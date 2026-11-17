# 口袋世界：本机后端与人工重建操作台

这是可在 Windows 上运行的 Node.js 服务，不是玩家网页。当前优先开发同项目的原生 iPhone 扫描 App；旧微信小程序与 v1 接口仍供历史验证。服务提供视频/模型文件流转、私有会话、处理状态、卡片领取、存档备份和实验日志。WorldMirror2 FF 重建需要操作者显式启动独立 worker；服务进程本身不会按倒计时生成结果，也不会在无 worker 时自动执行 GPU 任务。

## 启动

需要 Node.js 24 或更新版本；数据库使用内置 SQLite。首次运行安装锁定的流式 multipart 解析依赖 Busboy 1.6.0：

```powershell
Set-Location D:\PocketWorld
npm --prefix server ci
node server/index.mjs
```

默认监听 `http://127.0.0.1:8787`，健康检查为 `GET /health`。首次启动自动生成 `server/.local-config.json`，含独立管理员随机凭证；不要提交、分享或复制进玩家客户端。SQLite、原始视频、模型保存在 `server/data/`。相对路径不依赖执行命令时的工作目录。

环境变量：

| 变量 | 用途 |
|---|---|
| `HOST` | 默认 `127.0.0.1`；同一受信局域网内手机联调可显式改为 `0.0.0.0` |
| `PORT` | 默认 `8787` |
| `DATA_DIR` | 数据目录；相对路径以 `server/` 为基准 |
| `POCKETWORLD_CONFIG` | 本地 JSON 配置文件路径 |
| `ADMIN_TOKEN` | 可选替换管理员随机凭证，至少 32 个 URL-safe 字符 |
| `POCKETWORLD_URL` | 仅操作 CLI 使用，覆盖服务地址 |

`localhost` 仅指运行服务的设备，iPhone 中必须填写开发电脑可达的局域网地址或实际部署域名。服务不自动打开 Windows 防火墙、不创建公网隧道。默认 HTTP 只适合受信局域网调试；远程试验需配置 HTTPS。原始视频、模型及管理员凭证不应经过不受信网络的明文传输。

## 玩家接口

见 [CONTRACT.md](../docs/CONTRACT.md)。匿名登录创建随机用户 token，数据库只保存 hash。所有会话、预览、模型下载、日志和存档按用户隔离。管理员 token 无法冒充玩家 token，普通玩家 token 不能调用管理员接口。

### 外部视频自动 FF + SfM→3DGS

实现与 Windows 实测见 [自动双重建验证](../docs/AUTO-DUAL-VIDEO-VALIDATION-2026-11-03.md)。使用同一个玩家 Bearer token；与 ARKit capture、旧视频游戏和人工导入 studies 独立。

| 请求 | 语义 |
|---|---|
| `POST /v2/video-reconstructions` | `{id,title,consentVersion:"2026-11-03-video-dual-v1",expectedSha256,expectedByteSize}`，固定 UUID 创建来源记录 |
| `PUT /v2/video-reconstructions/:id/video` | MP4/MOV 原始字节；核对 SHA-256／大小／容器后一次事务排入 FF、SfM 两任务，相同上传不重复排队 |
| `GET /v2/video-reconstructions`、`GET /v2/video-reconstructions/:id` | 列表 `reconstructions`／详情 `reconstruction`，含两条独立 `tasks` 和 `previousAttempts` |
| `POST /v2/video-reconstructions/:id/retry` | `{failedTaskId,id:<新稳定UUID>}`，仅重试已失败分支，归档旧 attempt；重复请求幂等，blocked 未知写入不允许重试 |
| `GET /v2/video-reconstructions/:id/results/:taskId/file`、`.../cameras` | 所有者鉴权下载不可变结果，文件支持 Range；清单有文件大小与 SHA-256 |
| `DELETE /v2/video-reconstructions/:id` | 删除业务原片／结果／任务，保留来源墓碑并禁止晚到产物复活 |

业务 API 排队，独立 worker 执行。运行 `node server/tools/dual-reconstruction-worker.mjs --config <私有JSON> --watch`；`--once` 供受控测试或调度器调用。配置、运行日志、视频及密钥放在忽略目录，不发给客户端。worker 用 FFmpeg 从本次上传字节选帧；FF 默认16帧、SfM默认64帧；远端计算与模型／相机校验全部成功才发布 ready。

当前相机读取由受控服务端 SSH 助手完成；手机只使用业务 API。API DELETE **尚未清理 worker 私有工作目录和远端 Hub 资产**，需要运维单独按来源清理；不宣称全链路擦除。该验证服务不是稳定公网部署，原生 App 对新任务列表的交互适配仍待完成。

### 原生 iPhone v2 采集包（首个纵切）

原生 App 先以 `POST /v1/auth/anonymous` 获取玩家 token，后续每次请求带 `Authorization: Bearer <token>`。客户端在拍摄前生成并持久保存 UUID；断网或重启后继续使用同一个 ID。以下接口与 v1 会话独立，旧接口语义不变。

| 请求 | 内容与结果 |
|---|---|
| `POST /v2/captures` | JSON `{"captureId":"UUID","sceneId":"可选 UUID","environment":"indoor|outdoor|unknown","consentVersion":"版本"}`；创建返回 201，同一内容重试返回 200 |
| `PUT /v2/captures/:id/rgb` | 原始 MOV/MP4 字节，`Content-Type: video/quicktime` 或 `video/mp4`，以及小写十六进制 `X-Content-SHA256`；返回 200 |
| `PUT /v2/captures/:id/metadata` | `Content-Type: application/json`，同样的 SHA-256 头；JSON 为 `{"manifest":<manifest.json 对象>,"framesJSONL":"<frames.jsonl 原样 UTF-8 文本>"}`；返回 200 |
| `POST /v2/captures/:id/complete` | JSON `{}`；重新核对服务端保存的文件哈希、视频容器结构、清单哈希、逐帧索引、严格递增时间、位姿和内参后返回回执 |
| `GET /v2/captures/:id` / `GET /v2/captures` | 查询单条／当前玩家全部草稿与回执，供断网重试 |
| `GET /v2/captures/:id/rgb` / `GET /v2/captures/:id/metadata` | 鉴权下载已存原片和上传的元数据，原片支持单一 byte range |
| `DELETE /v2/captures/:id` | 删除原片、元数据和记录；ID 留墓碑，不允许再次创建 |

所有响应中的采集资源放在 `capture` 字段；列表放在 `captures` 字段。上传和完成可使用相同内容重试，冲突字节返回 409。完成后 `capture.status` 和 `receipt.scope` 均为 `rgb_metadata_verified`，唯一 `captureReceiptId` 在重复完成和服务重启后不变。`receipt.decodeVerified:false` 明确表示当前仅检查视频容器结构，尚未实际解码。

首个纵切仅上传 RGB 视频与逐帧元数据。清单可携带 LiDAR 深度／置信度文件引用，但**尚未上传或核对深度字节**；有深度引用时回执为 `depthStatus:pending_upload`，不能据此宣称 RGB-D 采集包通过。v2 完成回执本身不会自动排队 FF；需显式申请下述任务并启动 worker。当前没有分段续传、成长奖励或管理员导出 v2 包。视频上限 500 MiB，元数据上限 16 MiB；应先用短录制验证真实 iPhone 上行。服务部署到手机可达的 HTTPS 后才能进行公网测试。

### 原生 v2 采集接入 FF 预览

`POST /v2/captures/:id/ff` 发送 JSON `{}`，仅在同一用户的 v2 采集已经完成 RGB 与元数据核验后创建 FF 任务。首次返回 `201`，相同采集重复请求返回 `200`，不会创建第二个任务。`GET /v2/captures/:id/ff` 在尚未申请时返回 `{ "ff": null }`；已申请时返回：

```json
{
  "ff": {
    "captureId": "源采集 UUID",
    "jobId": "FF 任务 UUID",
    "status": "queued"
  }
}
```

`status` 来自真实持久任务，可能为 `queued`、`processing`、`ready`、`failed` 或 `cancelled`。`failed` 可含 `errorMessage`。只有真实模型导入并通过 Gaussian 结构检查后才有 `ready`，并增加 `assetId`、同源相对路径 `viewerInfoPath` 和 `viewerPath`。这些路径是现有按用户鉴权的 `/v1/assets/:id/viewer-info?maxPoints=60000` 和 `/v1/assets/:id/viewer?maxPoints=60000`；前者返回顶层 `sha256`、`byteSize`、`pointCount` 等展示派生文件信息。手机应逐次带自己的 bearer token 下载、核对字节数与 SHA-256，再交给本机查看器。FF 状态与采集回执分离；采集成功不表示重建成功。

服务为 FF 任务创建一个内部 v1 处理会话，**引用同一份 v2 原视频路径与 SHA-256，不复制或改写原片**。会话记录 `linkedCaptureId`、核验回执、元数据 SHA-256、`provenance:device_capture_v2_verified`，worker 仍通过原有受保护管理员路由下载并核对视频。原生客户端不能通过旧 v1 路由改写、领奖或单独删除该内部会话；删除源 v2 采集会移除关联任务和已生成的本服务资产，旧查看地址随即失效。worker 在下一次来源检查时停止后续导入；已送往 Hub 的图片资产和 worker 私有缓存仍须按试验保留与删除流程单独处理。

首个 FF 预览由操作者启动 `node server/tools/worldmirror-worker.mjs --watch --config <私有配置绝对路径>`；具体配置见 [WorldMirror 接入说明](../docs/WORLDMIRROR-INTEGRATION.md)。手机只连接本服务的 HTTPS 地址，不携带管理员或 Hub 凭据。当前 FF 选帧使用原视频均匀抽帧，最多 8 或 16 帧，v2 的 ARKit 位姿／内参作为已核验同源元数据保留，尚未传给 WorldMirror 作相机先验。传统 SfM 是后续独立算法，不参与此预览闭环。

原生采集路径：

1. 客户端创建 UUID 会话（一次创建，多次重试使用原 ID）。
2. `POST /v1/sessions/:id/video` 用微信 `wx.uploadFile` 上传实际 `.mov` 或 `.mp4`；可附 JPEG 预览。原客户端仍可使用原始二进制 `PUT`。
3. `POST /v1/sessions/:id/submit` 提交客户端实测的时间、时长、分辨率、帧率，生成 `queued` 人工任务。
4. `POST /v1/sessions/:id/reward` 可领基础卡片。同一会话只领取一次，处理失败不撤销。
5. 操作员导出本次源数据，用支持该输入的工具真实重建，再上传本次结果。
6. 客户端刷新状态，鉴权下载用于小程序 WebGL 查看器的 `.splat` 衍生文件；原始重建结果独立保留。

外部扫描路径：

1. 创建 `external_app` 会话，保存任务关联。
2. 用户自行打开 Scaniverse 等工具进行实际采集/处理、导出 Gaussian PLY。
3. `POST /v1/sessions/:id/asset?format=ply&tool=实际软件名` 用 multipart 导入该次扫描文件；仍兼容原始二进制 `PUT`。
4. 基本格式校验通过才进入 `asset_imported`、`ready` 并允许领卡。

外部导入记录为 `external_asset_only`，`rawDataAvailable=false`。后端不会将模型渲染视频、另拍的视频或一个 PLY 文件宣称为同一次具有轨迹的采集母数据。Scaniverse 是否接收普通手机 MP4 不是本项目的假设；原生视频转外部重建需要操作者选择实际支持的工具。

### 微信上传与音轨/FPS 声明

`POST /v1/sessions/:id/{video,preview,asset}` 接收 `multipart/form-data`，**恰好一个名为 `file` 的文件，不含其他表单字段**。资产格式、工具与版本仍使用 URL 查询参数。每次 `wx.uploadFile` 带本人 `Authorization: Bearer <user token>`，不要手填 multipart boundary。服务流式落盘，不把整个视频装入内存；文件 hash 只计算文件字节，不包含 multipart 包装。POST 和 PUT 的会话权限、格式校验、幂等及大小限制一致。

视频 part MIME 为 `video/mp4` / `video/quicktime`；当微信仅发送 `application/octet-stream` 时允许从 `.mp4` / `.mov` 文件名推断 MIME，然后仍检查容器结构。JPEG 同理。文件名不作为存储路径使用。

`submit` 仍提交 `capturedAt,durationSeconds,width,height,fps`。新增可选字段：

| 字段 | 允许值与含义 |
|---|---|
| `fpsSource` | `client_reported`：fps 为客户端获取的实际 1–240 数字；无法取得时必须为 `unknown` 且 `fps:null`。旧客户端省略时默认 `client_reported` |
| `audioPolicy` | `not_recorded` / `may_contain_audio` / `unknown`；省略默认 `unknown`。微信 camera 没有可靠静音保证时必须填 `may_contain_audio` |

服务保存 `audioPolicySource:client_reported`，不会把声明当成音轨解码检测。提交后的元数据不可用重试改写。导出的 manifest 包含这些真实来源和未知值。

### 小程序查看器衍生文件

| 接口 | 返回 |
|---|---|
| `GET /v1/assets/:id/viewer-info?maxPoints=60000` | 衍生格式/版本、原资产 ID 与 SHA-256、原始/展示点数、文件 SHA-256 与字节数、损失说明 |
| `GET /v1/assets/:id/viewer?maxPoints=60000` | 32 字节/点的 `.splat`，支持单一 byte range |
| `GET /v1/assets/:id/file` | 未转换的原始文件，保留原 hash |

三个接口均要求资产所有者的 token。`maxPoints` 默认 60,000，仅允许 10,000 / 30,000 / 60,000 / 100,000，以限制内存及缓存数量；60k 文件最多 1.92 MB。原文件逐条校验后，以 `floor(outputIndex × originalCount / outputCount)` 按源顺序确定性采样。Gaussian PLY 转换使用 `exp(logScale)`、`0.5 + 0.28209479177387814 × f_dc` 的 SH0 颜色、sigmoid opacity，以及归一化 wxyz quaternion；RGBA/旋转量化为字节。已有 `.splat` 保留选中记录的原字节。

32 字节布局：位置 float32[3]（偏移 0）、线性尺度 float32[3]（12）、RGBA uint8[4]（24）、四元数 wxyz uint8[4]（28）。四元数以 `(byte−128)/128` 解码后重新归一化。颜色/透明度/四元数字节按四舍五入并夹在 0–255。

`viewer-info` 明确返回 `lossy:true, rendererOnly:true`，高阶 SH 不进入查看衍生文件。下载头含 `X-Content-SHA256`（衍生文件）、`X-Source-SHA256`、`X-Source-Asset-ID`、`X-Viewer-Format:splat`、`X-Viewer-Version:splat-sh0-v1`、`X-Point-Count`、`X-Renderer-Only:true`。文件及 `.json` sidecar 缓存于所属会话目录，删除会话时一并移除。转换不提升质量状态，不推断尺度/位姿/碰撞几何，也不构成训练数据验收。

## 操作者：从待处理到返回真实模型

以下命令在 `D:\PocketWorld` 执行，不需要把管理员 token 粘贴到命令行：

```powershell
node server/admin.mjs jobs
node server/admin.mjs export SESSION_ID D:\PocketWorld\work\source-export-001
node server/admin.mjs start JOB_ID
```

`export` 要求目标是**尚不存在的新目录**，防止覆盖别的采集。输出：

```text
manifest.json
capture.mov 或 capture.mp4     # 仅原生源视频存在时
preview.jpg                    # 仅客户端上传过时
events.jsonl
processing.json
result/scene.ply 或 scene.splat # 仅实际结果存在时
result/quality.json            # 仅资产存在时
```

下载原文件时校验 SHA-256。manifest 明确标注视频元数据来自客户端、缺少的相机轨迹/内参/尺度/碰撞几何；不生成虚假的 `camera.jsonl`。

在外部软件完成对这个会话的真实处理后：

```powershell
node server/admin.mjs import JOB_ID D:\YourResult\scene.ply --tool ActualTool --version ActualVersion
```

记录真实软件与版本。导入按会话和文件 hash 幂等：相同文件重试不重复资产，不同文件不能覆盖已有结果；补采应新建关联原会话的 session。文件可加载只表示结构通过，质量仍为 `needs_review`，来源关系为 `declared`，双用途为 `not_evaluated`。

处理失败、重试：

```powershell
node server/admin.mjs fail JOB_ID "视角重叠不足，外部工具未完成重建"
node server/admin.mjs retry JOB_ID
```

质量复核后单独记录：

```powershell
node server/admin.mjs review ASSET_ID --quality accepted --lineage verified --dual-use partial --notes "已核对源视频与结果；视觉回放通过。无可靠相机轨迹和碰撞几何，双用途尚未验收。"
```

`verified` 是人工审查记录，不是自动识别来源。当前没有可靠相机轨迹和碰撞几何的接入/校验能力，所以 API **拒绝将双用途直接设为 accepted**。可标记 `not_evaluated` / `partial` / `rejected`。

日志与计数：

```powershell
node server/admin.mjs events D:\PocketWorld\work\pilot-events.jsonl
node server/admin.mjs metrics
```

计数是运营日志而非质量/留存结论；客户端与服务端可能有同名事件，漏斗分析需按用户、会话去重。纯建设返回须用游戏事件另算。导出的样本/日志包含私有研究数据，只发给获授权的研究者。

## 管理员接口

全部以 `Authorization: Bearer <admin token>` 保护，CLI 已负责读取配置。

| 方法与路由 | 行为 |
|---|---|
| `GET /v1/admin/jobs` | `jobs: [SessionEnvelope]` 待处理与历史处理记录 |
| `GET /v1/admin/sessions/:id/bundle` | 元数据、处理记录、事件、质量以及受控文件地址 |
| `GET /v1/admin/sessions/:id/video` | 原视频，支持单一 byte range |
| `GET /v1/admin/sessions/:id/preview` | JPEG |
| `GET /v1/admin/assets/:id/file` | 原模型文件 |
| `PUT /v1/admin/jobs/:id/status` | JSON `status: queued/processing/failed/cancelled`，失败需 `errorMessage`；不能手填 ready |
| `PUT /v1/admin/jobs/:id/asset?format=ply&tool=...&version=...` | 原始二进制模型；校验成功才能 ready |
| `PATCH /v1/admin/assets/:id/review` | `qualityStatus,lineageStatus,dualUseStatus,notes` |
| `GET /v1/admin/events` | `events` 数组，含匿名用户 UUID |
| `GET /v1/admin/metrics` | 样本模式、室内外、处理/质量状态、事件计数 |

## 格式、限制与真实能力

- 视频最多 500 MiB；JPEG 最多 5 MiB；模型最多 150 MiB 且最多 1,000,000 个 Gaussian。手机建议先用更小的结果测内存与帧率。
- Gaussian PLY 支持 ASCII / binary little endian；必须有 float32 的 `x/y/z`、`f_dc_0..2`、`opacity`、`scale_0..2`、`rot_0..3`。普通 XYZ/RGB 点云不是本入口的高斯模型。
- 匹配所选 MetalSplatter 版本，高阶 SH 要么省略，要么有全部 float32 `f_rest_0..44`；部分 SH1/SH2 导出需先转兼容格式。
- 逐条检查 Gaussian 字段数量、有限数值、旋转非零、声明记录数/实际长度；`.splat` 按 32 字节记录校验。首版不接收 SPZ，不按改扩展名方式转换。
- 视频检查 QuickTime/MP4 顶层 box 长度和 `moov/mdat` 存在。**不是完整解码检测，不证明视频可用于重建。**时长、分辨率、fps 保留客户端报告来源。真实播放/重建/画质仍需操作员与真机验证。
- 当前无 ARKit 轨迹接入，无离线 SfM，无碰撞网格，无机器人策略训练或视频模型训练。数据字段如实留空/未验证。
- 文件通过临时路径流式写入，数据库使用 SQLite WAL，单会话操作串行化。同一 ID 不能变成其他来源；提交/领卡/相同文件重试幂等。
- 删除本人 session 会清理其视频、预览、模型、查看衍生文件与 sidecar、处理记录、事件及子会话父引用；游戏备份中的源引用清空，虚拟建筑可保留。为防重放，仅保留最小删除标记与奖励账本。操作者已经手工导出的外部副本不可能由本地 API 自动撤回，需纳入试验者自己的删除流程。
- 适用于小规模内测的单进程服务。暂不含断点续传、分布式锁、生产账号恢复、自动配额、自动重建或自动供应商回调。失败上传可重新提交完整文件，原始手机文件应保留。

## 测试

### 原生采集自动双重建（2026-11-03）

完成 `/v2/captures/:captureId/complete` 后，可调用：

- `POST /v2/captures/:captureId/reconstructions`，JSON `{ "consentVersion": "2026-11-03-native-dual-v1" }`。首次返回 201，再次相同操作返回 200；均为 `{reconstruction}`。
- `GET /v2/captures/:captureId/reconstructions` 返回 `{reconstruction:null}` 或已有任务。需原采集拥有者 bearer token。
- `POST /v2/video-reconstructions/:id/retry`，JSON `{ "failedTaskId": "旧任务UUID", "id": "新的稳定UUID" }`，仅显式重试已失败分支；未知远端写入状态不能重试。成功分支及历史失败记录保留。

每个原生 capture 仅产生一个稳定 reconstruction，以及独立 FF / SfM 两个任务。返回对象的 `sourceKind` 为 `native_arkit_capture`，包含 `captureId`、`captureReceiptId`、`sourceVideoSha256`、`sourceByteSize`、`sourceMetadataSha256`、`sourceMetadataByteSize`；其余任务、重试历史和结果描述符沿用视频双重建协议。结果私有地址仍为 `/v2/video-reconstructions/:reconstructionId/results/:taskId/file` 和 `/cameras`。其中一个结果就绪即可使用，不等待另一分支。

桥接直接引用已验证的服务端原始视频和原始 metadata 文件，不重新上传或转码。入队及发布核对文件哈希、大小、metadata schema 与原采集回执；worker 获得原生来源标记、原始 metadata 路径/哈希/大小，发布时保存完整来源记录。算法相机与 ARKit 原始 pose 仍分别保留，不能宣称已对齐或尺度已验证。当前 metadata 内的深度引用可能仍为 `pending_upload`，不能当作已上传深度数据。

双任务、算法成功及重试均不生成新的成长回执。成长仍仅按唯一原生 `captureReceiptId` 去重；外部 RGB 视频继续标注 `external_rgb_video`，不计为原生 ARKit 采集。现有 `/v2/captures/:id/ff` 兼容接口保持可用。

`DELETE /v2/captures/:id` 在一个数据库事务内删除原生采集、旧 FF 链接、双任务及重试历史，保留删除标记，然后清理 API 管理的原片、metadata 和结果文件。迟到的 worker 不能复活结果。原生双任务不能单独通过视频重建 DELETE 接口删除；应删除原采集。worker 工作目录和远端供应商副本须按部署侧清理策略处理。

本合同与合成测试验证接口和来源完整性，不代表 ARKit 原片已经真实拍摄、模型已经在 iPhone 上渲染，或机器人/视频训练数据已验收。

```powershell
Set-Location D:\PocketWorld\server
npm test
```

测试会在系统临时目录启动独立服务，自动清理测试数据，不污染内测数据库。覆盖鉴权与跨用户隔离、原生/外部导入链路、并发幂等、无效文件、大小限制、失败/重试、质量分离、重启持久化、数据删除、受控导出和实际 CLI 操作；另覆盖 multipart/chunked 超限、边界损坏、临时文件清理、SH0/尺度/透明度/旋转转换的实际数学结果、确定性采样、原 hash 与衍生 hash、衍生文件鉴权及删除。测试 Gaussian、视频都是明确标注的合成夹具，**不作为真实采集、真实重建或 iPhone 验收证据**。
