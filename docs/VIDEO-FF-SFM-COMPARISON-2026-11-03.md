# 用户视频：FF 与 SfM／3DGS 实测（2026-11-03）

输入是用户指定的 `C:\Users\seanzjxiao\Downloads\video.mp4`：11.733333 秒、540×960、30 fps、352 帧、H.264、1,892,196 字节，含音轨。原视频保持不变，SHA-256 为 `32b699cefa0fabdae7e7905ffbeef94a4659a2775eaf3c0aed03b13d2ea46712`。是否为未压缩 iPhone 原片尚未核实。两条路线均仅上传 JPEG，没有上传音轨或伪造 ARKit／LiDAR 数据。

| 项目 | FF／WorldMirror2 | COLMAP SfM → gsplat MCMC |
|---|---|---|
| 输入 | 16 帧，target_size 518 | 同段视频 64 帧，长边 960 |
| 相机来源 | 模型预测 | 独立 SIFT、穷举匹配、增量 SfM、BA；无 FF 位姿先验 |
| GPU | A10 GPU 7 | A10 GPU 1，由动态显卡池分配 |
| 成功任务耗时 | 54.538 秒 | 187.237 秒；包含 SfM、7,000 步训练与导出 |
| 最终状态 | SUCCESS，exit 0 | SUCCESS，exit 0 |
| 高斯点数 | 490,221 | 143,064 |
| 原始 PLY | 33,335,444 字节，SH0 | 35,481,403 字节，SH3 |
| 压缩 SOG | 未生成 | 3,981,159 字节 |
| 项目／步骤 | `2028390bb099` / `1c4b4d680642` | `bef996791c9d` / `621010e38716` |

这是两条当前流程的体验对照，**不是等帧数、等分辨率或等计算预算的模型评测**。成功任务耗时不含人工诊断与启动脚本修复。

## SfM 与训练结果

最终尝试注册 64/64 帧，得到 6,308 个稀疏点、31,360 个观测，平均轨迹长度 4.971465、平均重投影误差 0.731643 px。使用 SIMPLE_PINHOLE，由 COLMAP 估计内参；这些不是设备实测标定，也不具备已验证的公制尺度。

参数：`matcher=exhaustive`、`steps=7000`、`cap_max=300000`、`resize_long_side=960`、`sift_peak_threshold=0.00667`、`use_pose_prior=false`。输入资产 `88528660d3384245abcdfcb1bb41072a`，revision 1，独立组 `802f7e9cb822`。

最终导出检查中，PLY 属性数量、点数、坐标变换往返、COLMAP 边界与反归一化检查均通过，未丢弃高斯点。PLY 已反归一化到本次 COLMAP 坐标，须搭配 `sfm-cameras-final.json`；不能配首次失败尝试或归一化训练坐标中的相机。

8 张留出视角的实际指标：PSNR 29.0516、SSIM 0.929749、LPIPS 0.129616。留出图来自同段视频的相邻视角，不是独立场景泛化测试。`view_index.json` 将第一对图绑定到 `image_000001.jpg`。人工对照实际渲染与对应原图：杯体、把手和标志清晰可辨，背景与部分边缘仍有模糊；不能由图像相似度推导碰撞几何或机器人仿真精度。

## 结果文件

SfM 完整记录位于被 Git 忽略的 `D:\PocketWorld\work\sfm-downloads-video-20261103-f64`：

- `scene.ply`：SHA-256 `cd640a8bc89b0f21ace473e72727d5194dfb856c112f68cec8e79d110fb7625d`。
- `scene.sog`：SHA-256 `accb57284ffa5b1cd3083a89526e275a77cb6df690768288d2317747ae1cb169`。
- `export-check.json`、`state.json`、`last-result.json`：输入绑定、尝试历史与真实终态。
- `sfm-sparse-final.tar.gz`、`sfm-sparse-final/`、`sparse-points-final.ply`：最终 COLMAP 稀疏结果；稀疏 PLY 不是 Gaussian PLY。
- `sfm-cameras-final.json`：最终任务估计的相机、内参和原始图名。
- `holdout/test/ours_7000/{renders,gt}/00000.png` 至 `00007.png`、`view_index.json`：实际完整 SH3 渲染与配对原图。
- `holdout/stats/val_step6999.json`：实际评估指标。

原始输入帧与时间戳分别保存在 `work/t0-downloads-video-20261103-f16` 和 `work/t0-downloads-video-20261103-f64`。FF 原始输出与查看文件位于 `work/ff-downloads-video-20261103-f16`。

## 本轮修复与接入注意点

首次 SfM 尝试 `13b9fed7a1f3` 已完成相机求解，但训练前记录 gsplat 提交号时，Git 因目录归属不同退出 128。仅将部署脚本 `backend/scripts/gs_mcmc/100_run_gs_mcmc.sh` 的这一条 `git rev-parse` 命令改为显式指定该 gsplat 目录的命令级 `safe.directory`，保留原版本记录检查。没有修改全局 Git 配置、算法或服务配置。原脚本备份在 `/mnt/data2/zxnzzhang/rshub-runtime/dsflash-pipelines-20261102/private/100_run_gs_mcmc.before-git-guard-20261103T072925Z.sh`。保留失败历史后，只新建了一次明确重试，最终成功；首轮稀疏相机与最终相机分别保存。

FF 查看时另发现实际安装的 WorldMirror 直接向 PLY 写入概率 opacity，而通用转换器假定 logit，旧 100k 截图因此不能用于比较。临时查看器已按核实的导出格式修正透明度，并使用完整 490,221 点和真实模型预测相机；有效截图为 `preview-predicted-first-full-probability.png`。该图中杯体仍有明显透明／模糊感。FF 使用 SH0，本次 SfM 留出渲染使用 SH3，展示方式也不同。正式 App 必须以来源标识区分这两种 opacity 编码，不能整体改变标准 gs_mcmc 的解析规则。

本次通过的是同一段外部 RGB 视频的服务器重建测试。原生 App 拍摄、真机上传和渲染、尺度与机器人数据验收仍是后续独立步骤。
