#!/usr/bin/env bash
# 打包窗间 · Windowfolk 为 Windowfolk.app（输出到仓库根目录）。
#
# 用法：./build-app.sh
#
# 可选环境变量：
#   WINDOWFOLK_ARCHS  目标架构，空格分隔。默认 "arm64 x86_64"（通用二进制）；
#                     通用构建失败时自动退回本机架构。显式设置时不退回。
#   WINDOWFOLK_APP_DIR  Windowfolk.app 的输出目录，默认仓库根目录。
#
# 不需要任何交互输入。任一步骤失败时输出失败步骤并以非零退出码结束。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="Windowfolk"
OUT_DIR="${WINDOWFOLK_APP_DIR:-$ROOT}"
APP="$OUT_DIR/$APP_NAME.app"
PLIST_TEMPLATE="$ROOT/Resources/Info.plist"
ASSETS_SRC="$ROOT/Assets"

CURRENT_STEP="准备"
STAGING=""

step() {
  CURRENT_STEP="$1"
  echo "==> $1"
}

# 用 EXIT 而不是 ERR：set -u 的未定义变量等错误不会触发 ERR，但一定会走到 EXIT
on_exit() {
  local code=$?
  # bash 3.2 遇到 set -u 错误时传给 EXIT 的 $? 为 0，用完成标记兜底
  if [[ $code -eq 0 && "${BUILD_DONE:-0}" != 1 ]]; then
    code=1
  fi
  if [[ -n "$STAGING" && -d "$STAGING" ]]; then
    rm -rf "$STAGING"
  fi
  if [[ $code -ne 0 ]]; then
    echo "" >&2
    echo "错误：构建在步骤「${CURRENT_STEP}」失败（退出码 ${code}）。" >&2
    echo "未生成新的 ${APP_NAME}.app；已有的 ${APP_NAME}.app 保持不变。" >&2
  fi
  exit "$code"
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
step "检查工具"
for tool in swift codesign plutil lipo rsync; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "缺少命令：${tool}（需要安装 Xcode 或 Command Line Tools）" >&2
    false
  fi
done
if [[ ! -f "$PLIST_TEMPLATE" ]]; then
  echo "找不到 Info.plist 模板：$PLIST_TEMPLATE" >&2
  false
fi

# ---------------------------------------------------------------------------
step "确定版本号"
VERSION="0.1.0"
if TAG="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null)"; then
  VERSION="${TAG#v}"
fi
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
echo "    版本 ${VERSION}（build ${BUILD_NUMBER}）"

# ---------------------------------------------------------------------------
build_release() {
  local arch_flags=()
  local a
  BUILT_FOR=("$@")
  for a in "$@"; do arch_flags+=(--arch "$a"); done
  # 在 if 条件中调用时 set -e 不生效，所以每一步显式检查
  swift build -c release --product "$APP_NAME" "${arch_flags[@]}" || return 1
  BIN_DIR="$(swift build -c release --product "$APP_NAME" "${arch_flags[@]}" --show-bin-path)" || return 1
}

BIN_DIR=""
BUILT_FOR=()
if [[ -n "${WINDOWFOLK_ARCHS:-}" ]]; then
  read -r -a ARCHS <<<"$WINDOWFOLK_ARCHS"
  step "Release 构建（${ARCHS[*]}）"
  build_release "${ARCHS[@]}"
else
  step "Release 构建（通用二进制 arm64 + x86_64）"
  if ! build_release arm64 x86_64; then
    NATIVE="$(uname -m)"
    echo "    注意：通用二进制构建失败，退回本机架构 ${NATIVE}。生成的 .app 只能在 $NATIVE Mac 上运行。"
    step "Release 构建（本机架构 ${NATIVE}）"
    build_release "$NATIVE"
  fi
fi

BINARY="$BIN_DIR/$APP_NAME"
if [[ ! -x "$BINARY" ]]; then
  echo "构建产物不存在：$BINARY" >&2
  false
fi
echo "    可执行文件：$BINARY"
BUILT_ARCHS="$(lipo -archs "$BINARY")"
echo "    架构：$BUILT_ARCHS"
# SwiftPM 遇到无效架构只给警告并沿用旧产物，这里确认产物确实包含请求的架构
for a in "${BUILT_FOR[@]}"; do
  if [[ " $BUILT_ARCHS " != *" $a "* ]]; then
    echo "构建产物缺少架构 ${a}（实际：${BUILT_ARCHS}）" >&2
    false
  fi
done

# ---------------------------------------------------------------------------
step "组装 $APP_NAME.app"
mkdir -p "$OUT_DIR"
STAGING="$(mktemp -d "$OUT_DIR/.$APP_NAME.app.XXXXXX")"
BUNDLE="$STAGING/$APP_NAME.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY" "$BUNDLE/Contents/MacOS/$APP_NAME"
chmod 755 "$BUNDLE/Contents/MacOS/$APP_NAME"

cp "$PLIST_TEMPLATE" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$BUNDLE/Contents/Info.plist"
plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null
printf 'APPL????' >"$BUNDLE/Contents/PkgInfo"

# ---------------------------------------------------------------------------
step "复制素材"
if [[ -d "$ASSETS_SRC" ]]; then
  mkdir -p "$BUNDLE/Contents/Resources/Assets"
  # 只复制内容，不带 .DS_Store
  rsync -a --exclude '.DS_Store' "$ASSETS_SRC/" "$BUNDLE/Contents/Resources/Assets/"
  echo "    已复制 $(find "$BUNDLE/Contents/Resources/Assets" -type f -name '*.png' | wc -l | tr -d ' ') 个 PNG"
else
  echo "    仓库根目录没有 Assets/，应用将全部使用占位图形"
fi

# ---------------------------------------------------------------------------
step "Ad-hoc 签名"
codesign --force --sign - --deep "$BUNDLE"
codesign --verify --strict "$BUNDLE"

# ---------------------------------------------------------------------------
step "替换输出目录中的 $APP_NAME.app"
rm -rf "$APP"
mv "$BUNDLE" "$APP"
BUILD_DONE=1

echo ""
echo "完成：$APP"
echo "启动：open \"$APP\""
