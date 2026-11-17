# Windows 本机虚拟机：FF 测试环境

> 2026-11-03 检查记录。虚拟机用于在隔离的 Linux 环境运行 PocketWorld Node 服务、FFmpeg、WorldMirror 出站 worker 和测试。它不能编译原生 iPhone App；Xcode 编译、签名和 ARKit／Metal 真机验收仍在 Mac 与 iPhone 上进行。

## 本机实测状态

| 项目 | 结果 |
|---|---|
| 系统 | Windows 11 专业版，build 26200；AMD Ryzen AI 9 HX 370，约 64 GB 内存 |
| 虚拟化 | 固件虚拟化 `True`，`VirtualMachinePlatform` 已启用；Hyper-V 全量组件未启用 |
| WSL 运行时 | 用户已完成 Windows 重启；已通过微软 WinGet 安装 WSL `2.7.14`，内核版本 `6.18.33.2-2` |
| Ubuntu | `Ubuntu-24.04` 已安装并启动，系统报告 Ubuntu `24.04.5`，PID 1 为 systemd |
| VM 文件位置 | `D:\PocketWorld\work\wsl\Ubuntu-24.04`；位于被 Git 忽略的工作目录 |
| 依赖 | Node `24.22.2`；FFmpeg `n9.0.2-45-g1e65c6cd5d-20261102`；均为 Linux 二进制，已核对下载 SHA-256 |
| 业务服务 | Linux 用户 `pocketworld`；`pocketworld-backend.service` 已启用且 active；固定监听 VM 内 `127.0.0.1:8787`；启动脚本以隐藏的 WSL 进程维持测试期间运行 |
| 数据与配置 | `/home/pocketworld/PocketWorld/server/data` 和 `server/.local-config.json` 持久保存；私有配置权限 `0600` |
| 服务端验证 | Ubuntu 内测试 **74/74 通过**；Windows 的 `http://127.0.0.1:8787/health` 返回 `ok:true` |
| 其他 VM | 未发现 Docker Desktop、VirtualBox 或 VMware Workstation 的常见安装路径 |
| Hub 网络 | Windows 主机可达；Ubuntu 内 curl 已成功读取 `9.135.79.113:8000` 的 capabilities，返回 `worldmirror2`、`available:true` |

Ubuntu 已实际运行，业务服务和测试依赖已配置。VM 当前使用默认 NAT；试验 mirrored 网络后仍无法完成互联网 apt 下载，试验用 `.wslconfig` 已移除并恢复默认 NAT。Hub 内网访问正常。capabilities 只证明 VM 能访问 FF 接口，不证明 GPU 空闲或任务已经重建成功。

## 已执行的安装与后续核验

本次使用的管理员 PowerShell 安装命令如下，已经完成安装时无需重复执行：

```powershell
winget install --id Microsoft.WSL --exact --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
wsl --install -d Ubuntu-24.04 --no-launch --web-download --location D:\PocketWorld\work\wsl\Ubuntu-24.04
wsl --list --verbose
```

`wsl --list --verbose` 已确认 Ubuntu 的 `VERSION` 为 `2`。服务使用本机 Linux 用户 `pocketworld`，PID 1 为 systemd。参照 [Microsoft 的 WSL 安装说明](https://learn.microsoft.com/en-us/windows/wsl/install)。

由于 WSL 的互联网 apt 下载超时，本次通过 Windows 下载 Linux 发行包并核对发布方 SHA-256，再解包到 VM：

- Node 官方包安装于 `/opt/node-v24.22.2-linux-x64`。
- FFmpeg Linux 构建安装于 `/opt/ffmpeg-n9.0-latest-linux64-gpl-9.0/bin`。
- 常用命令的符号链接在 `/usr/local/bin`。完整来源、大小、SHA-256 及 npm cache 记录在 `D:\PocketWorld\work\vm-deps\manifest.json`，不含凭据。
- `npm ci` 使用从 Windows 复制的包缓存离线安装；Linux 的 `server/node_modules` 独立创建，没有共享 Windows 的依赖目录。

从 Ubuntu 检查 FF 服务是否可达：

```bash
curl -fsS http://9.135.79.113:8000/api/3dgs/quick-reconstruct/capabilities
```

本次已看到 `engine: worldmirror2` 和 `available: true`。此前任务因 GPU 6 固定绑定与空闲显存门槛而超时；14:26 按用户指示调整独立 `rshub-worker.service` 为 GPU 7，并仅重启 worker。14:28 新合成任务 project `42cee8632a77`／step `bb77fb6ecb57` 达到真实 `SUCCESS`、exit code 0，已下载并解析 33,363,528 字节、490,634 点的 PLY。报告耗时约 65.036 秒。该任务验证远端运算恢复，不是 iPhone 或完整 v2 链路验收。详见 [服务器恢复与诊断记录](APP-FF-VALIDATION-2026-11-03.md)。

## 在 VM 中测试服务端

当前工程代码已复制到 `/home/pocketworld/PocketWorld`，业务服务已启动。日常从 Windows 执行：

```powershell
powershell -ExecutionPolicy Bypass -File D:\PocketWorld\scripts\Start-WSL-Backend.ps1
powershell -ExecutionPolicy Bypass -File D:\PocketWorld\scripts\Test-WSL-FF.ps1
```

`Test-WSL-FF.ps1 -SkipServerTests` 和完整服务端测试已实际通过。最终检查发现，只有 systemd 服务时，所有前台 `wsl.exe` 命令结束后发行版仍会停止；这是 [WSL 的 systemd 行为](https://learn.microsoft.com/en-us/windows/wsl/systemd)。启动脚本现会运行一个隐藏的 `wsl.exe`，通过 Linux `flock` 持有专用锁并执行 `sleep infinity`，让测试 VM 保持运行。重复启动已实测成功，Linux 内仅有一个保活 sleep 进程；随后 **45 秒不执行任何 Linux 命令**，Windows localhost 健康接口仍返回 `ok:true`，`wsl --list --verbose` 仍报告 Ubuntu-24.04 为 `Running`、`VERSION 2`。

**Windows 每次重启后，先重新运行 `Start-WSL-Backend.ps1`。**脚本不注册 Windows 开机启动，也不修改全局 `.wslconfig`。结束测试时可停止这个专用测试发行版及其中的所有进程，磁盘中的数据和配置会保留：

```powershell
wsl --terminate Ubuntu-24.04
```

后续更新源码时，须继续排除 Windows 的 `node_modules`、`server/data` 和 `.local-config.json`，保留 VM 的数据与私有配置。

私有出站 worker 配置已保存在 `/home/pocketworld/PocketWorld/work/worldmirror-worker.json`，绑定这个持久业务服务，并使用 FFmpeg 的实际可执行文件路径。配置加载和带管理员鉴权的 jobs 只读查询已通过。**VM 安装验证没有启动 watch 或提交 GPU 任务；后续远端恢复验证使用了独立的明确合成任务。**需要处理某条明确任务时，按 [WorldMirror 接入说明](WORLDMIRROR-INTEGRATION.md)传入其固定 `jobId`；不要把私有配置或管理员凭据复制到聊天或 Git。原片可从 `/mnt/d/PocketWorld/input` 读取。

Windows localhost 健康检查通过，只证明这台电脑能调用 VM 服务。此前 iPhone 与 Windows 位于企业 Wi-Fi 下时，手机打不开电脑端口；WSL2 不会消除这层网络隔离。手机上传测试仍需一个 iPhone 可访问、稳定的 HTTPS **业务后端**。[Microsoft WSL 网络说明](https://learn.microsoft.com/en-us/windows/wsl/networking)。

## 本轮验收边界

Ubuntu 已安装且 `pocketworld-backend.service` 已创建。目标发行版固定为 `Ubuntu-24.04`，Linux 工程位于 `/home/pocketworld/PocketWorld`，服务以 `pocketworld` 用户运行；这些辅助脚本只启动或检查既有环境，不安装发行版或依赖。

`Start-WSL-Backend.ps1` 启动持久配置的业务服务，维持一个隐藏的 WSL 保活进程，并检查锁与 VM 内健康接口；Linux 锁保证重复调用不会累计保活进程。`Test-WSL-FF.ps1` 检查 Node、FFmpeg、服务端测试、VM 内健康接口和 Hub capabilities；不上传图片，不创建 GPU 任务。已有测试通过且仅需重新检查网络时可加 `-SkipServerTests`。Hub capabilities 的 `available:true` 只说明接口报告引擎可用，GPU 排队和真实结果仍需单独核对。

1. **已通过：** Ubuntu WSL2 启动，Node／FFmpeg 可用，VM 能读 Hub capabilities，服务端测试 74/74 通过，业务服务和 Windows localhost 健康检查通过。
2. **已通过的合成视频检查：** 在 VM 内对 8 秒合成视频解码并抽取 8 帧，输出保存在 `work/t0-vm-synthetic`。源视频 SHA-256 为 `556017f023fc93399385a97afc817838b28e6e756e8bf5de9d09ffb0d5a013af`。它只验证视频工具，不是 iPhone 实拍或重建质量证据。
3. **远端运算已恢复：** 切换到 GPU 7 后，独立 8 图合成任务已真实成功，PLY 下载与结构校验通过；Hub 仍报告 `preview_ready=false`、`sog_size=0`。
4. **待完成：** 原始 iPhone 视频的真实 FF 终态、同源 PLY／展示文件；iPhone App 的拍摄、HTTPS 上传和 Metal 预览，以及场景质量评估。SfM 不参与本轮 FF 验收。
