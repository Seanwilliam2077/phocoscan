# 微信小程序：Windows → iPhone → 数据回流

> 2026-10-23 更新：拾境首页 → 带小芽去扫描 → 同意本次用途 → 直接进入原生相机，无需先连接电脑。视频先保存到手机，可稍后在“回忆”打开同一草稿；点击“连接并提交／提交视频”才发起网络操作。已确认的服务器回执才让小芽成长。局域网无法互通时先验证离线相机；域名测试路线见 docs/CODESPACES.md，持续部署见 docs/CLOUD-DEPLOY.md。下文旧版“拍摄前连接”说明以此更新为准。

> 当前为极简版：打开首页 → 开始采集 → 确认室内/街景及本次用途 → 相机 → 预览提交。首次点击开始拍摄时尝试连接预设的本机服务，失败可在“设置”修改。无需命名小站、领六个任务或布置建筑；历史记录从首页“我的采集”进入。下文早期玩法步骤以此处为准，人工重建和数据来源约束继续有效。

日期：2026-10-22。以下取代此前 Mac/Xcode 安装路线。项目 `D:\PocketWorld`，开发工具 `D:\WeChatDevTools`。

## 1. 身份与扫码

1. 打开 [官方测试号申请页](https://mp.weixin.qq.com/wxamp/sandbox?doc=1)，本人微信扫码取得**小程序测试号 AppID**。不是公众号测试号；不要发 AppSecret。
2. 打开微信开发者工具，用同一微信扫码登录。需要 CLI 时，由用户在“设置 → 安全设置”开启服务端口；如果出现 Codex 授权提示，由用户确认。
3. 在项目目录执行 `node scripts/Set-WeChatAppId.mjs 真实AppID`。开发工具导入目录选 `D:\PocketWorld`，已配置 `miniprogram/` 为代码根。
4. 点击“预览”，iPhone 微信扫码。也可运行 `powershell -ExecutionPolicy Bypass -File .\scripts\WeChat.ps1 -Action Preview`，成功后打开 `runtime\wechat-preview.png`。

微信官方明确支持测试号真机预览，见 [申请测试号](https://developers.weixin.qq.com/miniprogram/dev/devtools/sandbox.html)。没有 AppID/登录时只能先完成代码和本地编译，不能声称可扫码。测试号不等同正式发布账号；本工程复用 Node 后端，不依赖云开发。

如果相机/聊天文件选择返回 `api scope is not declared in the privacy agreement`（errno 112）或 `appid privacy api banned`，需要该 AppID 管理员按平台提供的入口补充相机、视频/所选文件等实际使用内容的隐私声明。重新授权手机相机不能解决缺失的后台声明。当前微信可显示官方隐私授权弹窗，用户需自行同意；项目不自动接受。见 [微信隐私授权文档](https://developers.weixin.qq.com/miniprogram/dev/framework/user-privacy/PrivacyAuthorize.html)。测试号实际可配置范围以该账号后台为准。

## 2. 手机连后端

```powershell
cd D:\PocketWorld
npm.cmd --prefix server ci
powershell -ExecutionPolicy Bypass -File .\scripts\Stop-Backend.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\Start-Backend.ps1 -Lan
```

手机和电脑连接可互通的同一 Wi-Fi，小程序设置填启动器输出的 `http://电脑IP:8787`。不要填手机 localhost/127.0.0.1。局域网 HTTP 开发预览按官方测试号文档，在手机右上角菜单“打开调试”后重新进入；工程的开发配置已关闭合法域名校验。相机、录音、本地网络权限由用户授予。

连接失败：电脑先执行 `Invoke-RestMethod http://127.0.0.1:8787/health`，然后检查 LAN 绑定、IP 变化、路由/AP 隔离和 Windows 防火墙。脚本不关闭防火墙、不建立公网隧道。蜂窝网络远程测试需要另外部署 HTTPS 后端、配置平台域名与隐私声明。

## 3. 第一条录像闭环

1. 连接服务、命名小站，放置和旋转初始道路。
2. 探索页选“第一盏暖灯”，选择允许拍摄的静态室内/室外一角，选择游戏内录像，确认本次用途。微信视频可能包含环境声音。
3. 建议录 20–40 秒，保持画面重叠，缓慢横向/弧线移动并补侧面；不要仅站原地转手机。引导是玩家确认，未自动检测清晰度/覆盖率/位姿。
4. 预览真实视频再提交。文件先持久保存；失败留草稿，重试沿用同一会话。开始上传后锁定这一份源视频，若要重拍请另开任务，避免源数据错配。
5. 领取门厅卡、布置小站、完成居民愿望。基础奖励与模型处理独立，处理失败不撤回卡片。
6. 操作者在电脑查任务并导出真实源数据：

   ```powershell
   node server/admin.mjs jobs
   node server/admin.mjs export SESSION_ID D:\PocketWorld\work\capture-001
   node server/admin.mjs start JOB_ID
   ```

   导出目标必须是新目录。用**确实支持视频输入**的工具重建该包里的视频，再导入对应结果：

   ```powershell
   node server/admin.mjs import JOB_ID D:\真实结果\scene.ply --tool 实际软件 --version 实际版本
   ```

   失败就按 `server/README.md` 的 fail/retry 流程处理，不用别的场景冒充。
7. 小程序邮袋刷新，打开真实模型，单指环绕、双指缩放、重置。默认最多展示 6 万点；原始模型不覆盖。只有实际画出结果才记录 result_viewed。
8. 继续休息区、绿地、路口等探索，验证另一个室内外环境与再次打开动力。

## 4. Scaniverse 人工转接

先在小程序建外部扫描任务 → 手动到 Scaniverse 扫描/处理 → 导出 Gaussian PLY 或支持的 `.splat` → 自己发到微信会话 → 回对应探索记录，从聊天文件导入。`wx.chooseMessageFile` 不是 iPhone 通用文件浏览器，大文件可由电脑操作者导入。

普通点云 PLY 缺少 Gaussian 尺度、旋转、透明度等属性，不能代替。当前未实现 `.spz` 解码，改扩展名也不能导入。参考 [Scaniverse 官方流程](https://www.nianticspatial.com/docs/scaniverse/quickstart/)，本项目没有其自动 API，也不假定它支持导入本项目的 MP4。

此路径标记 external_asset_only，不能从 PLY 恢复原始时序视频。验证“一份数据两种用途”应走同一录像会话的导出/重建/导回路径，再验收相机估计、尺度/碰撞几何等。当前采集授权用于私有试验存储和评估，不自动覆盖所有未来训练用途。

## 5. 必须在 iPhone 完成的验收

| 项目 | 通过条件 |
|---|---|
| 预览/网络 | 真实微信预览码打开，连接电脑成功 |
| 室内录像 | 真相机视频可预览，重开小程序后草稿可提交，元数据来自视频 |
| 室外录像 | 出门前建任务，断网录制，回 Wi-Fi 上传 |
| 权限拒绝 | 拒绝相机后可返回，不产生假采集/奖励 |
| 弱网重试 | 单一会话不重复奖励，不换源视频，失败保留草稿 |
| 外部导入 | 本人的真实 Gaussian PLY 到正确任务，错误文件明确报错 |
| 3D GPU | 真模型可环绕缩放，记录帧率/发热，离页释放缓存/GPU |
| 建设 | 道路旋转改变连通，愿望/庆典/下一章偏好可保存 |
| 删除/隔离 | 删除会话后源文件与衍生物不可访问，不串账号/服务器 |

记录手机型号、iOS/微信版本、session ID、环境、耗时与失败原因。测试夹具和桌面编译通过都不是手机采集/重建成功。首次闭环后再邀请 3–5 人，优先观察二次打开、二次探索、有效视频比例和每条可用场景成本。

本期没有自动重建、质量评分、ARKit 位姿、碰撞网格、机器人策略或视频模型训练。先验证真实媒体和游戏闭环，再根据采集成功率扩展。

官方参考：[下载](https://developers.weixin.qq.com/miniprogram/dev/devtools/download.html)、[CLI](https://developers.weixin.qq.com/miniprogram/dev/devtools/cli.html)、[camera](https://developers.weixin.qq.com/miniprogram/dev/component/camera.html)。
