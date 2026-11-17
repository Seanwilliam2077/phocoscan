# 实施与验证记录

记录时间：2026-10-22 17:10（Asia/Shanghai）。项目：`D:\PocketWorld`。

**当前状态：Windows 本机后端已运行，iPhone 原生工程已生成；尚未完成 iOS 编译、签名、安装或真机闭环验收。**

## 已实际执行

| 项目 | 结果与证据范围 |
|---|---|
| Windows 环境 | Node.js v24.16.0，内置 node:sqlite；无需额外后端依赖 |
| 后端启动/停止/重启 | Start-Backend.ps1 / Stop-Backend.ps1 实际执行通过；服务在后台运行 |
| 健康检查 | `http://127.0.0.1:8787/health` 返回 `{ "ok": true, "version": "0.1.0" }` |
| 后端集成测试 | `npm.cmd test`：**17/17 通过**，0 失败；最后一次约 1.33 秒 |
| 操作员 CLI | jobs / metrics 实际可用；导出/导入/复核由独立测试服务验证 |
| 内测数据库 | users=0、sessions=0；没有把测试夹具写成真实扫描结果 |
| Xcode 工程生成 | 16 个 App Swift 源文件，1 个 XCTest 源文件，4 个资源项；主 target 与测试 target |
| 独立工程语法解析 | npm xcode 3.0.1 解析 project.pbxproj，通过；能识别 PocketWorld / PocketWorldTests |
| plist 解析 | 两份 Info.plist 与隐私清单通过独立 XML/plist 解析 |
| Swift 语法解析 | tree-sitter 0.25.2 + tree-sitter-swift 0.7.4，**17 个文件通过** |
| 原生路径结构检查 | 无 WebView；包含真实 AVFoundation 与 Metal 模块、任务资源、渲染依赖版本锁 |

语法解析只证明语法树可解析，**不检查 Apple SDK 类型、可用性、并发约束、链接、Metal 编译或运行行为**。Xcode 构建结果仍未知，不把这些检查称为 iOS 构建成功。

17 项后端测试覆盖：用户/管理员鉴权、跨用户隔离、原生与外部模型路径、重复/并发幂等、来源冲突、模型逐记录验证、损坏与超限文件、处理失败与重试、质量状态独立、重启持久化、事件幂等、补采与删除、原文件导出与范围下载、删除后的备份兼容及真实 CLI 调用。视频/模型测试文件是**合成夹具**，不是用户实采或真实重建效果证据。

## 已写但尚未运行的 iOS 检查

`ios/PocketWorldTests/GameRulesTests.swift` 含 8 项 XCTest：示例布局、旋转断路、网格边界、建筑不作为隐形道路、路口旋转、无效布局、庆典按进度开放、旧草稿解码。这些测试需在 Xcode 中执行，当前不能写为已通过。

原生工程已包含：九格建造、六任务、三居民、纯建设章节、庆典、原始视频采集与预览、手动扫描导入、文件传输、真实结果原生查看、存档与事件，以及数据删除。UI 布局、权限、相机方向、性能、热量、内存与触控尚无真机证据。

## 已处理的集成问题

- 录像侧车文件记录准确 session ID，恢复不再依据拍摄时间猜测来源。
- 新草稿先可靠保存再清理原片；保存失败保留恢复入口。
- 首次尝试上传前锁定原视频，避免上传回包丢失后重拍导致来源冲突。
- 媒体目录排除系统云备份；删除时处理本机原片、草稿、结果与服务端引用。
- 按服务器地址隔离凭证与存档；重新安装后的远端恢复决策持久化，避免网络失败后覆盖原有布局。
- 删除记录不会使远端存档必填字段变成 null；旧离线备份也不能复活被删会话。
- `result_viewed` 由 Metal 首帧实际呈现触发，下载完成不当作查看成功。

这些属于源代码审查修复。涉及 iOS 行为的部分仍需真机执行对应故障测试。

## 下一步必须具备的条件

1. **Mac + Xcode 16.3 或更新工具链**，实际解析 Swift 包并编译；检查所选 Xcode 与 iOS 版本兼容性。已准备版本锁，尚未执行 SwiftPM 构建。
2. Apple 开发签名条件与一台 **iOS 18+ iPhone**。目前未知手机型号、系统版本、Team 与可用签名方式。
3. 手机可达的后端。当前仅监听本机回环地址；局域网联调用 `Start-Backend.ps1 -Lan`。公网/蜂窝网络试验还需真实 HTTPS 部署，本期未创建公网隧道或开放防火墙。
4. 室内、室外各一条真实采集与返回结果，按 PHONE-ACCEPTANCE.md 记录来源、处理软件与设备。

本机后端只做文件流转和人工处理管理，不包含自动 3DGS 重建。Scaniverse 是手动扫描/导出路径，没有虚构的自动集成。当前未取得可靠逐帧相机参数、尺度或碰撞几何；**机器人/视频双用途仍未验证**。

## 重复执行

```powershell
cd D:\PocketWorld
npm.cmd test
node scripts/generate-xcode-project.mjs
node scripts/check-project.mjs
Invoke-RestMethod http://127.0.0.1:8787/health
```

完整启动与手机安装步骤见 README.md；操作员手册见 server/README.md；真机脚本见 PHONE-ACCEPTANCE.md。
