#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status.
set -e

S6_VER=2.2.0.3

# Check if TARGETARCH environment variable is set by Docker Buildx.
# This is the most reliable way to determine the target architecture for multi-platform builds.
if [ -z "${TARGETARCH}" ]; then
    echo "错误：环境变量 TARGETARCH 未设置。"
    echo "此脚本需要 TARGETARCH 来确定目标CPU架构，该变量通常由 Docker Buildx 自动提供。"
    echo "请确保您的 Dockerfile 包含 'ARG TARGETARCH' 和 'ENV TARGETARCH=\${TARGETARCH}'，"
    echo "并且使用 'docker buildx build --platform ...' 命令进行构建。"
    exit 1
fi

echo "检测到目标CPU架构: ${TARGETARCH}"

# Determine the S6-Overlay architecture name based on TARGETARCH.
# The mapping is:
# Docker TARGETARCH -> S6-Overlay ARCH
# amd64             -> amd64
# arm64             -> aarch64
# arm               -> arm  (for armv7l platforms)
# 386               -> x86  (for 32-bit x86 platforms)
# ppc64le           -> ppc64le
case "${TARGETARCH}" in
    "amd64")   S6_ARCH="amd64"   ;;
    "arm64")   S6_ARCH="aarch64" ;;
    "arm")     S6_ARCH="arm"     ;;
    "386")     S6_ARCH="x86"     ;;
    "ppc64le") S6_ARCH="ppc64le" ;;
    *)
        echo "错误：不支持的CPU架构或S6-Overlay映射不完整: ${TARGETARCH}"
        echo "请检查 s6-overlay GitHub Release 页面以获取支持的架构名称，并更新脚本。"
        exit 1
        ;;
esac

echo "将为 S6-Overlay 使用架构: ${S6_ARCH}"

# Download s6-overlay
wget --no-check-certificate "https://github.com/just-containers/s6-overlay/releases/download/v${S6_VER}/s6-overlay-${S6_ARCH}.tar.gz"

# Create target directory and extract
mkdir -p ./s6-overlay
tar -xvzf "s6-overlay-${S6_ARCH}.tar.gz" -C ./s6-overlay

echo "S6-Overlay 下载并解压完成。"