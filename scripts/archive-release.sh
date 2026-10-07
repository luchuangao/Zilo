#!/bin/bash
set -euo pipefail
: "${OWNLIST_TEAM:?设置 Apple 开发者团队 ID}"
ownlist_root="$(cd "$(dirname "$0")/.." && pwd)"
ownlist_release="$ownlist_root/.release/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ownlist_release"
ownlist_archive="$ownlist_release/OwnList.xcarchive"
xcodebuild -project "$ownlist_root/OwnList.xcodeproj" -scheme OwnList -configuration Release -archivePath "$ownlist_archive" DEVELOPMENT_TEAM="$OWNLIST_TEAM" -allowProvisioningUpdates -allowProvisioningDeviceRegistration archive
cat > "$ownlist_release/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>method</key><string>developer-id</string><key>destination</key><string>upload</string><key>teamID</key><string>$OWNLIST_TEAM</string><key>signingStyle</key><string>automatic</string><key>manageAppVersionAndBuildNumber</key><false/></dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ownlist_archive" -exportPath "$ownlist_release/upload" -exportOptionsPlist "$ownlist_release/ExportOptions.plist" -allowProvisioningUpdates
printf '提交完成不代表公证通过。Apple 完成公证后执行：
xcodebuild -exportNotarizedApp -archivePath "%s" -exportPath "%s/notarized"
' "$ownlist_archive" "$ownlist_release"
