# T0 独立 SfM 基线：COLMAP CPU

这条链只用 [T0 视频预处理](T0-VIDEO-PILOT.md)抽出的同一批 JPEG 独立估计稀疏相机与点。它用于对照 WorldMirror，不使用 WorldMirror 产物作为先验。结果不带已验证的公制尺度、稠密深度或机器人碰撞网格。

## 本机工具

- 已从 [COLMAP 官方 4.2.1 Release](https://github.com/colmap/colmap/releases/tag/4.2.1)下载 Windows `colmap-x64-windows-nocuda.zip`，存放于忽略目录 `D:\PocketWorld\work\tools\` 并解压。下载包 SHA-256：`C493D88CB4A43F21AFBA42CB55BF786E5434A0420E73DB0BA1454C5D8B3686AE`。命令行返回 COLMAP 4.2.1、commit `bd1fcf6`。官方[安装说明](https://colmap.github.io/install.html)确认 Windows 包包含 CLI，且需要经 `COLMAP.bat` 启动。
- 运行脚本需 PowerShell 7。当前脚本默认定位上述本机路径；其他 Windows 机器可通过 `-ColmapBat` 传自己的 `COLMAP.bat`。COLMAP 可用 CPU 做特征提取、匹配和稀疏 SfM，[官方 CLI 文档](https://colmap.github.io/cli.html)给出 `FeatureExtraction.use_gpu=0` 与 `FeatureMatching.use_gpu=0`。无 CUDA 包不执行稠密 PatchMatch。

## 执行

先用 `server/tools/t0-video.mjs` 生成 `frames/` 与同级 `manifest.json`，看联系表确认帧有重叠和侧向视差。录制时尽量固定 iPhone 1×镜头、不变焦；本脚本把同一段视频视为单个相机，采用 `SIMPLE_RADIAL` 模型。摄像头中途切换时应另做校准或拆成不同片段。

```powershell
cd D:\PocketWorld
pwsh -File .\scripts\Run-T0-Colmap.ps1 -FramesDirectory 'D:\PocketWorld\work\t0\<hash>-f16\frames'
```

脚本先对照 T0 清单复核每张图的 SHA-256，然后顺序执行 CPU SIFT、穷举匹配、稀疏 mapper 和模型分析。输出默认在帧目录同级 `sfm-colmap-cpu/`：`database.db`、`sparse/`、各阶段 `logs/`、`summary.json`。摘要包含来源视频哈希、输入帧哈希、COLMAP 版本、注册图片数、点数和平均重投影误差（若有模型）。已有输出目录会被拒绝，避免覆盖或把新输入混入旧结果。

若返回 `no_sparse_model`，这是有效的失败观测：特征与匹配可能完成，但没有足够可靠的初始图像对；不要把它写成“重建成功”。需查联系表、匹配日志和原视频的侧向视差、模糊、动态物体。COLMAP 的相对重建尺度仍须用已知尺寸标记或实测距离校准；稀疏点云不能直接当作碰撞几何。

## 2026-11-02 冒烟结果

对代码生成的 16 帧合成视频，固定 CPU 单线程与随机种子后，脚本两次完成特征、匹配和 mapper，均返回 `no_sparse_model`；证据在忽略目录 `work/t0-fixture/prepared2/sfm-colmap-cpu5/`、`sfm-colmap-cpu6/`。这只证明工具可运行、能诚实记录无模型结果。尚未收到 iPhone 原片，不能评价真实场景的注册率或尺度。
