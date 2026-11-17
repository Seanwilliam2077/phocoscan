# WorldMirror2 接入与操作说明

> 2026-11-02：已从本部署的一次独立合成 GPU 任务和其结果 step 核实真实终态为 `SUCCESS`，并下载通过结构校验的 Gaussian PLY。可在该已核实部署的显式测试运行中设置 `WORLDMIRROR_SUCCESS_STATUS=SUCCESS`；默认仍保持未确认即拒绝下载。该结果不代表 iPhone 实景质量。见 [T0 实测记录](T0-VALIDATION-2026-11-02.md)。

> 2026-11-03：原生 App 的 v2 采集回执现可通过 `POST /v2/captures/:id/ff` 显式创建一个内部关联任务；现有 Windows worker 从同源原视频处理，结果回填后由 `GET /v2/captures/:id/ff` 给出真实状态及鉴权查看路径。此代码已通过合成链路测试，仍待 Xcode 真机、真实 iPhone 视频与远端 FF 端到端验收。SfM 不在本阶段。

本文说明当前 operator 工具的边界和使用方式。实际服务的验收结果由单独测试报告记录；合成接口测试、手机上传成功、模型结构校验和真实重建成功是不同证据。

## 1. 旧 v1 小程序拓扑（操作员参考）

```text
iPhone 微信小程序
  └─ 用户鉴权 HTTPS → 现有私有 PocketWorld 后端
                         ├─ 保存原视频、session、任务及真实奖励回执
                         └─ 管理员鉴权接口 ← Windows outbound worker
                                                ├─ 下载并核验自己的原视频
                                                ├─ FFmpeg 抽取有限张图片
                                                └─ 请求 RealityScan Hub / WorldMirror2
                                                     ↓ 真实成功、来源核验、PLY 校验
                         原任务导入接口 ← Windows worker
                         └─ 手机原生 viewer 查看派生结果
```

当前观察是：云端执行环境直连 Hub 超时；Windows 能分别访问现有云端后端和 Hub。因此由 Windows 主动连接两端，不要求云端直接访问 Hub，也不需要为 worker 开放入站端口。Windows 停机时任务不会继续由此 worker 处理。

iPhone Safari 能读取 Hub 的 HTTP 接口，只证明该设备当时的浏览器网络可达。它不证明正式微信小程序允许该 HTTP 地址、域名已配置，或微信上传/下载已经验收。玩家继续使用现有后端；生产部署应使用有效 HTTPS、微信相应合法域名和私有鉴权。不要把管理员凭据、Hub 凭据或内网地址放进小程序包。

Codespaces 仍是开发预览后端，不能当作持续在线托管服务承诺。

## 2. 已实现与尚未验证

已实现 operator 路径：选定已提交的原生 RGB 任务 → 按原始 SHA-256 下载视频 → FFmpeg 抽帧 → images asset → quick-reconstruct → 查询固定 project/step → 校验输入来源 → 下载、校验 Gaussian PLY → 导回原任务。接口回执和农场成长规则不变；重建失败不会制造新奖励或撤销已有虚拟成长。

2026-11-02 的独立合成任务已核实本部署的真实成功状态 `SUCCESS` 和成功 PLY。`successStatus` 默认仍为 `null`，避免把其他部署或未知状态误认成成功；操作者在确认目标部署后显式设置。选定的 `step.status` 和 `result_step.status` 必须同时等于已核实的成功值，且产物仍需做来源与结构校验。

现在可从原生 v2 核验回执创建关联 FF 任务。关联会话保存源采集 ID、回执和元数据哈希，worker 引用同一份原视频字节并核验视频哈希；v2 的 ARKit 位姿和内参仍只保留在原始元数据中，**尚未作为 WorldMirror2 的相机先验输入**。SfM 精建、相机标定、深度/碰撞几何、机器人训练验收和视频模型训练验收仍待完成。WorldMirror2 结果的尺度与坐标不能擅自标记为公制或真实世界坐标。

## 3. 准备工作

- Node.js 24 或更新版本。
- 已存在、可访问的 PocketWorld 后端及独立管理员配置。玩家 token 不能替代 admin token。
- Windows 能访问配置的 Hub origin；只接受 HTTP(S) origin，不含用户名、密码、路径或 query。
- FFmpeg 可执行文件的绝对路径，通过私有配置 `ffmpegPath` 或环境变量 `FFMPEG_PATH` 提供。worker 不自动安装软件。
- 私有配置、原视频、抽帧、产物和 manifest 均放在项目已忽略的 `work/` 下，且不要手工加入 Git。
- 初次仅选择一个已明确授权处理的原生任务。`--watch` 会主动领取符合条件的排队任务，应在确认其范围后使用。

独立 Hub CLI 的只读检查：

```powershell
Set-Location D:\PocketWorld
$env:WORLDMIRROR_URL = 'http://reconstruction.example.test'
node server/tools/worldmirror.mjs doctor
```

`doctor` 只 GET capabilities，不创建组、不上传媒体、不启动 GPU 任务。它检查 `available:true`、`type:gs_worldmirror2` 和 `engine:worldmirror2`，不证明一次重建能够成功。需要 Hub 鉴权时，安全提供 `WORLDMIRROR_TOKEN` 环境变量；不要把实际凭据写进命令参数或本文示例。

## 4. Windows worker：完整原视频路径

在 `D:\PocketWorld\work\worldmirror-worker.json` 创建私有配置。以下域名和路径为占位，必须替换成已核实的配置；`adminConfigFile` 指向已有且包含 `adminToken` 的 operator 私有配置。

```json
{
  "backendOrigin": "https://capture.example.test",
  "adminConfigFile": "D:\\PocketWorld\\work\\operator-admin.json",
  "providerOrigin": "http://reconstruction.example.test",
  "workDir": "D:\\PocketWorld\\work\\worldmirror-bridge",
  "ffmpegPath": "D:\\tools\\ffmpeg\\bin\\ffmpeg.exe",
  "frameCount": 8,
  "successStatus": null,
  "timeoutMs": 30000,
  "downloadTimeoutMs": 120000,
  "ffmpegTimeoutMs": 90000,
  "pollIntervalMs": 15000
}
```

可选字段：

| 字段 | 含义 |
|---|---|
| `providerTokenEnv` | 保存 Hub 凭据的环境变量名称；不是凭据值。无此鉴权需求时省略。 |
| `providerVersion` | 已确认的实际 provider 版本；未知时省略，导入记录不捏造版本。 |
| `successStatus` | 经独立核验的终态成功枚举；未核验时保持 `null`。 |
| `groupId` | 明确指定的既有组；通常省略，让每次运行使用独立组。 |
| `frameCount` | `8` 或 `16`，默认 `8`。这是采样上限，不是覆盖率或质量分数。 |
| `maxVideoBytes` | worker 默认原视频上限 80 MiB，可显式配置，不能超过后端 500 MiB 上限。 |

worker 也支持用 `WORLDMIRROR_SUCCESS_STATUS` 提供已核验成功值。未产生输出/导入意图的旧 `null` 配置可以首次绑定该值；其他配置不变且已有非空契约不得静默更换。

先运行一个明确任务；将 `<job-uuid>` 替换为管理员任务列表中的目标 job ID：

```powershell
node server/tools/worldmirror-worker.mjs --once --job-id '<job-uuid>' --config 'D:\PocketWorld\work\worldmirror-worker.json'
```

`--once` 推进该任务一轮。如果 provider 仍在等待或运行，返回持久化状态，再次执行同一命令会继续原任务，不会另建一个重建任务。首次抽帧使用真实视频解码，均匀 fps 采样，最长边不超过 1024；记录视频来源、采样方法、帧名、大小和 SHA-256。采样时长来自已有提交元信息，当前未生成逐帧准确 PTS、标定或位姿。

需要持续处理时显式启动：

```powershell
node server/tools/worldmirror-worker.mjs --watch --config 'D:\PocketWorld\work\worldmirror-worker.json'
```

也可给 `--watch` 加 `--job-id` 限定一个任务。未传 `--once` 或 `--watch` 只显示帮助。轮询间隔允许 5–60 秒；Ctrl+C 在当前有界操作结束后退出，不代表立刻取消 Hub GPU 任务。

worker 仅开始排队的原生采集任务，或恢复自己已持久化认领的 processing 任务。已有其他 operator 的 processing 任务不能无凭据接管。源身份、后端、provider、采样配置等绑定在 manifest 中；不要复用某次运行目录处理另一份视频。

## 5. 独立 Hub CLI：只测试图片到 PLY

该 CLI 不连接 PocketWorld 后端，不会自动把结果关联到玩家 session。明确选取的目录只放本次要上传的 2–32 张 JPEG/PNG；每张最多 20 MiB，总量最多 256 MiB。

```powershell
node server/tools/worldmirror.mjs upload --files 'D:\PocketWorld\work\selected-frames' --run-dir work/operator-run --name 'operator-explicit-frames'
node server/tools/worldmirror.mjs quick --run-dir work/operator-run
node server/tools/worldmirror.mjs resume --run-dir work/operator-run --max-wait 30 --poll 2
node server/tools/worldmirror.mjs inspect --run-dir work/operator-run
```

`upload` 默认创建本次独立组；`--group-id '<group-id>'` 只用于明确选择的既有组。`quick` 使用已落盘的 `request_id` 提交一次。`resume` 默认只查询一轮；单次等待参数最多 300 秒，每个请求仍有独立超时。`inspect` 只读本地 manifest，不访问网络。

核验真实终态枚举之后，独立 CLI 通过 `WORLDMIRROR_SUCCESS_STATUS` 配置该值。未配置时，存在产物也会停留在 `awaiting_success_contract`。既有 `null` 契约可以首次绑定已核验值；已绑定的非空值不能静默更换。不要使用 `RUNNING`、`PENDING` 等运行状态绕过检查。

成功支路还会 GET 固定的 `/api/projects/{projectId}/3dgs/inputs`，核对 images asset ID、group、帧数、准备状态和 revision；revision 必须与选定 step 的 `params.input_revision` 一致。查询与下载都显式带 `algorithm=gs_worldmirror2` 和固定 `step_id`，不会跟随响应中任意下载 URL。

下载保留原始 PLY，检查大小上限及现有 `validateGaussian` 结构规则。无效文件不导入，不会转换成虚假的成功状态。通用点云 PLY、超过 importer 上限或不兼容的 SH 属性均可能被拒绝，需要保留原产物并单独评估兼容方案。

## 6. 持久化、未知结果与恢复

worker 每个 job 的私有目录包含 `bridge.json`、原来源 manifest、原视频、抽帧目录，以及 `provider/manifest.json` 和真实下载产物。provider manifest 保存请求 ID、已确认的 group/images/project/step IDs、输入哈希和状态，不保存认证头或完整内部响应。

远端写入前先保存操作意图，并重新检查源任务仍然有效。组创建等待期间发生取消/删除，会阻止下一次 images 上传；组创建期间本地帧被修改，也会阻止以旧哈希上传。原视频和已提交的原始元信息不被重建覆盖。

| 状态/情形 | operator 操作 |
|---|---|
| 正常运行、等待 GPU | 对同一运行目录执行 `resume`，或继续同一 worker job。 |
| 只读查询/传输暂时失败 | 保留目录；修复网络后继续。worker 的暂时网络失败进入 `retry_wait`。 |
| `group_unknown` / `images_unknown` / `quick_unknown` 或 `*_pending` 残留 | 停止自动写入，对账；不要删除 manifest 后重跑。 |
| 后端 processing 认领响应未知或发生并发冲突 | worker 进入 `blocked`；operator 核对任务归属，必要时明确重新排队。仅有本机 manifest 不代表已认领，不能据此继续上传或把别人的任务改为失败。 |
| 已下载但进程中断 | 保留原文件；恢复会校验既有文件，避免无理由重下或替换来源。 |
| 导入响应丢失 | 下一轮读取后端任务/资产，按同一输出 SHA-256 确认，不创建另一份结果。 |
| `awaiting_success_contract` | 独立确认实际成功枚举后配置，再继续原 project。 |
| 输入/来源/hash 冲突 | 停止并调查；不能靠改 manifest 中的 ID 或 hash 强行通过。 |

未知写入对账流程：保全 manifest → 在服务端核对本次组名、已有 IDs、`request_id`、图片数量/哈希及 project/step → 确认是否已产生副作用。images 和新建组没有已确认的幂等键；quick 虽携带固定 request ID，也不在响应未知时盲目重放。当前没有自动 reconcile 命令，需依据真实服务记录由开发/operator 完成有证据的状态恢复。不能把未收到响应等同于“服务器没有执行”。

## 7. 删除、取消与数据保留

后端任务被取消或源 session 被删除后，worker 停止后续桥接，不能再导入结果。后端导入在同一 session 锁下检查取消状态；取消任务需显式重新排队，不能直接改回 processing。普通停止 worker 不会擅自取消或删除 Hub 工作。

**目前删除未覆盖全部外部副本。** PocketWorld 的源删除不会自动清除 Windows worker 缓存、Hub 图片资产、Hub project 或组。worker 保留这些私有文件和远端 IDs 供恢复与人工清理，因此不能向玩家声称“一次删除已清除所有副本”。

本机人工清理时，先停止处理该 job 的 worker，依据私有 `bridge.json` 核对源 session、视频哈希和准确的 `<workDir>/<job-uuid>` 目录。清点其中原视频、帧目录、provider 原始产物和临时文件；另存最小必要的远端清理 IDs 后，再删除经过核实的该 job 缓存目录并检查残留。不要凭模糊名称递归清空整个 `work/`，也不要在 worker 仍写入时删除。当前没有自动缓存清理或可验证的完整删除回执。

当前 Hub OpenAPI 未提供已确认的 images asset DELETE 接口。project/组删除也可能拒绝包含运行中 step 的任务。operator 应向 Hub 管理员确认图片资产保留期限和删除方式，按本次独立资源清单清理；不得删除共享组来代替精确删除。生产化还需要持久化清理队列、取消/删除重试、完整删除回执和约定的缓存保留期限。未完成这些措施前，仅用于明确授权的小规模测试。

## 8. 手机显示与双用途边界

导入资产沿用原 session 来源，原视频保持可用。结果质量默认 `needs_review`，双用途默认 `not_evaluated`。SHA-256、源 session、图片资产和 step 关联证明的是处理链记录，不自动证明几何、尺度、相机参数或训练质量可靠。

手机使用现有原生 WebGL Gaussian viewer。后端默认生成最多约 60,000 点的 `.splat` 显示派生文件，当前可选上限为 100,000 点；原始 PLY 独立保留。该派生文件是有损显示用途，**当前不是 SOG，也不是渐进 streaming**，不应称为完整精度原模型。

后续可继续用同一原视频开展视频数据处理，也可增加 SfM/精建或其他重建 provider；本次代码没有实现这些后续算法。下一步实测应分别覆盖：真实成功终态和 PLY 兼容性、原任务回填、iPhone GPU 显示、取消/删除竞态、原片完整保留，以及室内/室外样本的数据质量。合成图片测试不计入真实手机采集或训练有效性验收。
