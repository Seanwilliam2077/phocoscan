# phocoscan

原生 iPhone 扫描与 3D Gaussian Splatting 应用。当前产品名为 **phocoscan**，Xcode 工程和模块仍使用 `PocketWorld`，App Bundle ID 为 `com.pocketworld.mvp`。

## 当前功能

- 物体、人像、空间扫描：原始视频、相机位姿及设备支持的深度数据保存在本机，支持校准、偏离提示和采集检查。
- **3DGS 重建**：快速预览、精细重建、本机重建由用户独立选择；上传完成不会自动启动全部版本。
- 本机 Metal 训练：主体优先、自适应增密、锁屏/后台暂停与断点恢复；重新训练保留已有结果。
- 单图 AI 生成独立展示，与实拍扫描重建分开。
- 原生交互查看、主体/全景切换、上一版结果、视频与 Live Photo 导出。
- 作品搜索与分类；在「设置 → 作品管理」批量删除或清理显示覆盖低于 80% 的扫描。未评估、处理中作品和关联单图不会被低覆盖清理删除。

## 开发入口

- Android 协作先看 [接入说明](docs/ANDROID-HANDOFF.md)；`android/` 为预留目录，目前尚无 Android 客户端实现。
- `ios/PocketWorld.xcodeproj`：iOS 18+ 原生 SwiftUI / ARKit / Metal App。
- `ios/PocketWorldTests/`：模型、采集、恢复与删除等回归测试；真实素材/真机专项检查须显式启用。
- `ios/TrainerCheck/`：Mac GPU 训练与数值检查工具。
- `server/`：Node.js 24 API 与异步重建 worker。
- `deploy/`：服务部署脚本及校验工具；实际环境配置和凭证不在仓库中。

在 Mac 上用 Xcode 打开工程，选择自己的签名团队及目标设备。需要重新生成工程时执行：

```sh
POCKETWORLD_DEVELOPMENT_TEAM=YOUR_TEAM_ID node scripts/generate-xcode-project.mjs
```

服务端依赖和测试：

```sh
npm --prefix server ci
npm --prefix server test
```

运行环境和接口见 [服务端说明](server/README.md) 与 [接口契约](docs/CONTRACT.md)。远程部署、真实素材上传和 GPU 任务均不是上述测试命令的默认步骤。

## 状态与数据边界

当前为内部开发测试版本。功能、真机验收范围及已知限制以 [AGENTS.md](AGENTS.md) 的最新记录为准；尤其不能将模型可打开等同于几何/画质达标。[产品体验记录](docs/PRODUCT-EXPERIENCE-2026-11-11.md)、[本机训练 v6](docs/ON-DEVICE-TRAINING-V6.md)。

仓库只管理代码、文档、必要应用资源和合成测试夹具。原始拍摄与真实相机轨迹、生成模型、运行数据库、账户凭证、签名材料和编译缓存通过 `.gitignore` 排除。私有轨迹参考测试仅在测试设备设置 `PHOCOSCAN_ORBIT_REFERENCE_FIXTURE` 后运行；未配置时跳过该项。第三方组件及许可证见 [第三方声明](docs/THIRD-PARTY-NOTICES.md)。

<details>
<summary>早期开发记录（历史名称、自动双重建与成长玩法不代表当前产品行为）</summary>

# 小芽扫描 · iPhone 扫描、FF 预览与 SfM 精细结果

> 2026-11-03 最新方向：原生 iPhone App 保持简洁扫描，先给真实 FF／WorldMirror2 预览，同时将独立 SfM → 3DGS 精细结果、手机 SH3 渲染和轨迹游览纳入交付计划。两条结果可分别成功或失败；小芽成长只记录真实采集一次。[双结果与手机渲染方案](docs/FF-SFM-MOBILE-DELIVERY.md)、[FF 主线范围](docs/NATIVE-FF-APP-MVP.md)。服务器自动双重建的实现与验证见下文；Windows 测试不能代替 Xcode 编译与 iPhone 验收。此前微信小程序保留作历史原型。

## 当前原生 App 运行

2026-11-03 22:39 更新：原生 App 已接自动 FF/SfM、同查看器结果切换与失败分支重试。业务 API 和 worker 已部署到 A10 并常驻，Debug 地址为 `http://9.135.79.113:8787`；Windows真实上传已返回两份模型，服务重启恢复通过。Windows/A10后端各125项测试通过，25个Swift文件语法检查通过；仍未Xcode编译或真机验收。[本轮完成项、服务地址与证据](docs/APP-A10-MVP-VALIDATION-2026-11-03.md)。

2026-11-03 外部视频实现：`/v2/video-reconstructions` 上传一份外部视频后自动排入独立 FF 与 SfM→3DGS 任务，处理器持久保存进度、下载模型与匹配相机，再提供私有结果下载。成功分支不因另一分支失败而重跑；失败重试保留历史。较早 Windows 临时服务的验证记录见 [自动双重建验证](docs/AUTO-DUAL-VIDEO-VALIDATION-2026-11-03.md)。原生采集现通过 `/v2/captures/:id/reconstructions` 关联同次原片、metadata与核验回执，App接线见上方最新记录。原生 SH3／游览仍待Xcode编译与真机验收；大场景streaming仍待实施。

从 Mac App Store 安装 Xcode，在 Xcode 登录 Apple Account 并选择 Personal Team，连接 iPhone 17 Pro Max 后打开 `ios/PocketWorld.xcodeproj` 编译安装。Windows 上可运行 `powershell -ExecutionPolicy Bypass -File .\scripts\Export-MacHandoff.ps1` 生成不含采集媒体和凭证的 Mac 源码交接 ZIP。逐步操作与真机验收见 [Mac／iPhone 运行指南](docs/MAC-IPHONE-RUN.md)。

App 当前主线源码是扫描 → 本机保存原片及逐帧 ARKit 元数据 → 显式同意上传与双重建 → 服务器核验 RGB 与元数据 → 自动排入 FF／WorldMirror2 与独立 SfM→3DGS → 核对、下载并切换两份结果。成长记录由唯一采集核验回执推进，独立于算法成功与重试。服务端 v2 接口见 [server/README.md](server/README.md)。当前A10固定HTTP地址用于Debug，Release仍要求HTTPS。深度文件仍留在手机；视频／机器人数据验收和 iPhone 真机效果还需后续完成。Windows 项目结构、语法与服务端测试已通过，不等于 iPhone 编译或拍摄成功。

早期 [T0 FF／WorldMirror 视频验证](docs/T0-VIDEO-PILOT.md) 以系统相机视频 → 8／16 帧 → FF 任务和产物为目标；随后已对同一外部视频加跑独立 SfM。下一阶段按 [手机分发与验收方案](docs/FF-SFM-MOBILE-DELIVERY.md) 接入两份结果，不把外部视频服务器成功等同于原生拍摄成功。

2026-11-03 后续实测：用户指定的 Downloads 水杯视频已经分别完成 FF（16 帧、54.5 秒）和用户另行要求的 COLMAP／3DGS-MCMC（64 帧、7,000 步、187.2 秒）。两条均取得真实 PLY，SfM 路线另有 SOG、64/64 注册的相机和实际留出视角渲染。帧数与预算不同，不能当作等条件评测；[结果与接入注意点](docs/VIDEO-FF-SFM-COMPARISON-2026-11-03.md)。原生 App 的真机流程仍需单独验收。

Windows 本机 WSL2 Ubuntu 已安装，Node 24／FFmpeg 和持久业务服务已就绪；VM 内服务端测试 74/74 通过，Windows localhost 健康检查及 VM 到 Hub 的接口访问通过。每次 Windows 重启后运行 `scripts/Start-WSL-Backend.ps1`，脚本会维持一个隐藏的 WSL 保活进程，避免前台命令退出后 VM 自动停止；重复启动只保留一个保活进程。结束测试可用 `wsl --terminate Ubuntu-24.04` 停止这个专用发行版。8 秒合成视频已在 VM 解码并抽取 8 帧；14:28 远端 FF 在切换到 GPU 7 后完成 8 图合成任务，约 65.036 秒达到 `SUCCESS`，33.36 MB PLY 已下载并解析。仅重启独立 `rshub-worker.service`，API 未重启。此次证明运算恢复，真实 iPhone 画质、完整 v2 导回和手机渲染仍待验收，Hub SOG／预览尚未就绪。[恢复与诊断记录](docs/APP-FF-VALIDATION-2026-11-03.md)；[虚拟机测试步骤](docs/WINDOWS-VM-FF-TEST.md)。手机仍需可达的 HTTPS 业务服务器，iOS 编译仍需 Mac 上的 Xcode。

## 历史微信小程序原型

> 2026-10-28 复查：10 月 26 日的 WorldMirror2 测试任务已因等待 GPU 约一小时而失败，尚无真实模型；既有 Codespaces 公网健康检查本次返回 404，原因待排查。下文的上传、测试与预览记录保留原日期，不能代替当前服务或手机验收。见 [最新实测记录](docs/WORLDMIRROR-VALIDATION.md)。

当前拍摄采用本地优先：无需联网即可进入原生相机，保存真实视频，稍后显式提交。域名测试准备支持 GitHub Codespaces 的 HTTPS 开发地址；持续运行的服务使用单实例后端与持久磁盘。详见 docs/CODESPACES.md 和 docs/CLOUD-DEPLOY.md。开发测试素材不代表真机采集成功。

> 当前产品名为「小芽扫描」（此前名：拾境；原型名：口袋世界），首页直接显示应用名、图标和“开始扫描”，陪伴角色为「小芽」。工程目录、GitHub 仓库和数据标识沿用现有名称；微信公众平台的账号名称和头像需在后台单独设置。

> 2026-10-26 用户真机反馈：iPhone 拍摄、上传、新回忆和小芽成长成功。当前默认 GitHub 实例尚未找到对应采集，正在核对手机实际服务地址；手机体验与服务端存储分别验收，见 docs/WEAPP-VALIDATION.md。

> 最新目标（2026-10-26）：**种一颗风景果**。一株植物、三次真实扫描，分别解锁手动播种、浇水、收获；实际封面成为背景，收获物包含本轮真实回忆。用户操作后才推进 0/1/2/3 阶段，奖励由唯一实际上传回执解锁。详见 [三次扫描 Demo](docs/FARM-DEMO.md)。本轮只验证短体验，不开发长线经济和社交系统。

> WorldMirror2 接入（2026-10-26）：新增可恢复的接口适配器与 Windows 出站处理器，沿用原来的私有上传 API，将原视频抽帧、提交 Hub，并在真实模型通过校验后导回原会话。手机回忆页提供独立的重建状态和 3D 入口。处理器必须另行配置并显式启动；当前真实合成素材测试已成功提交，但仍在等待服务器 GPU，不能宣称重建闭环已通过。见 [接入与运行](docs/WORLDMIRROR-INTEGRATION.md) 和 [实测记录](docs/WORLDMIRROR-VALIDATION.md)。

> 当前已按用户反馈改为极简版：打开 → 开始采集 → 拍摄 → 提交 → 查看结果。“导入已有模型”“我的采集”“设置”为次级入口。地图、建造、六任务选择和底部导航已退出主流程；下文早期玩法描述仅供历史参考，数据 API 与人工重建方式继续有效。

当时的原型用真实的室内外一角养大一株小芽，并以微信小程序（WXML / WXSS / JS、camera、Canvas WebGL）在 iPhone 上扫码预览。以下命令和接口说明仅供追溯旧版本；当前路线是上面的原生 iOS App。

**先读 [微信启动与真机验收](docs/WEAPP-START.md)。** 免费测试号可以真机预览。当前工程已配置用户提供的真实测试 AppID；开发工具需由有权限的微信账号登录。复制到其他账号开发时，应换成自己的 AppID。`touristappid` 不能生成可用的手机预览码。

## 本机启动

要求 Node.js 24+。微信开发者工具已安装于 `D:\WeChatDevTools`。后端无需 Docker、GPU 或付费云服务。

```powershell
cd D:\PocketWorld
npm.cmd --prefix server ci
powershell -ExecutionPolicy Bypass -File .\scripts\Start-Backend.ps1 -Lan
powershell -ExecutionPolicy Bypass -File .\scripts\WeChat.ps1 -Action Open
```

手机设置填启动器输出的电脑 Wi-Fi 地址，不能填手机的 localhost。后台进程和日志在 `runtime/`，停止用 `scripts\Stop-Backend.ps1`；切换 LAN 模式也要先停止。开发工具 CLI 服务端口由用户在其安全设置开启。

申请 [微信官方小程序测试号](https://mp.weixin.qq.com/wxamp/sandbox?doc=1) 后：

```powershell
node scripts/Set-WeChatAppId.mjs 你的真实AppID
powershell -ExecutionPolicy Bypass -File .\scripts\WeChat.ps1 -Action Preview
```

成功后 `runtime/wechat-preview.png` 才是本次游戏预览码。登录二维码是另一回事；命令失败时不能把旧二维码当成本次成功。

## 真实闭环

选择室内/室外 → 原生录像（建议约 20 秒，最多 40 秒）→ 持久草稿 → 显式上传并取得唯一回执 → 回首页手动播种/浇水/收获 → 查看真实风景回忆。三次完成一轮，后续真实重建结果仍可由操作者导回对应会话后查看。三步拍摄向导只是引导，不是自动质量评分；微信录像可能包含环境声音。

Scaniverse 路径：先保存探索任务，手动切换 Scaniverse 扫描/处理，将导出的 Gaussian PLY 或 `.splat` 发到自己的微信会话，再从小程序“聊天文件”导入。大文件可交给电脑操作员。`wx.chooseMessageFile` 不是 iOS 通用文件选择器；没有假定 Scaniverse 提供自动 API 或能接收本项目的 MP4。不支持 `.spz`。

只有真实结果才能显示 ready，没有倒计时模拟重建。仅模型导入标记 `external_asset_only`，不宣称拥有同次扫描原视频。手机显示用有损衍生文件，原视频和模型独立保留。双用途训练数据仍需相机估计、尺度、几何、权限等后续验收，模型可看不等于机器人可用。

## 玩法与检查

当前主流程是单株植物的三次扫描：拖种子入土、按住水壶、拖果实入篮。实际封面成为可切换背景，收获页保留本轮真实回忆入口。拍摄可离线，提交与新阶段解锁需要实际服务回执。旧城镇游戏规则保留在代码中作为历史实现，不出现在主界面。

```powershell
npm.cmd test
npm.cmd run check
```

`check` 执行 JS/JSON 和打包边界检查，并使用微信官方 wcc/wcsc 编译 WXML/WXSS；不替代模拟器和真机。执行记录见 [微信验证报告](docs/WEAPP-VALIDATION.md)。

| 目录 | 内容 |
|---|---|
| `miniprogram/` | 城镇、探索、相机、邮袋、设置、3D 查看 |
| `miniprogram-tests/` | 游戏/API/持久化/渲染测试 |
| `project.config.json` | 小程序代码根目录、AppID、开发配置 |
| `server/` | 私有 API、SQLite、真实文件、人工处理 CLI |
| `docs/WEAPP-START.md` | 扫码启动、完整验收和故障处理 |
| `docs/WEAPP-CONTRACT.md` | 当前接口与实现边界 |
| `ios/` | 原 SwiftUI 工程，当前无需使用 |

后端操作详见 [server/README.md](server/README.md)。交接源码应排除 `server/data/`、`server/.local-config.json`、`runtime/`、`work/`、`exports/` 和所有私有采集包。管理员凭证只留本机，不填写到小程序。

</details>
