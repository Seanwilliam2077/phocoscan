# iPhone App 与 FF 接线验证记录（2026-11-03）

本记录区分代码检查、合成端到端试验和真实 iPhone 验收。当前没有后两者的完整通过结论。SfM 不参与首版。

## 用户视频 FF 测试与后续 SfM 对照

用户随后指定 `C:\Users\seanzjxiao\Downloads\video.mp4`：1,892,196 字节，H.264、540×960、30 fps、352 帧、11.733333 秒，含音轨；原文件 SHA-256 为 `32b699cefa0fabdae7e7905ffbeef94a4659a2775eaf3c0aed03b13d2ea46712`。尚未核实它是否为未压缩 iPhone 原片。原件保持不变，仅将抽出的 JPEG 送给重建服务。

在 WSL 中按实际视频时间抽取 16 帧，人工查看联系表确认静态水杯和桌面、视角连续。Hub project `2028390bb099`／step `1c4b4d680642` 返回 `SUCCESS`、退出码 0、GPU 7；任务耗时 54.538 秒，报告推理 54.067 秒。已下载并校验 33,335,444 字节、490,221 个高斯点的 PLY，SHA-256 为 `6cdca95ce047fa218566381e53dd5b6e9b0321ee6fe354109be64e9aa06974d7`。原视频和抽帧来源清单位于忽略目录 `work/t0-downloads-video-20261103-f16`，重建清单和 PLY 位于 `work/ff-downloads-video-20261103-f16`。

临时本地查看器使用该任务输出的 16 个模型预测相机定位观察视角；这些相机不是 ARKit 实测值。检查实际安装的 WorldMirror 导出代码后发现，该版本把已 sigmoid 的 opacity 概率直接写入 PLY，而通用展示转换器按常规 logit 再次 sigmoid，导致透明点错误地变得不透明。因此旧 `preview-predicted-first-100k.png` 有格式解码问题，**不能用于评价 FF 画质**。

已单独为这个经过核验的输出生成 `viewer-full-wm-probability-v1.splat`，直接读取概率透明度，完整保留 490,221 点，15,687,072 字节，SHA-256 `69a0b94009ea6d711004d8222f672e87cde998fc29329c14d4b9ad4af392d63f`；尺度 log→exp、SH0 与 wxyz 四元数也核对了源实现。原 PLY 未改变，产品通用转换器未修改。实际浏览器渲染并导出的有效截图为 `preview-predicted-first-full-probability.png`：杯体、圆桌及背景结构可辨认，杯体仍有明显透明／模糊感。它是完整点数的本地诊断渲染，仍有 SH0 与 8 位展示量化，不代表公制几何或真机质量通过。Hub 自身 `preview_ready=false`、SOG 未生成。正式 App 接入仍需将这一已确认的 WorldMirror 格式差异纳入带来源标识的转换，而不能改变标准 gs_mcmc 的 opacity 解码。

用户又明确要求同段视频使用服务器已有 SfM 算法。64 帧独立输入已完成 COLMAP → gsplat MCMC，最终任务 `621010e38716` 为 SUCCESS：64/64 注册、6,308 个稀疏点、平均重投影误差 0.731643 px，7,000 步训练，成功任务耗时 187.237 秒，生成 143,064 点 PLY 和 SOG；不使用 FF 输出作为相机先验。实际留出渲染中的杯体、把手与标志更清楚。完整证据、启动修复与比较边界见 [同视频实测](VIDEO-FF-SFM-COMPARISON-2026-11-03.md)。此实验不改变首版原生 App 的 FF 主线范围；两个实验的帧数、分辨率和训练预算不同。

## 14:28 最新状态：GPU 7 合成 FF 验证成功

用户明确确认切换到 `nvidia-smi` 编号 **7** 的 A10。检查 `step` 与 `presentation_job` 均无活动任务后，于 14:26:52 备份并原子修改 worker 配置，仅将 `RS_HUB_WM_GPU_UUID` 改为 `GPU-c4b7b304-4aaf-a0f8-716e-f8afcf01b7fe`；显存门槛 20,000 MiB 和排队时限 3600 秒保持不变。重启的是独立的 **`rshub-worker.service`**，新 PID `134610`；API 服务没有重启。进程环境、物理 GPU 7 上的 WorldMirror Python 进程和真实任务报告均确认新绑定生效。

有效 worker 配置为 `/mnt/data2/zxnzzhang/lookdev-runtime/pipeline-release-20261030-ea64caa/private/rshub-worker.env`，备份为同目录的 `rshub-worker.env.gpu6-backup-20261103T062652Z`。API 的 `native.env` 不是负责推理执行的 worker 配置；今后修改执行绑定应核对 worker 的实际 EnvironmentFiles 与进程环境。

| 验证项 | 实际结果 |
|---|---|
| 输入 | 8 张既有合成图片，`target_size=518` |
| Hub project / step | `42cee8632a77` / `bb77fb6ecb57`；`result_step` 与本次 step 相同 |
| 终态 | `SUCCESS`，exit code `0`，报告 `gpu_id=7`，GPU UUID 与新绑定相同 |
| 耗时 | 报告总耗时 `65.036` 秒，其中推理 `64.668` 秒 |
| PLY | 已下载并解析，33,363,528 字节、490,634 个高斯点 |
| 文件 | `D:\PocketWorld\work\ff-gpu7-20261103\scene.ply`（被 Git 忽略） |
| SHA-256 | `bebaf7667dd2ebf3728de76bb5c0621b4d8203ebec1b729baccebeb0726ce83c` |
| Hub 预览 / SOG | `preview_ready=false`、`sog_size=0`，未将 PLY 成功等同于这些产物已就绪 |

本次证明远端 WorldMirror 在 GPU 7 上能够完成合成输入的真实推理并交付有效 PLY，恢复了 FF 运算能力；它不是 iPhone 原片、v2 上传到结果导回、手机渲染或重建质量的完整验收。

## 14:20 历史诊断：GPU 6 显存不足

2026-11-03 北京时间，通过本机已有 SSH 密钥和账号已有的 sudo 管理权限，只读检查实际 Hub 服务、GPU 与部署代码：

- `rshub-api.service` 为 active，8000 端口由 PID 925343 监听。服务器有 8 张 NVIDIA A10，每张约 23,028 MiB 显存，检查时多张卡几乎空闲。
- FF 实际配置 `RS_HUB_WM_GPU_UUID=GPU-929298dc-b516-ab84-4a1c-97a17b08cdaa` 对应物理 GPU 6；`RS_HUB_WM_MIN_FREE_MIB=20000`、`RS_HUB_WM_QUEUE_TIMEOUT=3600`。
- GPU 6 当时使用 10,389 MiB，驱动报告空闲 12,210 MiB，达不到门槛；主要显存由另一用户的计算进程占用。没有停止或修改该进程。
- 部署代码位于 `/mnt/data2/zxnzzhang/rshub-releases/cd8ab24-20261102-dsflash-pipelines/backend/app/`。`worldmirror_runner.py` 只对指定 UUID 调用 `gpu_pool.acquire_exact`，不自动换卡；显存不足时持续等待。`available:true` 只检查配置与路径，不检查 GPU 当前可用性。
- API 进程当时的 GPU 配置来自 `/mnt/data2/zxnzzhang/lookdev-runtime/model-agent-access-20261102-e79431e/private/native.env`，第 58、59、61 行分别为 UUID、显存门槛与队列超时。后续确认 API 与推理 worker 为独立服务；实际执行绑定必须检查 `rshub-worker.service`，不能只修改或重启 API。未输出其他私有环境变量。

原 step `ad98419c369f` 已于 12:03:36 因等待 GPU 一小时超时，状态 `FAILED`、exit code 1，无产物，日志为空。另提交了一次 8 张既有合成图片的当前探测：project `1de984f2e65e`、step `8fe33d270e30`，同样 `waiting_gpu`。定位原因后，已通过任务接口主动取消这一条探测；终态为 `FAILED`、exit code `-9`、`report.phase=cancelled`、`cancelled=true`。这不是推理失败。运行清单位于忽略目录 `work/ff-health-20261103-1418`。

当时结论：固定 GPU 6 的空闲显存不满足门槛，其他空闲卡不会被使用。14:20 诊断阶段仅只读检查并取消本次探测；随后按用户指示完成 GPU 7 切换及真实成功验证，见上方最新状态。没有终止其他用户进程或降低显存门槛。

## 已完成的代码路径

- 原生 App 保留同一 ARKit 帧的 RGB 视频、时间、位姿、内参与设备提供时的深度；采集后直接打开本次详情。拍摄界面显示真实录制时间、帧数和 ARKit 跟踪警示。
- v2 原片及元数据核验成功后，App 用同一 capture ID 自动建立一次 FF 任务，轮询真实状态；失败可重试提交。轻量 `.splat` 在资产 ID、精确鉴权路径、格式、点数、字节数和 SHA-256 都一致后才交给 Metal 查看器。
- 业务服务把已核验 v2 采集关联到原有 WorldMirror 出站 worker；任务排队、处理、结果导入和源删除保持独立来源。结果只有经过 Hub 真实成功、PLY 校验和服务端导入才可显示 ready。
- 修复旧 worker 使用带空格的 Hub 项目名：实际 Hub 明确以 HTTP 400 返回“项目名不能包含空格/制表符等空白字符”；现用不含空格的名称，并加入回归断言。

Windows 上 `npm.cmd --prefix server test` 为 **74/74 通过**；`node --test server/test/worldmirror-bridge.test.mjs` 为 **17/17 通过**；`node scripts/check-project.mjs` 通过。这些测试不等于 Xcode 编译或真机拍摄。

## 真实 Hub 的合成视频试验

来源为 `work/t0-fixture/synthetic.mp4`（8 秒、640×360、240 帧的测试视频），元数据是明确标记的合成矩阵，**不是 iPhone／ARKit 测量值**。临时业务服务接收并核验视频与元数据；同一个 FF job 由实际出站 worker 抽取并上传 8 张 JPEG。Hub 接受任务并产生以下固定标识：

| 项目 | 标识／结果 |
|---|---|
| v2 capture ID | `31f2e320-ffe4-4d1b-98cc-0177e49c6480` |
| FF job ID | `4e96c652-4d61-4381-bf17-4dc236ec0a83` |
| Hub images asset | `c96c39c821a1415ab7fe82fd46e9acc1` |
| Hub project / step | `2f1f9faab8b0` / `ad98419c369f` |
| 本机试验目录 | `D:\PocketWorld\work\v2-ff-live-2026-11-03T03-03-34-272Z`（被 Git 忽略） |

初次试验时 Hub step 为 `RUNNING / waiting_gpu`；14:15 复查已因等待 GPU 一小时而 `FAILED`，无 PLY，见上方诊断。短时试验程序等候 40 次后停止，临时业务服务随之关闭，因此本次不能继续自动导回结果；Hub project/step 留作核查，**不可写成完整 FF 闭环通过**。2026-11-02 的另一组独立合成图片曾获得真实 `SUCCESS`、33.36 MB Gaussian PLY 和 1.92 MB 展示 `.splat`，说明当时 Hub 输出与转换器可工作，但不是本次 v2 视频任务，也不代表手机画质。

## Windows 虚拟机与手机待验收

重启后已安装 WSL2 Ubuntu、Node 24 和 FFmpeg，VM 服务端测试 **74/74 通过**，合成视频解码与 8 帧抽取通过。持久业务服务、隐藏保活进程及 45 秒空闲健康检查通过。步骤见 [Windows VM FF 测试](WINDOWS-VM-FF-TEST.md)。WSL 可运行服务端、FFmpeg 和出站 worker，不能编译 iOS App，也不会自动解决 iPhone 与电脑之间的企业 Wi-Fi 隔离。

仍需：Mac 安装 Xcode 并编译签名；iPhone 17 Pro Max 真机采集与 Metal 预览；手机可达的稳定 HTTPS 业务后端；用户原始 MOV（目前 `D:\PocketWorld\input` 为空）；真实 iPhone 场景的 FF 产物、同源导回与质量验收。远端合成健康任务已成功，不替代这些验收。首轮真实场景至少记录一个静物／室内角落和一个室外固定场景，并分开记录上传、排队、推理、下载与手机首帧时间。
