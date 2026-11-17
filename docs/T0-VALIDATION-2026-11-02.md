# T0 FF／WorldMirror 预试验实测记录（2026-11-02）

本轮只验证前馈 WorldMirror，不以传统 COLMAP／SfM 结果作为通过条件。本记录把工具自检、远端 GPU 执行和真实 iPhone 场景结果分开。T0 的正式输入应是 iPhone 系统相机未经聊天软件压缩的 MOV/MP4；截至本次记录，`D:\PocketWorld\input` 尚无该原片，因此真实场景质量、手机直传与机器人数据价值均未验收。

| 环节 | 结果 | 证据与边界 |
|---|---|---|
| T0 视频预处理 | 合成视频冒烟通过；8／16 帧抽取、实际视频 PTS、原片／图片 SHA-256、联系表、重试复用及冲突拒绝已检查 | `server/tools/t0-video.mjs`；合成结果仅在忽略目录 `work/t0-fixture/`，不代表 iPhone 采集质量 |
| Hub 接口 | 可访问，`worldmirror2`、默认 16 帧／518 像素、最多 32 帧 | `node server/tools/worldmirror.mjs doctor`；`available:true` 单独不证明 GPU 可执行 |
| 新合成 GPU 健康任务 | **SUCCESS**；8 张合成图，`exit_code=0`，报告推理约 50.457 秒 | project `8b0f27a5a8d2`、step `d7aae1abb2b7`；远端报告 `gpu_id=6`、`input_count=8`，仅证明当前 GPU worker 可执行本测试 |
| Gaussian 产物 | 已下载并核对：33,363,528 字节、490,634 个高斯点，SHA-256 `bebaf7667dd2ebf3728de76bb5c0621b4d8203ebec1b729baccebeb0726ce83c` | `work/t0-gpu-health-20261102/scene.ply`；结构检查通过，质量仍 `needs_review`，坐标为 `algorithm`、尺度为 `unknown`，双用途 `not_evaluated` |
| 查看衍生文件 | 实际 PLY 经现有转换器生成 60,000 点／1,920,000 字节的 `.splat`，SHA-256 `fdb99dd7ef8f24b335aa616e505ea3450e124aabda4ea722c5d8ad4a7575c89d` | `work/t0-gpu-health-20261102/viewer-60000.splat`；只是有损渲染资源，尚未在 iPhone 上显示，也不证明几何质量 |
| iPhone 实拍 FF | **待原片** | 当前 v2 接口要求同次 ARKit 位姿和内参，系统相机视频不能伪造为原生采集包；T0 先本地转移原片、人工审帧并直接调用 Hub CLI。手机直传是后续 App 验收，不是本轮条件 |

历史任务曾等待 GPU 约一小时后失败；本次独立合成任务成功说明**当前** worker 状态已变化，但不推出真实 iPhone 视频的重建成功率或时延。真实视频到位后，对每个场景保留原片哈希、联系表人工复核、FF 输入资产／任务 ID／终态／产物、视觉对照和失败原因。WorldMirror 输出不自动进入机器人或视频模型训练分支，许可与数据授权边界仍按[原生验证计划](NATIVE-IOS-VALIDATION-PLAN.md)执行。

此前已准备的 [COLMAP CPU 脚本](T0-COLMAP.md)归档用于后续独立的传统重建路线；其合成素材冒烟结果 `no_sparse_model` 不参与本轮 FF 结论，当前不再运行该路径。

合成任务报告中的 50.457 秒是本次模型推理分项，已经高于计划中探索性的 5 秒目标；首版手机预览应按异步结果设计。HTTP 报告提供 GPU 编号／UUID，但没有显卡型号；日志目录中的 `a10` 不能单独证明硬件型号，因此不将这次时延写作经过硬件核验的 A10 基准。
