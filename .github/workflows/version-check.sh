#!/usr/bin/env bash
set -euo pipefail

hub_image=${1:?需要 Docker Hub 的最新 s6 v3 镜像引用}
ghcr_image=${2:?需要 GHCR 的最新 s6 v3 镜像引用}
alpine_pattern='^[0-9]+\.[0-9]+\.[0-9]+$'
overlay_pattern='^3(\.[0-9]+){2,3}$'

latest_alpine=$(
    curl -fsSL --retry 3 'https://hub.docker.com/v2/repositories/library/alpine/tags/?page_size=100&ordering=last_updated' |
        jq -r --arg pattern "$alpine_pattern" '.results[].name | select(test($pattern))' |
        sort -Vr | sed -n '1p'
)
latest_overlay=$(
    gh api --paginate 'repos/just-containers/s6-overlay/releases?per_page=100' \
        --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name | ltrimstr("v") | select(test("^3(\\.[0-9]+){2,3}$"))' |
        sort -Vr | sed -n '1p'
)

if [[ ! $latest_alpine =~ $alpine_pattern || ! $latest_overlay =~ $overlay_pattern ]]; then
    echo '::error::未找到可用的 Alpine 或 s6-overlay v3 稳定版本' >&2
    exit 1
fi

read_image_versions() {
    local image=$1 pull_output
    if pull_output=$(docker pull --quiet --platform linux/amd64 "$image" 2>&1); then
        # 读取已安装的版本，兼容没有版本标签的镜像。
        docker run --rm --pull=never --platform linux/amd64 --network none \
            --entrypoint /bin/sh "$image" -ec '
                alpine=$(cat /etc/alpine-release)
                overlay=$(readlink /package/admin/s6-overlay)
                overlay=$(basename "$overlay")
                printf "%s %s\n" "$alpine" "${overlay#s6-overlay-}"
            '
    elif [[ $pull_output == *'manifest unknown'* ||
            $pull_output == *'Error response from daemon:'*' not found'* ]]; then
        echo "$image 尚未发布" >&2
    else
        printf '::error::无法检查 %s\n%s\n' "$image" "$pull_output" >&2
        return 1
    fi
}

version_is_newer() {
    [[ $1 != "$2" && $(printf '%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

hub_versions=$(read_image_versions "$hub_image")
ghcr_versions=$(read_image_versions "$ghcr_image")

echo "上游版本：Alpine $latest_alpine，s6-overlay $latest_overlay"
echo "Docker Hub 版本：${hub_versions:-未发布}"
echo "GHCR 版本：${ghcr_versions:-未发布}"

# 同时比较两个仓库；如果上游标签回退，继续使用已发布的较高版本。
alpine=$latest_alpine
overlay=$latest_overlay
for versions in "$hub_versions" "$ghcr_versions"; do
    [[ -n $versions ]] || continue
    read -r published_alpine published_overlay <<< "$versions"
    if [[ ! $published_alpine =~ $alpine_pattern || ! $published_overlay =~ $overlay_pattern ]]; then
        echo "::error::无法解析已发布镜像的版本：$versions" >&2
        exit 1
    fi
    if version_is_newer "$published_alpine" "$alpine"; then
        alpine=$published_alpine
    fi
    if version_is_newer "$published_overlay" "$overlay"; then
        overlay=$published_overlay
    fi
done

should_build=false
if [[ $hub_versions != "$alpine $overlay" || $ghcr_versions != "$alpine $overlay" ]]; then
    should_build=true
fi

{
    printf 'should_build=%s\n' "$should_build"
    printf 'full_version=%s\n' "$alpine"
    printf 'minor_version=%s\n' "${alpine%.*}"
    printf 's6_overlay_version=%s\n' "$overlay"
} >> "${GITHUB_OUTPUT:?需要设置 GITHUB_OUTPUT}"
