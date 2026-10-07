#!/bin/bash
set -euo pipefail
ownlist_root="$(cd "$(dirname "$0")/.." && pwd)"
ownlist_products="$ownlist_root/.build-local"
xcodebuild -project "$ownlist_root/OwnList.xcodeproj" -scheme OwnList -configuration Release -derivedDataPath "$ownlist_products" CODE_SIGNING_ALLOWED=NO build
ownlist_app="$ownlist_root/../自己的清单-本地构建.app"
if [ -d "$ownlist_app" ]; then mv "$ownlist_app" "$ownlist_products/Previous-$(date +%Y%m%d-%H%M%S).app"; fi
ditto "$ownlist_products/Build/Products/Release/OwnList.app" "$ownlist_app"
codesign --force --sign - "$ownlist_app/Contents/PlugIns/OwnListWidget.appex"
codesign --force --sign - "$ownlist_app/Contents/PlugIns/OwnListShare.appex"
codesign --force --sign - "$ownlist_app"
printf '应用已生成：%s\n' "$ownlist_app"
