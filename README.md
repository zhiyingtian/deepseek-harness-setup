# DeepSeek Harness Setup

在 Ubuntu 或 WSL2 Ubuntu 上以普通用户安装、升级和管理 DeepSeek Harness Web 服务。程序使用官方 npm 包，无需构建源码，不修改系统 Node、shell 配置或 systemd 服务。

## 文件说明

| 文件 | 用途 |
|---|---|
| `install-upgrade.sh` | 首次安装与后续升级，准备私有 Node/pnpm，并安装插件市场 |
| `dshctl.sh` | 启动、停止、重启、查看状态与日志 |
| `test-install.cjs` | 不访问外网的安装、升级和回滚集成测试 |
| `.gitignore` | 排除运行数据、测试产物、环境配置及日志 |

## 环境要求

- 目标系统：Ubuntu 22.04/24.04，或 WSL2 中的 Ubuntu；架构为 x86_64 或 ARM64。
- 使用 Bash，预先具备 `curl`、`tar`、`xz`、`sha256sum`、`python3`、`flock`、`timeout` 及常规 Linux 命令。
- 能访问 `https://nodejs.org` 和 npm registry；第三方依赖的安装脚本还可能访问其发布站点。
- 默认使用 dsh 自身的本机监听地址及端口，当前端口为 **3080**。安装前确认端口没有被其他服务占用。

脚本会下载 Node 22 LTS（至少 22.19），对照官方 SHA-256 清单校验下载归档，并私有安装 pnpm 11.7.0；不要求预装 Node 或 npm。缺少系统命令时请管理员通过 Ubuntu 软件源准备，脚本不会自动提权。若原生依赖没有可用的预编译产物，可能还需要 Python 和 `build-essential` 等构建工具；不要通过忽略安装脚本绕过原生模块构建。

## 安装与升级

在目标 Ubuntu 或 WSL 终端中，进入本仓库目录：

```bash
cd ~/workspace/deepseek-harness-setup
bash install-upgrade.sh
```

目录位置可以不同，两个 shell 脚本应放在同一个目录。首次执行安装，再次执行升级；不需要预先卸载。默认查询官方 npm 的 `latest`，不自动选择 `next` 或 alpha，但 `latest` 本身仍可能指向 RC；执行前后以实际输出版本为准。同一版本重复执行也会创建新的安装目录，并非跳过安装。

默认通过 `dsh plugin --profile web add dshmarket` 安装、启用插件市场。每次安装或升级都会执行该步骤，不自动升级其他第三方插件。原有插件配置、会话和模型配置会保留；不代表旧插件一定兼容新的 dsh，仍需在页面验收。

### 参数

| 参数 | 行为 |
|---|---|
| `--version <值>` | 指定 npm 精确版本或发布标签，优先于 `DSH_VERSION` |
| `--dry-run` | 仅显示计划，不联网、不写文件、不验证远端版本是否存在 |
| `--no-start` | 安装完成后不启动 Web；升级时若旧服务正在运行，会先停止它 |
| `-h`、`--help` | 显示帮助 |

```bash
# 精确版本示例，不表示此版本是当前最新版
bash install-upgrade.sh --version 0.2.1-rc.2

# 明确选择 next 通道
bash install-upgrade.sh --version next

# 预览计划
bash install-upgrade.sh --dry-run

# 安装但不启动，稍后手动启动
bash install-upgrade.sh --no-start
bash dshctl.sh start
```

### 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DSH_BASE` | `~/deepseek-harness` | 安装和数据根目录，必须是绝对路径且不能是 `/` |
| `DSH_VERSION` | `latest` | dsh 的 npm 版本或发布标签 |
| `NODE_VERSION` | 自动选择最新 Node 22 LTS | 可固定为官方版本，例如 `v22.23.4`，必须至少为 22.19 |
| `NPM_REGISTRY` | `https://registry.npmjs.org` | npm registry，不改变 nodejs.org 的下载地址 |
| `NETWORK_TIMEOUT` | `300` | 网络请求／安装步骤的超时秒数，不是全流程总耗时 |

脚本不提供自定义 Web 端口参数，不传 `--port`。默认安装到当前用户 home 目录下的 `deepseek-harness/`，不会写入仓库目录。可通过 `DSH_BASE` 指定自定义绝对路径；自定义安装目录时，后续安装和服务管理也必须传入相同的 `DSH_BASE`，脚本不会自动记住它：

```bash
DSH_BASE=/absolute/path/to/dsh bash install-upgrade.sh
DSH_BASE=/absolute/path/to/dsh bash dshctl.sh status
```

## 访问 Web

安装并启动成功后，安装器会在最终成功摘要中打印带 token 的完整 Web 链接（`--no-start` 不会启动 Web，也不会打印新链接）。请使用输出的真实地址，不要使用下面示例中的省略号；认证成功后地址栏可能自动清除 token。token、日志和数据备份都应视为私有信息，不要提交到 Git 或公开分享。

### 本机 Ubuntu

浏览器打开输出的 `Web URL`，形如 `http://127.0.0.1:3080/?token=...`。

### WSL 与 Windows

在 WSL2 Ubuntu 中安装并启动后，在 Windows Edge/Chrome 中打开输出的 `Windows browser (WSL localhost)`，形如 `http://localhost:3080/?token=...`。无需 X Server、X11 转发或 SSH 隧道。

WSL 默认 NAT 网络依赖 `localhostForwarding`（默认开启）；镜像网络也支持 localhost。Windows 无法访问时，先确认 WSL 内服务正常，再检查 Windows 端口冲突、WSL 转发设置和公司防火墙策略。不要直接改成对公网监听。Windows 重启、WSL 关闭或执行 `wsl --shutdown` 后，进入 WSL 再执行 `bash dshctl.sh start`。

### 远程 Ubuntu

在个人电脑上运行服务输出的 SSH 转发命令，不带 `-N`。端口为 3080 时形式如下：

```bash
ssh -L 3080:127.0.0.1:3080 用户名@服务器
```

保持 SSH 连接，并在个人电脑浏览器中打开完整认证 URL。运行 dsh 的服务器不需要安装桌面环境。进入 Web 后在模型设置中配置 API；不要把 API 密钥放入命令行或版本库。

## 服务管理

```bash
bash dshctl.sh start
bash dshctl.sh stop
bash dshctl.sh restart
bash dshctl.sh status
bash dshctl.sh logs
bash dshctl.sh logs 200
```

不传参数等同于 `status`。服务未运行时 `status` 返回非零；`stop` 不删除程序或数据。`restart` 使用当前安装版本，不执行升级。每次启动会重新写入 Web 日志，状态输出的认证地址优先于历史日志中的地址。

这是用户后台进程，不是 systemd 服务，不配置开机自启。主机的会话清理策略可能终止后台进程；需要长期无人值守时，由管理员另行配置服务管理。安装和运行请使用同一账号，不要混用 root 或 sudo。

## 数据与回滚

默认运行目录为 `~/deepseek-harness/`（自定义 `DSH_BASE` 时则为指定目录）：

```text
~/deepseek-harness/
	current -> releases/dsh-<版本>-<时间>-<进程号>/
	nodes/       私有 Node 运行环境
	releases/    每次安装的程序版本和 profile 暂存／恢复副本
	data/        dsh 数据、会话、模型配置及 profiles/web
	workspace/   默认工作目录
	backups/     升级前的 data 归档
	logs/        Web 日志 web.log
	downloads/   Node 下载缓存与校验清单
	cache/       npm、node-gyp 等缓存
	tmp/         临时目录
```

升级先下载、安装新程序，再停止旧进程并备份数据；插件市场在 Web profile 副本中安装，成功后才切换。插件安装失败会保留原程序和 profile；新程序启动检查失败会恢复原程序及原 Web profile，旧服务原先运行时会尝试重新启动它。

**回滚不是完整数据恢复。** 其他数据不会自动覆盖回备份，避免丢失新内容；启动期间可能发生的数据迁移需要另行评估，备份位于 `~/deepseek-harness/backups/`。不要删除整个安装根目录，也不要只移动已经安装的脚本／运行目录，其中含绝对路径和符号链接。旧版本、下载和备份不自动清理，定期关注磁盘空间。使用自定义 `DSH_BASE` 时，将上述路径替换为对应根目录，并自行确保该目录不提交 Git。

## 排查与验证

启动失败时先运行 `bash dshctl.sh status` 和 `bash dshctl.sh logs 200`。端口被占用时不要盲目停止其他进程；依赖下载失败时检查网络和 registry，安装耗时超过限制时可调整 `NETWORK_TIMEOUT`。启动检查验证认证跳转、HTTP 2xx 和已知插件加载错误，不保证浏览器全部插件或模型调用可用。

开发测试需要已有 Node 22.19+、curl、tar 和 xz，在仓库根目录执行：

```bash
bash -n install-upgrade.sh dshctl.sh
node --test test-install.cjs
```

测试模拟 Node 下载及 npm 安装，使用真实的本地 HTTP 服务检查默认端口规则、市场安装、其他插件保留、认证跳转、重启、升级、备份及失败回滚；不会升级实际部署。测试文件仅位于 `.test-work/`，实例在结束后清理。此测试不等于官方 npm 包在所有 Ubuntu 环境的实机验收，也不验证 Windows 浏览器；仓库不包含运行数据、凭据和真实访问令牌。