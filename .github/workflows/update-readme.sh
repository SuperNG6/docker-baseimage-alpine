#!/bin/bash

# --- 脚本配置 ---
README_FILE="README.md"
NEW_VERSION=$1
# 用于定位插入点的标记行，注意转义正则表达式中的特殊字符
MARKER_LINE="\[linuxserverurl\]: https:\/\/linuxserver.io"

# --- 参数检查 ---
if [ -z "$NEW_VERSION" ]; then
  echo "::error::错误：未提供版本号。用法：$0 <版本号>"
  exit 1
fi

# --- 检查是否已存在该版本的更新记录 ---
# 使用 grep -q 来静默检查，如果找到匹配项，命令成功退出
if grep -q "Alpine v${NEW_VERSION}" "$README_FILE"; then
  echo "README.md 中已存在版本 ${NEW_VERSION} 的记录，无需更新。"
  # 正常退出，让 GitHub Action job 成功结束
  exit 0
fi

echo "正在更新 README.md，添加新版本 ${NEW_VERSION}..."

# --- 准备要插入的内容 ---
# 获取当前日期，格式为 YYYY-MM-DD
CURRENT_DATE=$(date +'%Y-%m-%d')

# --- 使用 sed 命令在标记行之前插入新内容 ---
# 使用 sed 的插入命令，将换行符用 \n 表示
# GNU sed 需要在每行末尾使用 \ 来续行
sed -i "/${MARKER_LINE}/i ### ${CURRENT_DATE} 更新\\nAlpine v${NEW_VERSION}\\n" "$README_FILE"

echo "README.md 文件已成功更新。"
cat "$README_FILE"