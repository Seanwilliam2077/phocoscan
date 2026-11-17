# 拾境：域名与 HTTPS 后端部署

状态：部署文件已准备，尚未创建云资源、发布代码或启动容器。本机未检测到 Docker，因此尚未验证镜像构建、Compose 启动、真实证书与手机公网连接。

GitHub 私有仓库存放代码；运行中的 Linux 服务器保存视频、SQLite 数据库和重建结果。GitHub Pages 用于静态网页，不能运行本项目的 Node 上传服务和持久数据库。小程序继续用微信开发工具生成预览码，连接 `https://自己的域名`。

本方案是一个服务器上的单个 Node 24 实例、持久磁盘及 Caddy HTTPS 代理。不要横向扩容这个 SQLite 实例，也不要放到休眠、临时磁盘或无状态函数里。镜像只复制 `server/src/`、入口、管理 CLI 与锁定依赖；服务端任务定义已在代码内，不依赖仓库的图片、采集文件或 miniprogram 数据目录。

## 首次部署

准备有公网地址的 Linux 服务器、Docker Engine 与 Compose 插件、一个自己控制的域名。服务器和磁盘会产生供应商费用，本文件不创建或购买它们。

1. 把域名或子域名的 DNS A 记录指向服务器公网 IPv4。只有服务器确实支持 IPv6 时才加 AAAA 记录。云防火墙允许 TCP 80、443；不开放 8787。
2. 通过受信任的 GitHub 登录或 SSH 方式，把私有仓库克隆到服务器。不要把访问令牌写进仓库、命令参数或聊天。
3. 在仓库根目录执行：

   ```sh
   cp deploy/.env.example deploy/.env
   # 编辑 deploy/.env，把 DOMAIN 改为自己的真实域名。
   docker compose --env-file deploy/.env -f deploy/compose.yaml config --quiet
   docker compose --env-file deploy/.env -f deploy/compose.yaml build
   docker compose --env-file deploy/.env -f deploy/compose.yaml up -d
   docker compose --env-file deploy/.env -f deploy/compose.yaml ps
   ```

4. 检查容器内部健康，再从手机蜂窝网络检查域名：

   ```sh
   docker compose --env-file deploy/.env -f deploy/compose.yaml exec app node --input-type=module -e "const r=await fetch('http://127.0.0.1:8787/health');console.log(await r.json())"
   ```

   手机 Safari 打开 `https://自己的域名/health`，应收到 `{"ok":true,"version":"0.1.0"}`，且没有证书错误。Caddy 会在 DNS 和 80/443 可达时申请、续期证书；内部健康不代表证书和公网路由已经成功。排查时可查看 `docker compose --env-file deploy/.env -f deploy/compose.yaml logs --tail 80 app caddy`。

`pocketworld` 命名卷同时保留 SQLite、视频与 `/var/lib/pocketworld/.local-config.json`。管理员凭据由现有服务第一次启动时随机生成，文件权限为 0600，不从示例环境变量或源码读取。管理 CLI 在容器内部使用此文件，不需要展示或复制凭据。Caddy 的证书保存在独立命名卷。

更新代码后重新 `build`、`up -d`，沿用同一个 Compose 项目和这些卷。停止服务可用 `down`；不要使用 `down -v`，它会删除持久卷。迁移或备份需同时保留整个应用卷与配置文件；SQLite 处于写入时不要只复制单个数据库文件，先停止应用再做一致性卷备份。

## 接回微信小程序

1. 在小程序“设置”填写 `https://自己的域名` 并保存连接；不要附 `/health` 或 `/v1`。也可更新 `miniprogram/lib/config.js` 的默认地址，再由微信开发工具生成新预览码。
2. 正式小程序账号在微信公众平台的开发设置中，把该 HTTPS 域名加入实际使用的 request、uploadFile、downloadFile 服务器域名；按账号要求完成域名与隐私配置。测试号可配置范围以其后台为准，不把开发调试当作正式配置成功。
3. 用手机蜂窝网络依次验证：健康检查、连接身份、真实录像、上传、重新打开后记录仍在。已有局域网地址的账号与新域名是不同连接配置，客户端不会静默把已绑定旧服务器的数据发到新地址；已有草稿须保留并按迁移流程核对。

## 人工重建闭环

以下命令都在仓库根目录执行，命令中的 ID、软件与文件必须来自本次真实采集。上传原始数据的接收方是部署的服务器；GitHub 仓库不存放用户视频、导出包或管理员配置。

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml exec app node admin.mjs jobs
docker compose --env-file deploy/.env -f deploy/compose.yaml exec app node admin.mjs export SESSION_ID /var/lib/pocketworld/operator/export-001
docker compose --env-file deploy/.env -f deploy/compose.yaml exec app node admin.mjs start JOB_ID
mkdir -p exports
docker compose --env-file deploy/.env -f deploy/compose.yaml cp app:/var/lib/pocketworld/operator/export-001 ./exports/export-001
```

`export` 的目标必须是新目录。使用确实支持该视频输入的软件处理同一个导出包，再把结果传回服务器上的本地文件路径：

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml cp ./exports/scene.ply app:/tmp/scene.ply
docker compose --env-file deploy/.env -f deploy/compose.yaml exec app node admin.mjs import JOB_ID /tmp/scene.ply --tool 实际软件 --version 实际版本
```

相同会话的结果才可导回该任务；手机刷新后查看真实 3DGS。未实现自动重建、相机位姿、标定或训练质量验收。Scaniverse 自行扫描后导入的资产仍属于外部资产路径，不能冒充本项目视频的重建结果。

配置依据：[Caddy 自动 HTTPS](https://caddyserver.com/docs/automatic-https)、[流式反向代理与超时](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)、[请求体大小限制](https://caddyserver.com/docs/caddyfile/directives/request_body)、[Compose 环境变量](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/)。
