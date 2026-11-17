# 口袋世界 · iPhone 原生 MVP

用真实的室内外一角，为三位旅人建一座九格小站。项目位于 `D:\PocketWorld`。

这是 **SwiftUI 原生 iPhone App + 可在 Windows 运行的本机后端**。当前电脑可以运行后端、处理数据和编辑工程；iOS 编译、签名及安装仍需要 Mac/Xcode。源码和结构检查不代表已在 iPhone 上运行，实际验证记录见 [验证报告](docs/VALIDATION.md)。

## 本机启动

要求 Node.js 24+。后端不需要数据库服务器、Docker、GPU或付费云服务。

```powershell
cd D:\PocketWorld
powershell -ExecutionPolicy Bypass -File .\scripts\Start-Backend.ps1
Invoke-RestMethod http://127.0.0.1:8787/health
```

启动器在后台运行服务，日志位于 `runtime/`。关闭当前终端不会停止已启动的服务。停止：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Stop-Backend.ps1
```

管理员操作方式见 [后端说明](server/README.md)。管理员凭证只留在本机 `server/.local-config.json`，不能填写到 App，也不要随项目发给测试者。

## 安装到 iPhone

1. 把整个项目复制到 Mac，**排除 `server/data/`、`server/.local-config.json`、`runtime/`、`work/` 和私有采集导出文件**。已有的 `ios/PocketWorld.xcodeproj` 可直接打开。
2. 使用 Xcode 16.3 或更新版本；iPhone 需 iOS 18 或更新版本。这是本次所选原生 Metal 查看器的系统要求，不需要 LiDAR。选用较新 Xcode 时仍以实际编译结果为准。
3. 打开工程，等待 Swift Package Manager 拉取锁定的 MetalSplatter 及其依赖。在 `PocketWorld` target 的 Signing & Capabilities 选择自己的 Team，改为自己的唯一 Bundle ID。
4. 连接并信任 iPhone，按 Xcode 提示开启开发者模式。选择 iPhone，使用 **Debug** 配置 Run。无需先上架或制作 TestFlight。具体可用签名条件取决于自己的 Apple 账号和设备。
5. 同一局域网测试时，Windows 端先停止后端，再运行 `Start-Backend.ps1 -Lan`。它会打印可尝试的局域网地址。App 的设置填 `http://电脑局域网IP:8787`，**不要填 iPhone 的 localhost**。允许 App 访问本地网络；如无法连接，再检查两台设备 Wi-Fi、路由隔离及 Windows 私有网络防火墙。脚本不会自动开放防火墙。
6. 先完成 [真机验收脚本](docs/PHONE-ACCEPTANCE.md)，再邀请其他玩家。Release 配置要求 HTTPS；内置 HTTP 例外仅用于 Debug 联调。

Mac 上可先运行 `bash scripts/mac-verify.sh` 编译 arm64 模拟器工程；所选渲染器不支持 Intel/x86_64 模拟器。模拟器不能替代手机相机、Metal、导入和真实采集测试。修改源码文件列表后，运行 `node scripts/generate-xcode-project.mjs` 重新生成工程。脚本不会删除源代码；Team/自定义签名设置请在 Xcode 中重新配置，或通过构建参数传入。

## 第一条闭环怎样操作

**游戏内采集：** 命名小站 → 接“第一盏暖灯” → 选择室内/室外 → 录制真实静音视频 → 预览并提交 → 领取门厅卡并放进社区。操作者用后端 CLI 导出采集包，交给支持该输入的重建工具处理，再把结果导回对应任务。App 刷新记录后打开原生 3D 查看器。

**Scaniverse 转接：** 先在游戏里保存任务 → 手动切到 Scaniverse 完成扫描/处理 → 导出本次结果到 iPhone“文件” → 回游戏导入 `.ply` 或 `.splat` → 领取场景卡、查看真实模型并布置社区。无需假定 Scaniverse 提供自动跳转或普通视频导入 API。当前导入器不接收 `.spz`；请从外部工具导出支持的格式。

如果只导入模型，来源会标记为 `external_asset_only`，不会声称拥有同一次扫描的原视频或相机轨迹。PLY 需要 Gaussian Splat 属性，普通点云 PLY 不能替代。模型上限和支持的数值布局见后端及媒体模块说明。

视频成功提交可以获得基础游戏卡；处理失败不会撤回它。只有真正导入的结果才能显示“可查看”，没有倒计时模拟重建。素材可看、几何合格、数据可双用是不同状态。

**当前本机模式的室外测试：** 出门前在同一 Wi-Fi 下创建任务；任务保存在邮袋后，可以离线录像或切换外部扫描工具，回到 Wi-Fi 再提交。新任务创建、上传和结果下载需要连接后端。若要在远处用蜂窝网络完成全部流程，需后续提供手机可达的 HTTPS 服务地址。

## 玩法和验证范围

- 九格社区可以放置、换位、旋转、收回；道路有接口，连通情况影响居民反馈。
- 六个探索任务涵盖门厅、休息区、道路、绿地、阅读角和小摊；保留室内外替代地点。
- 可以仅靠已有卡片完成建设章节；章节按进度推进，没有七天时间锁。支持庆典和下一章选择。
- 相机录制无游戏 UI、无音轨；三步拍摄引导是玩家确认，**尚未实现自动清晰度/覆盖率/AR 轨迹判断**。
- 后端保留来源、实际视频、处理状态与事件，支持人工重建、失败重试和追溯。
- 本期不实现云重建算法、自动 Scaniverse API、ARKit 相机轨迹、物理碰撞网格、机器人策略训练、视频模型训练或公开社交地图。

本轮优先验证“有人愿意玩 + 一次采集能走完产品流程”。一份数据同时服务机器人和视频模型仍需原始视频、相机估计、几何/碰撞等后续验收，不能凭一份 PLY 判定成功。

## 工程结构

```text
ios/PocketWorld/                 SwiftUI 游戏、原生相机与 Metal 查看
ios/PocketWorldTests/            原生游戏规则测试（需 Xcode 执行）
ios/PocketWorld.xcodeproj/       可打开的 Xcode 工程和共享 scheme
server/                         Node HTTP API、SQLite、人工处理 CLI、测试
scripts/                        Windows 启停、Xcode 工程生成与检查
docs/MVP-SPEC.md                 完整需求和原立项说明
docs/CONTRACT.md                 iOS / 后端接口契约
docs/PHONE-ACCEPTANCE.md          室内外真机验收
docs/VALIDATION.md               已执行/未执行的验证记录
```

## 本机开发检查

```powershell
cd D:\PocketWorld
npm.cmd test
node scripts/generate-xcode-project.mjs
node scripts/check-project.mjs
```

更多参考：[Apple 真机运行](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)、[MetalSplatter 原生查看器](https://github.com/scier/MetalSplatter)、[Scaniverse 官方流程](https://www.nianticspatial.com/docs/scaniverse/quickstart/)。

