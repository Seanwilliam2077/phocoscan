# FF／SfM 双结果：Windows 分发验证记录

日期：2026-11-03。用户确认暂时无法使用 Mac，先完成 Windows 验证。本轮使用已经成功重建的 Downloads 水杯视频结果，没有重复提交 A10 任务；没有把 Windows 测试写成 iPhone 渲染成功。

## 实际完成

- 新增私有「重建对照」结果通道：同一外部 RGB 视频、FF 和 SfM 两份独立不可变资产、各自的真实相机轨迹。
- FF 分发完整 490,221 点 SH0 splat，15,687,072 字节，使用已核实的 WorldMirror probability opacity 适配；没有减点。
- SfM 分发原始 143,064 点 SH3 PLY，35,481,403 字节，字节和 SHA-256 与服务器原结果完全一致；45 个高阶 SH 字段保留。
- 两份相机分别转换为显式 OpenGL C2W、行优先矩阵，16／64 个相机与各自原始模型坐标匹配。尺度仍为 unknown，未声称两个版本已配准。
- 原生 App 新增次级「重建对照」入口、快速／精细选择、有上限的下载与哈希校验、隔离账号的本地缓存、真实相机初始视角和轨迹播放代码。
- 已新增 Viewer 失败回调、渲染重试与回退机制；是否能在实际设备按预期运行仍需 Xcode 和 iPhone 验收。

这条结果通道明确标记 `external_rgb_video`，不创建原生 ARKit 采集、不伪造深度，也不增加成长回执。它用于先验证已有结果怎样回到 App；手机新采集后自动执行 SfM 的 job 接线仍是后续工作。

## 数据与相机证据

原视频 SHA-256：`32b699cefa0fabdae7e7905ffbeef94a4659a2775eaf3c0aed03b13d2ea46712`。

| 项目 | FF 快速版 | SfM 精细版 |
|---|---|---|
| 模型 SHA-256 | `69a0b94009ea6d711004d8222f672e87cde998fc29329c14d4b9ad4af392d63f` | `cd640a8bc89b0f21ace473e72727d5194dfb856c112f68cec8e79d110fb7625d` |
| 相机数 | 16，WorldMirror 预测 | 64，最终成功 SfM 任务估计 |
| 手机格式 | splat32、SH0 | binary little endian Gaussian PLY、SH3 |
| 有损处理 | 颜色、透明度和四元数 8 位展示量化，无额外减点 | 此次分发无转换、无减点 |

相机不是根据画面猜出的。准备工具核对原视频、两份选帧清单、实际任务结果、原始 PLY 和相机导出哈希，然后进行坐标转换。

独立检查将最终 COLMAP 的 6,308 个稀疏点、31,360 个真实图像观测，通过**准备交给手机的 GL C2W 相机及内参**重新投影：

- 覆盖 64 张图片，落在相机背后的观测为 0。
- 按每次观测汇总的平均像素误差：**0.750480 px**，最大 3.988103 px。
- 原 COLMAP 存储的逐点平均误差再取均值：**0.731643 px**，与此前报告一致。两者汇总权重不同，不是相机转换产生了额外 0.019 px 误差。
- 另对 Metal 投影公式作了 320 个数值检查；它与针孔投影参考一致。此项不等于实际执行 Swift／Metal。

记录位于忽略目录：`work/mobile-dual-result-20261103/assets/preparation-report.json`。保留此前 [算法实测及输入预算差异](VIDEO-FF-SFM-COMPARISON-2026-11-03.md)，不把两种不同配置当作等预算模型评测。

## 真实 HTTP 验收

`server/tools/check-reconstruction-delivery.mjs` 启动隔离的 Windows loopback 业务服务，注册两个测试账号，导入并下载实际约 51 MB 模型数据。**11 项检查全部通过**：

1. 实际模型与相机导入。
2. 同一清单重复导入幂等。
3. 未登录读取被拒绝。
4. 其他账号读取被拒绝。
5. 私有列表只有一份对应的不可变结果记录。
6. 两份完整模型及相机下载后大小、SHA-256 与源一致。
7. SfM 全部 SH3 字段保留。
8. 文件 Range 下载正确，文件接口同样隔离账号。
9. 外部视频对照不创建原生采集或成长回执。
10. 服务重启后结果与账号权限仍在。
11. 只删除本测试创建的临时副本；删除后无法下载，过期导入无法将其复活。

本次 FF／SfM loopback 下载与校验分别约 93／188 ms，仅是本机性能，不能推算 Wi-Fi、移动网络或 iPhone 首帧耗时。测试结束自动关闭临时 HTTP 服务，原有 WSL 服务和远端 A10 配置没有因本测试被修改。

原始报告：`work/mobile-dual-result-20261103/acceptance/delivery-report.json`。私有测试账号与管理员配置位于同目录忽略文件；不复制到源码交接包或聊天。

## 代码检查

- `npm.cmd --prefix server test`：**82/82**，0 失败。覆盖资产验证、权限、幂等、并发删除、来源格式和 FF 既有流程。测试工具输出记录在本次会话，未另存 TAP 文件。
- Xcode 工程生成与结构检查通过：20 个 App Swift 源文件、1 个测试源文件。
- Swift grammar 检查通过 21 个文件；未检查 Apple SDK 类型、actor 隔离、链接、签名或 Metal 真机执行。
- 已固定的 MetalSplatter 可保存和计算 SH3，底层模型保持原坐标；新视角通过相机矩阵变化，未仅旋转 xyz 破坏高阶颜色方向。

## 复跑与导入

在 `D:\PocketWorld` 执行准备和验证（配置、媒体均在本机忽略目录）：

```powershell
node server/tools/prepare-reconstruction-study.mjs --config work/mobile-dual-result-20261103/prepare-config.json
node server/tools/check-reconstruction-delivery.mjs --manifest work/mobile-dual-result-20261103/assets/study-manifest.json --work-dir work/mobile-dual-result-20261103/acceptance
```

要把同一结果分配给未来实际 iPhone 账号，先连接目标业务服务，从 App「重建对照」取得账号编号，再使用本地操作员导入工具：

```powershell
node server/tools/import-reconstruction-study.mjs --config <private-config.json>
```

该配置为 `{dataDir,userId,manifestPath}`，指向目标业务服务器的本地数据目录、已存在的目标账号及准备好的清单。清单里的私有源路径只供操作员读取；下载接口不会暴露路径。相同 study ID 不可转移到另一个账号；分配新账号时建立新的 study ID，保留相同源哈希与结果来源。不要公开测试账号令牌来共享资产。

新增接口：

- `GET /v2/reconstruction-studies`、`GET /v2/reconstruction-studies/:id`。
- `GET /v2/reconstruction-studies/:id/variants/:variantId/file`、`.../cameras`。
- `DELETE /v2/reconstruction-studies/:id`。

所有接口使用既有用户 Bearer 鉴权。这是私有结果分发通道；方案中的自动 `/reconstructions` 任务提交尚未实现。

既有 WorldMirror worker 的正式转换现在支持显式配置 `plyProfile: "worldmirror2-probability-v1"`，由来源配置经导入传递，缓存版本为 `splat-sh0-v2`。标准 gs_mcmc PLY 仍按 logit 解码。此轮未改变运行中的 worker 私有配置或批量迁移历史资产；之后部署时对已确认采用该导出格式的 worker 设置这一项。

## 下一步边界

Windows 端已验证真实双模型的来源、协议、完整下载和相机投影；iPhone 的实际画面、首帧、帧率、内存和发热仍未测量。后续在 Mac 安装 Xcode，按 [Mac／iPhone 指南](MAC-IPHONE-RUN.md) 编译，再连手机验收。

还未完成：稳定公网 HTTPS 的本次部署、手机新采集自动 SfM 任务、两模型的相似变换配准、SOG 解码、大场景 LOD streaming、碰撞行走。它们不会由本次 Windows 检查自动变成已完成。
