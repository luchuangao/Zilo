#!/bin/bash
set -euo pipefail
zilo_root="$(cd "$(dirname "$0")/.." && pwd)"
zilo_output="${ZILO_OUTPUT:-$zilo_root/.release/iphone-$(date +%Y%m%d-%H%M%S)}"
zilo_team="${ZILO_TEAM:-VFDQL6Z55P}"
mkdir -p "$zilo_output"
xcodebuild -project "$zilo_root/ZiloMobile.xcodeproj" -scheme ZiloMobile -configuration Release -destination 'generic/platform=iOS' -archivePath "$zilo_output/Zilo-iPhone.xcarchive" DEVELOPMENT_TEAM="$zilo_team" -allowProvisioningUpdates -allowProvisioningDeviceRegistration archive
cat > "$zilo_output/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>method</key><string>release-testing</string><key>destination</key><string>export</string><key>teamID</key><string>$zilo_team</string><key>signingStyle</key><string>automatic</string><key>iCloudContainerEnvironment</key><string>Production</string><key>manageAppVersionAndBuildNumber</key><false/></dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$zilo_output/Zilo-iPhone.xcarchive" -exportPath "$zilo_output/Export" -exportOptionsPlist "$zilo_output/ExportOptions.plist" -allowProvisioningUpdates
if [[ -n "${ZILO_DEVICE:-}" ]]; then
    mkdir -p "$zilo_output/Install"
    unzip -q "$zilo_output/Export/Zilo.ipa" -d "$zilo_output/Install"
    xcrun devicectl device install app --device "$ZILO_DEVICE" "$zilo_output/Install/Payload/Zilo.app"
fi
printf 'iPhone 构建产物：%s\n' "$zilo_output"
