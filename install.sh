#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status.
set -euo pipefail

S6_VER="${S6_OVERLAY_VERSION:-3.2.3.0}"
TARGETARCH="${TARGETARCH:-}"
TARGETVARIANT="${TARGETVARIANT:-}"

# TARGETARCH is provided by Docker Buildx. Fall back to the build host arch so
# a plain local `docker build` still works for native builds.
if [ -z "${TARGETARCH}" ]; then
    echo "警告：TARGETARCH 未设置，尝试从当前构建环境检测 CPU 架构。"
    case "$(uname -m)" in
        "x86_64") TARGETARCH="amd64" ;;
        "aarch64") TARGETARCH="arm64" ;;
        "armv7l") TARGETARCH="arm"; TARGETVARIANT="v7" ;;
        "armv6l") TARGETARCH="arm"; TARGETVARIANT="v6" ;;
        "i386"|"i486"|"i586"|"i686") TARGETARCH="386" ;;
        "ppc64le") TARGETARCH="ppc64le" ;;
        "ppc64") TARGETARCH="ppc64" ;;
        "riscv64") TARGETARCH="riscv64" ;;
        "s390x") TARGETARCH="s390x" ;;
        *)
            echo "错误：无法从 uname -m 检测支持的 CPU 架构: $(uname -m)"
            exit 1
            ;;
    esac
fi

echo "检测到目标 CPU 架构: ${TARGETARCH}${TARGETVARIANT:+/${TARGETVARIANT}}"

# Determine the s6-overlay v3 architecture name based on Docker target values.
case "${TARGETARCH}" in
    "amd64") S6_ARCH="x86_64" ;;
    "arm64") S6_ARCH="aarch64" ;;
    "arm")
        case "${TARGETVARIANT}" in
            "v6") S6_ARCH="armhf" ;;
            ""|"v7") S6_ARCH="arm" ;;
            *)
                echo "错误：不支持的 ARM 变体: ${TARGETVARIANT}"
                exit 1
                ;;
        esac
        ;;
    "386") S6_ARCH="i686" ;;
    "ppc64") S6_ARCH="powerpc64" ;;
    "ppc64le") S6_ARCH="powerpc64le" ;;
    "riscv64") S6_ARCH="riscv64" ;;
    "s390x") S6_ARCH="s390x" ;;
    *)
        echo "错误：不支持的 CPU 架构或 s6-overlay 映射不完整: ${TARGETARCH}"
        echo "请检查 s6-overlay GitHub Release 页面以获取支持的架构名称，并更新脚本。"
        exit 1
        ;;
esac

echo "将为 s6-overlay v${S6_VER} 使用架构: ${S6_ARCH}"

BASE_URL="https://github.com/just-containers/s6-overlay/releases/download/v${S6_VER}"
ARTIFACTS=(
    "s6-overlay-noarch"
    "s6-overlay-${S6_ARCH}"
    "s6-overlay-symlinks-noarch"
    "s6-overlay-symlinks-arch"
)

download_file() {
    local url="$1"
    local output="$2"

    if command -v wget >/dev/null 2>&1; then
        wget -q -O "${output}" "${url}"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "${url}" -o "${output}"
    else
        echo "错误：需要 wget 或 curl 下载 s6-overlay。"
        exit 1
    fi
}

mkdir -p ./s6-overlay

for ARTIFACT in "${ARTIFACTS[@]}"; do
    ARCHIVE="${ARTIFACT}.tar.xz"
    CHECKSUM="${ARCHIVE}.sha256"

    echo "下载 ${ARCHIVE}"
    download_file "${BASE_URL}/${ARCHIVE}" "${ARCHIVE}"
    download_file "${BASE_URL}/${CHECKSUM}" "${CHECKSUM}"
    sha256sum -c "${CHECKSUM}"
    tar -C ./s6-overlay -Jxpf "${ARCHIVE}"
done

echo "s6-overlay v${S6_VER} 下载、校验并解压完成。"
