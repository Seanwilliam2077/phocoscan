# 拾境：用 GitHub Codespaces 测试手机上传

> 2026-10-26 验收进度：用户确认 iPhone 拍摄、上传、新回忆和小芽成长已成功。独立复核当前默认 Codespace 的全部会话和总奖励仍为 0，尚未对应到这次反馈；已请求手机实际服务地址及大致上传日期。手机端成功反馈与当前指定实例的存储核验分别记录，详见 docs/WEAPP-VALIDATION.md。以下 2026-10-23 部署和网络记录为历史，不推断转发故障已永久消失。

> 2026-10-23 实际进度：已在用户本人登录的 `Seanwilliam2077/shijing-mvp` 私有仓库创建东南亚 2 核 Codespace，云端 Node 24.21.0 全量 104 项测试通过。当前测试入口为 `https://super-duper-trout-g444676v9675h9gv4-8787.app.github.dev`，已打开 Public 端口；Windows 实际健康检查返回 200 JSON、无凭据访问采集记录返回 401。微信开发工具原生客户端已成功建立该 HTTPS 连接（connected:true、error 为空），未上传任何真实或合成采集媒体。iPhone 连接和真实拍摄仍待验收。下文未创建环境的文字是准备阶段记录，以本段为准。

这条路线只需要可使用 Codespaces 的 GitHub 账号。代码放在 GitHub，Node 服务在 Codespaces 内运行，iPhone 小程序通过转发的 HTTPS 地址访问。尚未创建 Codespace、开放公网端口或验证手机访问；本文件与配置只准备运行步骤。

## 创建测试环境

1. 将本项目的代码上传到你控制的 GitHub 仓库，建议使用个人私有仓库。不要上传 `server/data/`、`server/.local-config.json`、`runtime/`、原视频、模型或任何令牌；这些本地路径已列入 `.gitignore`。
2. 在仓库的 **Code → Codespaces** 创建个人计费归属的 2 核环境。创建前检查自己的可用额度与预算；不要选公司计费或更大机型来假设免费。
3. 等待配置安装 Node.js 24，并执行 `npm ci --prefix server`。每次环境启动会运行 `node scripts/start-codespace.mjs`，把本后端启动在 `0.0.0.0:8787`。
4. 终端看到 `Local health check passed` 才说明容器内服务已就绪。若生命周期输出没显示，可手动运行一次相同命令；已由此脚本启动的同一服务会复用，不重复启动。

配置使用 GitHub 默认通用镜像 `mcr.microsoft.com/devcontainers/universal:2` 加官方 Node Feature。默认镜像与自行替换的自定义基础镜像在存储计算上有所不同；切换镜像前查看 [GitHub 的存储计费说明](https://docs.github.com/en/billing/concepts/product-billing/github-codespaces)。此配置未在真实 Codespaces 内构建验证。

## 让微信访问测试地址

1. 打开 Codespaces 底部 **Ports**，找到 **8787**。容器内部协议保持 **HTTP**，代理对外提供 HTTPS。
2. 默认端口为私有。确认本次需要给手机测试后，由你将 **Port Visibility** 改为 **Public**。本配置和脚本不会自动更改可见性。若组织策略禁止 Public，不要尝试绕过策略，应使用你获授权的环境。
3. 从 Ports 复制实际地址，格式通常为 `https://你的Codespace名称-8787.app.github.dev`。脚本仅根据实际环境变量输出候选地址，并未证明公网访问已开放。
4. 在 iPhone Safari 打开该真实地址加 `/health`。无需 GitHub 登录，且返回 `{"ok":true,...}`，才说明微信可访问的网络入口已打通。若跳转 GitHub 登录，说明仍是私有端口；不要把 GitHub Token 放进小程序。
5. 在小程序 **设置 → 测试服务地址** 填刚复制的 HTTPS 根地址，不含 `/health`，点击保存连接。回到原本的本地视频记录，再点击提交。小程序仍使用自身的用户令牌隔离文件；GitHub 的端口地址不等于上传成功或重建成功。

公共端口允许知道地址的人连到测试服务，因此只在需要的测试期间开放。正式微信发布仍需按平台要求配置合法域名和隐私接口声明；Codespaces 的动态域名开发入口不代表已完成正式发布条件。[GitHub 官方端口说明](https://docs.github.com/en/codespaces/developing-in-a-codespace/forwarding-ports-in-your-codespace)解释了地址、协议、可见性与私有端口认证。

## 数据位置和导出

- 数据库、真实视频和模型：工作区 `server/data/`。
- 仅供操作者的本地配置：`server/.local-config.json`。脚本不输出其中的管理令牌，也不输出 Codespaces 的环境凭据。
- 启动记录和日志：`runtime/codespace-backend-8787.*`。

测试数据留在工作区磁盘，不会因 Codespace 停止而自动成为 GitHub 仓库内容。但删除 Codespace 会删除其中尚未另存的数据；保留期限与组织策略也可能影响生命周期。每轮真实采集后，用已有管理命令导出会话到新目录，再通过 Codespaces 文件下载功能保存到你控制的电脑磁盘：

```text
node server/admin.mjs jobs
node server/admin.mjs export 真实会话UUID exports/你新建的导出目录
```

`exports/` 已被忽略。不要为了备份而把原视频、模型、数据库或导出包提交到 Git；代码提交不会备份被忽略的数据。停止/删除环境前确认实际下载完成。

## 运行时间和额度

Codespaces 是开发测试环境，不能作为 24 小时稳定服务承诺。默认闲置约 30 分钟停止，恢复时脚本重新启动服务；本项目没有防休眠、自动刷新或持续保活。见 [GitHub 闲置超时说明](https://docs.github.com/en/codespaces/setting-your-user-preferences/setting-your-timeout-period-for-github-codespaces)。

按 GitHub 当前个人 Free 规则，月度包含 120 核时和 15 GB-month 存储，2 核环境约对应 60 小时运行时间，实际用量还取决于其它环境、存储占用和账户规则。未配置有效付款方式且额度耗尽会停止使用；已配置付款方式时需检查预算，不能认为无限免费。以 [GitHub 当前账单页面](https://docs.github.com/en/billing/concepts/product-billing/github-codespaces)和账户实际余额为准。

## 本地验证脚本而不碰正式服务

脚本支持 `TEST_PORT`、`DATA_DIR`、`POCKETWORLD_CONFIG`、`POCKETWORLD_RUNTIME_DIR`，可把启动、幂等复用、错误端口占用检查放在独立临时目录和其它端口测试。不要把这些测试路径设到已有真实数据目录。脚本只检查启动时的健康状况，不执行用户拍摄、上传或重建；这些仍须实际验收。
