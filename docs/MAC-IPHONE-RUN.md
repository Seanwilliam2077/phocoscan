# 在 Mac 上安装并验证原生 iPhone 扫描 App

> 2026-11-03最新更新：双任务App源码已接好，A10业务API/worker已常驻。Debug默认 `http://9.135.79.113:8787`，点击连接后使用。使用本轮最新源码ZIP；此前临时Windows服务与仅FF步骤已被新主流程替代。完整实现与Windows验收见 [App/A10记录](APP-A10-MVP-VALIDATION-2026-11-03.md)。原生上传核验后自动POST `/v2/captures/:id/reconstructions`，同时运行FF和SfM；真机需验两个结果切换、游览、失败重试、前台刷新及成长去重。以下历史第5步的单独FF接口不再是当前App主流程。

> 2026-11-02。首轮设备：iPhone 17 Pro Max（LiDAR）；已有 Mac，尚未安装 Xcode，也没有付费 Apple Developer 会员。Windows 上的源码编辑和 Node 测试不能替代以下真机验收。

## 准备

1. 从 Mac App Store 安装与当前 macOS 兼容的官方 Xcode，首次打开并安装它要求的组件。不要将 Apple Account 密码或验证码发到聊天。
2. 在 Windows 项目根目录运行 `powershell -ExecutionPolicy Bypass -File .\scripts\Export-MacHandoff.ps1` 生成 `outputs/shijing-native-ios-source-*.zip`，再把这个**源码交接包**复制到 Mac 并解压；保留 `ios/PocketWorld.xcodeproj`、`ios/PocketWorld/`、`ios/Config/` 和项目中的 `Package.resolved`。交接包不含 `server/data/`、`server/.local-config.json`、`runtime/`、`work/` 或真实采集媒体。
3. 在 Xcode 的 Accounts 中登录自己的 Apple Account。即使没有付费会员，Xcode 也可显示 Personal Team，供本人设备开发测试；此类签名需定期重签，不能用于 TestFlight 分发。[Apple 账户说明](https://developer.apple.com/help/account/basics/about-your-developer-account)
4. 用 USB 连接 iPhone 17 Pro Max，信任电脑；按 Xcode 的提示在手机开启开发者模式。记录手机 iOS 版本和 Xcode 版本。

## 编译与安装

1. 在 Mac 双击 `ios/PocketWorld.xcodeproj`，等待 Swift Package 依赖解析完成。
2. 选择 `PocketWorld` App target 的 **Signing & Capabilities**，启用自动签名，Team 选自己的 Personal Team。若 `com.pocketworld.mvp` 已被占用，改为自己唯一的 Bundle Identifier；不要改测试数据中的 capture ID。
3. Scheme 选 `PocketWorld`，运行目标选连接的 iPhone，点击 **Run**。首次安装可能要求在 iPhone 上允许开发者 App。若构建失败，保存完整的 Xcode 编译错误；不得将未编译源码或模拟器画面记为真机通过。

## 首轮真机验收

> 新增范围：完成下面 FF 主线后，还需按 [FF／SfM 手机渲染方案](FF-SFM-MOBILE-DELIVERY.md) 验收精细 SH3 结果、同视角画质、版本切换和轨迹游览。当前步骤中的既有代码描述不代表精细分支已接通。

1. 允许相机权限，拍摄一处静止、有纹理的桌面或室内一角约 10–20 秒，保持目标在画面中，缓慢侧移并补一个斜角。之后再拍一处安全、允许拍摄的室外固定场景。
2. 每次拍摄都确认本地出现新采集包，含 `video.mov`、`frames.jsonl`、`manifest.json`；检查 `frameCount > 0`、视频能播放、逐帧时间递增、内参／位姿存在。Pro 机型应单独记录 `depthSupported` 和实际 `depthFrameCount`，不能仅凭设备型号宣称每帧都有深度。
3. 对照视频画面核对方向、帧率、跳帧、深度与 RGB 对齐；切到后台和断网各测一次，确认已完成的采集包仍可找到，未完成的 `.partial` 包不会误报为可上传。
4. 当前 App 已有 v2 上传和 FF 状态界面源码。取得稳定 HTTPS 服务地址并部署本项目的新版后端后，在首页右上角「设置」填写地址并连接；打开本机采集，选择室内／室外，阅读上传与 FF 预览同意说明后提交。上传期间保持 App 打开。确认服务器回读同一 capture ID、核对原片与元数据哈希、返回 `rgb_metadata_verified` 回执，并在成长记录中增加一步；断网后手动重试应沿用同一 ID。
5. 核验完成后 App 会用同一 capture ID 自动创建一次 FF 任务。显式运行出站 WorldMirror worker，确认任务经过 queued／processing 和 Hub 真实成功终态，再核对输入资产、PLY 和展示 `.splat` 的哈希。回到手机打开 3D 预览，记录上传、排队、推理、下载和首帧的时间；失败时原片和回执应保留。回执本身只证明 RGB 视频字节、视频容器和逐帧相机信息通过当前检查；深度仍在本机，SfM 尚未接入。当前没有稳定上传域名或 Xcode 真机结果，不能把 Windows 测试记成手机通过。

研究测试的场景、指标与 T1–T11 顺序见 [原生 iPhone 验证计划](NATIVE-IOS-VALIDATION-PLAN.md)。
