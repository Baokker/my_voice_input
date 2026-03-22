#!/bin/bash
# 将打包好的 VoiceInput.app 安装到 ~/Applications 并首次启动
# 用法：bash install.sh

set -e

APP_SRC="dist/VoiceInput.app"
APP_DST="$HOME/Applications/VoiceInput.app"

if [ ! -d "$APP_SRC" ]; then
    echo "错误：未找到 $APP_SRC，请先运行打包命令："
    echo "  source .venv_build/bin/activate && python setup.py py2app"
    exit 1
fi

mkdir -p "$HOME/Applications"

echo "正在安装到 $APP_DST ..."
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

# 去掉 quarantine 标记，避免 Gatekeeper 拦截
xattr -cr "$APP_DST"

echo ""
echo "✓ 安装完成：$APP_DST"
echo ""
echo "首次启动前，请在系统设置 → 隐私与安全性 中授予以下三项权限："
echo "  1. 辅助功能    （文字注入需要）"
echo "  2. 输入监控    （热键监听需要）"
echo "  3. 麦克风      （录音需要）"
echo ""
echo "正在启动应用..."
open "$APP_DST"
