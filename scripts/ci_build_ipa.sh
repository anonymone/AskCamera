#!/usr/bin/env bash
# CI: 编译并产出 AskCamera.ipa（有签名材料则导出可安装包，否则产出未签名包）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="AskCamera"
PROJECT="AskCamera.xcodeproj"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT/build/AskCamera.xcarchive}"
IPA_DIR="${IPA_DIR:-$ROOT/build/ipa}"
EXPORT_DIR="${EXPORT_DIR:-$ROOT/build/export}"
RUNNER_TEMP="${RUNNER_TEMP:-$(mktemp -d)}"

mkdir -p "$IPA_DIR" "$EXPORT_DIR" "$(dirname "$ARCHIVE_PATH")" "$RUNNER_TEMP"

beautify() {
  if command -v xcbeautify >/dev/null 2>&1; then
    xcbeautify --renderer github-actions
  else
    cat
  fi
}

has_signing=0
if [[ -n "${BUILD_CERTIFICATE_BASE64:-}" && -n "${BUILD_PROVISION_PROFILE_BASE64:-}" && -n "${P12_PASSWORD:-}" ]]; then
  has_signing=1
fi

if [[ "$has_signing" -eq 1 ]]; then
  echo "==> 使用手动签名归档并导出 IPA"
  : "${APPLE_TEAM_ID:?签名模式下必须设置 APPLE_TEAM_ID}"
  : "${KEYCHAIN_PASSWORD:?签名模式下必须设置 KEYCHAIN_PASSWORD}"

  CERTIFICATE_PATH="$RUNNER_TEMP/build_certificate.p12"
  PP_PATH="$RUNNER_TEMP/build_pp.mobileprovision"
  KEYCHAIN_PATH="$RUNNER_TEMP/app-signing.keychain-db"

  echo -n "$BUILD_CERTIFICATE_BASE64" | base64 --decode -o "$CERTIFICATE_PATH"
  echo -n "$BUILD_PROVISION_PROFILE_BASE64" | base64 --decode -o "$PP_PATH"

  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security import "$CERTIFICATE_PATH" \
    -P "$P12_PASSWORD" \
    -A \
    -t cert \
    -f pkcs12 \
    -k "$KEYCHAIN_PATH"
  security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security list-keychain -d user -s "$KEYCHAIN_PATH"

  mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
  PP_UUID="$(/usr/libexec/PlistBuddy -c 'Print UUID' /dev/stdin <<< "$(security cms -D -i "$PP_PATH")")"
  cp "$PP_PATH" "$HOME/Library/MobileDevice/Provisioning Profiles/$PP_UUID.mobileprovision"
  echo "Provisioning profile UUID: $PP_UUID"

  EXPORT_METHOD="${EXPORT_METHOD:-development}"
  case "$EXPORT_METHOD" in
    development) DEFAULT_IDENTITY="Apple Development" ;;
    *) DEFAULT_IDENTITY="Apple Distribution" ;;
  esac
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-$DEFAULT_IDENTITY}"

  cat > "$EXPORT_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>${EXPORT_METHOD}</string>
  <key>teamID</key>
  <string>${APPLE_TEAM_ID}</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>compileBitcode</key>
  <false/>
  <key>provisioningProfiles</key>
  <dict>
    <key>com.severuspeng.AskCamera</key>
    <string>${PP_UUID}</string>
  </dict>
</dict>
</plist>
EOF

  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    PROVISIONING_PROFILE="$PP_UUID" \
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
    | beautify

  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_DIR/ExportOptions.plist" \
    | beautify

  shopt -s nullglob
  exported=( "$EXPORT_DIR"/*.ipa )
  if [[ ${#exported[@]} -eq 0 ]]; then
    echo "错误: 未找到导出的 IPA" >&2
    exit 1
  fi
  cp "${exported[0]}" "$IPA_DIR/AskCamera.ipa"
else
  echo "==> 未配置签名 Secrets，生成未签名 IPA（仅供 CI 产物验证，无法直接安装到真机）"
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk iphoneos \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    | beautify

  APP_PATH="$(find "$DERIVED_DATA/Build/Products" -path "*/AskCamera.app" -type d | head -n 1 || true)"
  if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    echo "错误: 未找到 AskCamera.app" >&2
    find "$DERIVED_DATA/Build/Products" -maxdepth 4 -print >&2 || true
    exit 1
  fi

  STAGE="$EXPORT_DIR/unsigned-payload"
  rm -rf "$STAGE"
  mkdir -p "$STAGE/Payload"
  cp -R "$APP_PATH" "$STAGE/Payload/"
  (
    cd "$STAGE"
    zip -qry "$IPA_DIR/AskCamera-unsigned.ipa" Payload
  )
fi

echo "==> IPA 产物:"
ls -lh "$IPA_DIR"
