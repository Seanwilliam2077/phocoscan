# phocoscan 使用问题复查（2026-11-10）

范围：现有代码、iPhone 安装与合成 GPU 测试、部署服务器的只读任务记录。没有新建云端 GPU 任务，没有重试用户扫描，没有修改 RealityScan Hub。

## 本轮确认和修复

- 上传完成即同时生成两个云端版本，无法控制算力使用。现在上传只核验，快速版、高质量版、位姿版分别点击生成。服务端 `roles` 接口已完成；旧接口缺少能力标志时禁用单版本提交。
- 请求返回但所选任务缺失时，客户端原先会清除待处理选择。现在保留选择并提示核对，后续只恢复已选择的版本；已有可用结果保留。
- 删除扫描只发出取消信号，没有等本机训练停止。现在删除等待 worker 退出，保存前检查取消，重新训练的结果通过替换目录发布；取消保留旧结果。
- 上游错误统一显示失败。新代码将已确认的显存不足和任务取消映射为固定错误码及中文说明，保留手动重试。历史失败记录不会因部署自动改写。
- 本机训练确认框撤掉未经真实扫描测量的“约几分钟”，保留按实际迭代速度计算的运行中预计时间。

## 当前云端失败的证据

服务器 `VM-79-113-centos`，PocketWorld API 与 worker 均 active，检查时无 queued/processing 任务。

扫描 `4aada4d6…`：

| 版本 | 时间（北京时间） | 私有上游报告中的原因 | 结论 |
|---|---|---|---|
| 快速版 | 11 月 10 日 16:20 | phase=cancelled，error=cancelled locally，exit_code=-9 | 上游取消，无法从该记录确定操作者或触发机制 |
| 高质量版 | 11 月 10 日 16:29 | 最空闲 GPU 剩余 6,071 MiB，要求至少 20,000 MiB，未启动 3DGS | GPU 空闲显存不足；重新上传原片不能解决 |

数据盘剩余约 82 GB，系统盘约 2.2 GB。共享盘存在被其他任务填满的风险；没有证据把本次两项失败归因于磁盘。

较早扫描 `a8b4c4ab…` 的三个版本现在均 ready；`14db5c4e…` 的三个分支仍保留之前的 artifact_read_failed。

## 下一轮优先级

1. **云端资源与失败恢复。** 在独立 PocketWorld 服务内区分等待资源、执行、结果交付；显存不足应解释下一步，避免用户反复上传。排队或重试策略需要保留明确的任务归属与取消机制。禁止擅自修改 Hub 或 GPU 分配。
2. **本机训练恢复。** 现在切后台会取消，尚无训练检查点。对长扫描而言，中断后重算成本高；应增加可恢复检查点，并用真实扫描验证内存峰值、发热、耗时和结果质量。合成 GPU 收敛不等于真实扫描验收。
3. **覆盖提示的含义。** 红绿表示观测次数与视角分布；完全没看到的表面没有点可染红。界面应明确“覆盖参考”，提示具体缺少的方向，避免“绿色就是重建完整”的误解。
4. **人像与空间的验收。** 人像静止检测、遮罩与姿态漂移仍需实拍对照；快速版和高质量版仍从视频取帧，人物遮罩只用于支持关键帧的位姿版。空间还需检验长路径漂移和回到起点的效果。
5. **训练资格与结果状态。** 更新前的扫描没有关键帧包、本机无 LiDAR 等情况目前可能隐藏本机入口。应解释为什么不可生成。云端已生成、下载完成、渲染成功应分别呈现；下载失败应重试下载而非重训。
6. **实际网络入口。** 当前地址依赖内网/iOA。Safari 可访问不等于 App 当前请求已授权；应给出针对未连接、网关拒绝、服务不可达的短提示。供普通外部用户使用前仍需规划可达的 HTTPS 入口。

## 验证与交付状态

- Server：148/148 测试通过。
- Simulator：全量 120 项，116 通过、4 条件跳过；随后加入两项选择恢复测试，定向 NativeReconstructionTests 16/16 通过。
- iPhone 16 Pro Max：此前本机训练测试 3/3 通过，合成 GPU 收敛测试用时 0.836 秒。本轮签名构建成功并已覆盖安装；设备锁定，未宣称实际打开或实拍验收。
- 云端发布包：`20261110-a10-b0c0bffc538f`，47 个白名单源码文件；本地与服务器 SHA-256 均为 `b0c0bffc538f8e666ce869884fee357d397f91bb549170d66b5f0ae9ba6ea163`。
- 包已放入 `/data/home/seanzjxiao/pw-release/`，尚未安装或重启。当前仍运行 `20261109-a10-66ee6915b153`，因此单版本生成仍等待服务端更新。
- 批准部署后：运行既有 install-release.sh（会再次以 pocketworld 用户跑测试）；确认无活动任务，再重启 pocketworld-api 与 pocketworld-dual-worker；检查 health 中 reconstruction-selection。回退到原发布目录并重启同两个服务即可。不会自动重跑历史失败任务。


## 后续更新（同日）

用户批准后，版本选择发布 b0c0bffc538f 已部署；后续 GPU 准入发布 cbd60a900081 现在线上，服务器 152 项测试通过。只重启了 PocketWorld 服务，并新增只读 GPU 遥测 timer。手机端已安装空间优先入口、自由视点控制和繁忙后不自动重试的版本，模拟器 120 通过 / 4 条件跳过。

共享 Hub 的快速版动态选卡补丁已准备并通过 5 项模拟测试；受仍在运行的 align 任务阻挡，尚未应用，不能宣称快速版已解除 GPU 绑定。安全安装器检查发布路径和源码哈希，并在持有数据库写锁的情况下确认无活动任务后才允许重载 worker，避免与新提交竞争。旧临时 GPU 限制仅在成功重载后移除；其他共享任务不会被主动取消。


## Follow-up: poor on-device quality and single-image delivery

Confirmed from code and actual server status (Nov 10):

- Dedicated single-image executor completed two attempts (about 68 s / 51 s creation-to-update); the application's one image remained failed at exporting/99%, `invalid_result`. Read-only inspection found 46,919 +Infinity and 5 -Infinity opacity logits in 262,144 points, with no nonfinite geometry/color. A temporary finite derivative passed the live strict PLY validator; the existing 3,462,410-byte SPZ passed with the same point count. Original files/DB were untouched during diagnosis, and the temporary derivative was deleted. The prepared repair preserves provider bytes and adds delivery-only retry; no GPU work needs repeating.
- Local Metal MCMC perturbation used `R diag(sigma) z`, although the reference strategy uses `R diag(sigma²) Rᵀ z`. For isotropic 1 cm Gaussians the old displacement is 100x the reference magnitude. The isolated GPU regression failed before the correction (doubling sigma gave 2x displacement), then passed (4x). This is a confirmed implementation defect, not proof that it explains every poor real scan. The synthetic renderer/gradient/convergence suite still passes after correction. Reference: [gsplat noise implementation](https://github.com/nerfstudio-project/gsplat/blob/main/gsplat/strategy/ops.py).
- Other verified local limitations remain: longest image side 512, fixed 3,000 iterations, at most 160 frames, SH0/L1 only, fixed Gaussian count with relocation but no adaptive growth, direct ARKit poses without joint refinement. LiDAR seeds initialize geometry; per-frame depth/confidence/person masks are not used as training losses. One last-view error is not a multi-view acceptance criterion.

Next quality work, in order:
1. On a fixed real scan, inspect initial LiDAR reprojection over several JPEGs (orientation, intrinsics and temporal alignment), then compare held-out views before/after the noise fix. Keep training inputs/parameters identical for the comparison; don't treat synthetic convergence as real quality.
2. Use confidence-filtered measured depth and masks with robust losses/occlusion handling; diagnose pose drift and add bounded camera refinement when supported by evidence. A bad alignment is not solved by more iterations.
3. Add adaptive growth/pruning and correct relocation-scale compensation under a mobile memory budget; tune with multi-view validation. [gsplat strategies](https://docs.gsplat.studio/main/apis/strategy.html).
4. Progressive resolution, L1 + SSIM, and SH1 with a measured thermal/memory budget. Original 3DGS uses an SSIM term, and its documented depth regularization has scene-dependent results: [reference training loop](https://github.com/graphdeco-inria/gaussian-splatting/blob/main/train.py). None of these unimplemented improvements is claimed as shipped.

Capture guidance update: both object/person use a fixed nearby camera waypoint advanced only by a successfully saved sharp frame; no orbit ring or circle-completion percentage is displayed. Directions are gravity-aligned for portrait-held phones. Tracking loss/world jumps suppress stale recommendations. Space uses saved-view stages (translation, upper/lower views, oblique view, neighboring region, return to start) and warns when no new clear frame was saved. Bottom-center preview follows real camera heading, with space distance and stop on the right. This borrows AgeScan's bottom-control organization; its actual free mode displays cumulative movement, not the object coverage sphere. These remain capture suggestions, not an obstacle map or certified completeness.


Follow-up outcome: user approved deployment; API release `20261110-a10-cdd41ad00193` is live. Delivery-only recovery restored the same image/attempt to ready; dedicated executor count stayed at two. 163 server tests pass, full simulator run 136 pass/5 conditional skips, and 5 real-iPhone training tests pass. Final UI build installed; phone locked at launch. Real camera guidance and this result's visual rendering still need on-phone acceptance.
