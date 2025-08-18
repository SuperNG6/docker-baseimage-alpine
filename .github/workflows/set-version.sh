#!/bin/bash

# 任何命令执行失败时，立即退出脚本
set -e

# 将调试信息输出到标准错误流 (stderr)
echo "正在从 Docker Hub API 获取最新的 Alpine 版本..." >&2

API_URL='https://hub.docker.com/v2/repositories/library/alpine/tags/?page_size=100&ordering=last_updated'
RESPONSE=$(curl -fsSL --retry 3 --retry-delay 2 "$API_URL")

if [ -z "$RESPONSE" ]; then
    echo "::error::无法从 Docker Hub API 获取标签信息。" >&2
    exit 1
fi

FULL_VERSION=$(echo "$RESPONSE" | jq -r '.results[].name' | grep -E '^[0-9]+(\.[0-9]+){1,2}$' | sort -Vr | head -n 1)

if [ -z "$FULL_VERSION" ]; then
    echo "::error::无法从 Docker Hub API 响应中解析出有效的 Alpine 版本标签。" >&2
    exit 1
fi

# 从完整版本号中提取 主版本.次版本
MINOR_VERSION=$(echo "$FULL_VERSION" | cut -d '.' -f 1-2)

# 将调试信息输出到标准错误流
echo "获取到的完整版本是: $FULL_VERSION" >&2
echo "生成的次版本是: $MINOR_VERSION" >&2

# --- GitHub Actions 输出 ---
# 使用多行字符串向 $GITHUB_OUTPUT 写入，这是官方推荐的方式
{
  echo "full_version=${FULL_VERSION}"
  echo "minor_version=${MINOR_VERSION}"
} >> "$GITHUB_OUTPUT"