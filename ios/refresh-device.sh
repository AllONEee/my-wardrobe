#!/usr/bin/env bash
#
#  refresh-device.sh —— 免费个人开发者账号的「续期」脚本
#
#  免费账号签名出来的 App 只有 7 天有效期，过期后再点图标会提示无法验证 / 直接闪退。
#  手机连上电脑（或开着无线调试）跑一下这个脚本就行：重新签名 + 覆盖安装，
#  App 里的数据（衣物、图片、穿搭）都在，不会被清掉。
#
#  用法：
#      ./ios/refresh-device.sh                 # 自动找第一台已连接的 iPhone
#      ./ios/refresh-device.sh "我的 iPhone"    # 指定设备名
#      DEVELOPMENT_TEAM=ABCDE12345 ./ios/refresh-device.sh   # 工程里还没设 Team 时用
#

set -euo pipefail

cd "$(dirname "$0")"

BUILD_DIR="$PWD/build-ios"
DEVICE_NAME="${1:-}"

TEAM_SETTING=""
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  TEAM_SETTING="DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
elif ! grep -q "DEVELOPMENT_TEAM = " Wardrobe.xcodeproj/project.pbxproj; then
  echo "⚠️  工程里还没有 Development Team。"
  echo "   先在 Xcode 里打开 Wardrobe.xcodeproj → Signing & Capabilities 选一次 Team（选完会写进工程，之后就不用再选），"
  echo "   或者这样运行：DEVELOPMENT_TEAM=你的TeamID ./ios/refresh-device.sh"
  exit 1
fi

echo "==> 1/3 找手机"
# devicectl 的输出里，设备标识是一串 UUID，用它定位最稳（设备名可能带空格）
DEVICE_LIST="$(xcrun devicectl list devices 2>/dev/null || true)"
pick_uuid() {
  awk -v pattern="$1" '
    $0 ~ pattern {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/) {
          if (pattern == "connected") { if ($(i+1) == "connected") { print $i; exit } }
          else { print $i; exit }
        }
      }
    }' <<<"$DEVICE_LIST"
}

if [[ -n "$DEVICE_NAME" ]]; then
  UDID=$(pick_uuid "$DEVICE_NAME")
else
  UDID=$(pick_uuid "connected")
fi

if [[ -z "${UDID:-}" ]]; then
  echo "✗ 没找到已连接的 iPhone。确认：数据线已连接并「信任此电脑」，手机上已开启「开发者模式」。"
  echo "  已识别的设备："
  echo "$DEVICE_LIST"
  exit 1
fi
echo "    设备标识：$UDID"

echo "==> 2/3 构建（自动签名，会顺带刷新 7 天的描述文件）"
# 用 generic/platform=iOS 构建（真机通用产物），装到哪台设备交给下面的 devicectl；
# xcodebuild 认的是硬件 UDID，和 devicectl 给的标识不是一回事，所以这里不指定具体设备。
# 构建日志先收进临时文件：成功时保持输出干净，失败时把真正的报错打印出来
BUILD_LOG="$(mktemp -t wardrobe-build)"
if ! xcodebuild \
  -project Wardrobe.xcodeproj \
  -scheme Wardrobe \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$BUILD_DIR" \
  -allowProvisioningUpdates \
  $TEAM_SETTING \
  -quiet \
  build >"$BUILD_LOG" 2>&1; then
  grep -E "error:|❌|Signing" "$BUILD_LOG" | head -20
  echo "✗ 构建失败。常见原因：Xcode 里还没登录 Apple ID、Team 没选对，或手机的 iOS 版本低于 17。"
  echo "  （完整日志：$BUILD_LOG）"
  exit 1
fi

APP_PATH="$BUILD_DIR/Build/Products/Debug-iphoneos/Wardrobe.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "✗ 没找到构建产物：$APP_PATH"
  exit 1
fi
echo "    构建成功"

# bundle id 直接从打好的包里读，改过名字也不用动脚本
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Info.plist" 2>/dev/null || echo "")"

echo "==> 3/3 覆盖安装（不会清数据）"
if ! INSTALL_OUT="$(xcrun devicectl device install app --device "$UDID" "$APP_PATH" 2>&1)"; then
  echo "$INSTALL_OUT" | tail -5
  echo "✗ 安装失败：确认手机已解锁、停在主屏，并已「信任此电脑」。"
  exit 1
fi
echo "$INSTALL_OUT" | grep -E "App installed" || true

# 装完顺手打开，省得手动找图标（失败也不影响续期结果）
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "✅ 续期完成，有效期重新开始算 7 天。手机上如果提示「不受信任的开发者」，去"
echo "   设置 → 通用 → VPN与设备管理 → 开发者 App 里信任一次即可。"
