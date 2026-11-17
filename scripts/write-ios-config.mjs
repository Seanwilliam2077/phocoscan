import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const base=path.join(root,'ios','Config');fs.mkdirSync(base,{recursive:true});
const xmlHeader='<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n';
for (const debug of [false,true]) {
const plist=`${xmlHeader}<plist version="1.0"><dict>
 <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
 <key>CFBundleDisplayName</key><string>口袋世界</string>
 <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
 <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
 <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
 <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
 <key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
 <key>LSRequiresIPhoneOS</key><true/>
 <key>NSCameraUsageDescription</key><string>用相机把你选择的室内外一角记录成风景邮票，提交后可由研究者处理成三维场景。</string>
 <key>NSLocalNetworkUsageDescription</key><string>连接你设置的局域网测试服务器，上传采集并取回三维场景。</string>
 <key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
 <key>UILaunchScreen</key><dict/>
 <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string><string>metal</string></array>
 <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
 <key>UIUserInterfaceStyle</key><string>Light</string>
 ${debug?'<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>':''}
</dict></plist>`;
fs.writeFileSync(path.join(base,debug?'Info-Debug.plist':'Info.plist'),plist);
}
const privacy=path.join(root,'ios','PocketWorld','PrivacyInfo.xcprivacy');fs.mkdirSync(path.dirname(privacy),{recursive:true});
fs.writeFileSync(privacy,`${xmlHeader}<plist version="1.0"><dict>
 <key>NSPrivacyTracking</key><false/>
 <key>NSPrivacyTrackingDomains</key><array/>
 <key>NSPrivacyAccessedAPITypes</key><array><dict>
  <key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryUserDefaults</string>
  <key>NSPrivacyAccessedAPITypeReasons</key><array><string>CA92.1</string></array>
 </dict></array>
 <key>NSPrivacyCollectedDataTypes</key><array>
  <dict><key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypePhotosorVideos</string><key>NSPrivacyCollectedDataTypeLinked</key><true/><key>NSPrivacyCollectedDataTypeTracking</key><false/><key>NSPrivacyCollectedDataTypePurposes</key><array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array></dict>
  <dict><key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeUserID</string><key>NSPrivacyCollectedDataTypeLinked</key><true/><key>NSPrivacyCollectedDataTypeTracking</key><false/><key>NSPrivacyCollectedDataTypePurposes</key><array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array></dict>
  <dict><key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeProductInteraction</string><key>NSPrivacyCollectedDataTypeLinked</key><true/><key>NSPrivacyCollectedDataTypeTracking</key><false/><key>NSPrivacyCollectedDataTypePurposes</key><array><string>NSPrivacyCollectedDataTypePurposeAnalytics</string></array></dict>
 </array>
</dict></plist>`);
console.log('Wrote native iOS plist configuration. HTTP exception is Debug-only.');

