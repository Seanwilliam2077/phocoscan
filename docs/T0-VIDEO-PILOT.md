# T0：iPhone 视频的 FF／WorldMirror 验证

本轮只回答「普通 iPhone 视频能否让前馈模型 WorldMirror 产出可查看的 3DGS，以及耗时和失败原因」。传统 COLMAP／SfM 是另一条算法路线，不参与 T0 的通过条件。此试验不代表原生 App、ARKit 位姿、LiDAR、手机直传、机器人尺度或训练数据已通过。真实结果必须来自用户提供的**未压缩转发的原始 MOV/MP4**；代码生成的视频只能做工具冒烟测试。

## 准备视频

用 iPhone 系统相机分别拍一个有纹理的静态物体／桌面、一处室内角落、一处允许拍摄的室外固定场景，每段约 15–30 秒。保持目标可见，缓慢侧移并补斜角；避免只原地转圈、动态人车、反光与极暗区域。通过数据线、AirDrop 或原文件方式送到电脑；不要用聊天软件的压缩视频。记录设备、地点类型、原文件大小和 SHA-256，保留原件。

Windows/Linux 主机或虚拟机需 Node.js 24、FFmpeg 和 FFprobe。若可执行文件不在 `PATH`，传入 `--ffmpeg`、`--ffprobe` 的绝对路径。本项目的 `work/` 已被忽略，工具只在其下新建结果，不会改写原视频或上传网络。

```powershell
cd D:\PocketWorld
node server/tools/t0-video.mjs --video 'D:\PocketWorld\input\iphone-original.MOV' --frames 16 --ffmpeg 'C:\path\to\ffmpeg.exe' --ffprobe 'C:\path\to\ffprobe.exe'
```

输出 JSON 中的 `out` 目录包含 `frames/image_0001.jpg` 等 16 张图片、`contact-sheet.jpg` 和 `manifest.json`。清单记录原片哈希、实际探测到的视频流与音频存在性、每张图的原视频帧序号和时间戳、图片哈希。来源固定标为 `external_rgb_video`，ARKit 位姿／同步内参／LiDAR 深度／公制尺度均标为不可用。图片按时间均匀抽取，**并未自动评判清晰度、视差或覆盖**；先看 contact sheet，近似重复或模糊时应重拍或另做有记录的人工选帧。重复执行同一输入与参数会校验并复用已有结果，不覆盖不同内容。

## 提交 WorldMirror

只有人工检查抽帧后，再明确选择这些图片调用现有 [WorldMirror operator CLI](WORLDMIRROR-INTEGRATION.md)。将下例中的 `--files` 换成实际输出的 `framesDirectory`，每次使用新的 `work/` 运行目录。Hub 地址与访问凭据由操作者在私有环境中配置，不放在命令行、清单或源码里。

```powershell
node server/tools/worldmirror.mjs doctor
node server/tools/worldmirror.mjs upload --files 'D:\PocketWorld\work\t0\<hash>-f16\frames' --run-dir 'work\t0-worldmirror-run1' --name 't0-external-rgb-run1'
node server/tools/worldmirror.mjs quick --run-dir 'work\t0-worldmirror-run1'
node server/tools/worldmirror.mjs resume --run-dir 'work\t0-worldmirror-run1' --max-wait 30 --poll 2
node server/tools/worldmirror.mjs inspect --run-dir 'work\t0-worldmirror-run1'
```

提交后分别记录：原片与选帧哈希、上传耗时、GPU 排队、推理与压缩耗时、任务终态、PLY／SOG 结构与首帧查看结果，以及相对原视频的明显空洞、漂浮、重影和错误几何。`available:true` 或成功排队不等于模型产出。2026-11-02 的独立合成 GPU 健康任务已真实成功；真实 iPhone 场景仍须各自验收。

T0 最低验收是一条真实 iPhone 原片经 8／16 帧输入得到可下载、可解析且能打开的同源 3DGS；再用物体、室内一角、室外固定场景各一条记录成功率与失败类型。一次成功不代表这三类场景都适用。首个样本的人工查看要把模型与原视频并排比对，记录是否能辨认目标和主要结构；不把 PLY 结构通过等同于视觉质量通过。进度见 [T0 实测记录](T0-VALIDATION-2026-11-02.md)。

已备的 [COLMAP CPU 脚本](T0-COLMAP.md)保留给后续独立的传统重建研究，本轮不运行、不纳入 FF 指标。

## 与正式 App 的边界

系统相机视频不含同次 ARKit `cameraToWorld`、逐帧内参或 LiDAR `sceneDepth`。当前 `/v2/captures` 要求这些逐帧元数据，不能用假矩阵凑接口；v1 `in_app_rgb` 也不能用于外部系统相机视频，否则来源会被误标。若要让手机直接向本项目上传系统相机视频，需要新增 `external_rgb_video` 导入资源与稳定 HTTPS 入口。真机扫描引导、原生上传与带公制尺度的机器人几何仍需后续分别验收。
