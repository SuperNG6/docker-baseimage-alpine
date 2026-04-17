#!/bin/bash

# 版本检查脚本
# 用于获取官方 Alpine 最新版本，并每月强制构建镜像

# 检查参数
if [ -z "$1" ]; then
    echo "::error::错误：未提供 Docker 镜像名称。用法：$0 <镜像名称>"
    exit 1
fi

DOCKER_IMAGE="$1"

echo "正在检查官方 Alpine 版本..." >&2

# 获取官方 Alpine 最新版本
API_URL='https://hub.docker.com/v2/repositories/library/alpine/tags/?page_size=100&ordering=last_updated'
RESPONSE=$(curl -fsSL --retry 3 --retry-delay 2 "$API_URL")

if [ -z "$RESPONSE" ]; then
    echo "::error::无法从 Docker Hub API 获取 Alpine 标签信息。" >&2
    exit 1
fi

OFFICIAL_VERSION=$(echo "$RESPONSE" | jq -r '.results[].name' | grep -E '^[0-9]+(\.[0-9]+){1,2}$' | sort -Vr | head -n 1)

if [ -z "$OFFICIAL_VERSION" ]; then
    echo "::error::无法从 Docker Hub API 响应中解析出有效的 Alpine 版本标签。" >&2
    exit 1
fi

echo "官方 Alpine 最新版本: $OFFICIAL_VERSION" >&2

# 获取我们镜像的最新版本
OUR_API_URL="https://hub.docker.com/v2/repositories/${DOCKER_IMAGE}/tags/?page_size=100&ordering=last_updated"
OUR_RESPONSE=$(curl -fsSL --retry 3 --retry-delay 2 "$OUR_API_URL" || echo '{"results":[]}')

# 提取我们镜像中符合 x.y.z 格式的最新版本
OUR_VERSION=$(echo "$OUR_RESPONSE" | jq -r '.results[].name' | grep -E '^[0-9]+(\.[0-9]+){1,2}$' | sort -Vr | head -n 1 || echo "0.0.0")

echo "我们的镜像最新版本: $OUR_VERSION" >&2

# 每月强制构建，不论版本是否相同
echo "每月定期构建，无论版本是否相同，直接触发构建 (官方版本: $OFFICIAL_VERSION，我们的版本: $OUR_VERSION)" >&2
SHOULD_BUILD="true"

# 计算次版本号
MINOR_VERSION=$(echo "$OFFICIAL_VERSION" | cut -d '.' -f 1-2)

echo "检查完成: should_build=$SHOULD_BUILD, full_version=$OFFICIAL_VERSION, minor_version=$MINOR_VERSION" >&2

# --- GitHub Actions 输出 ---
# 使用多行字符串向 $GITHUB_OUTPUT 写入，这是官方推荐的方式
{
  echo "should_build=${SHOULD_BUILD}"
  echo "full_version=${OFFICIAL_VERSION}"
  echo "minor_version=${MINOR_VERSION}"
} >> "$GITHUB_OUTPUT"
