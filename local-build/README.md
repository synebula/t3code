# t3 本地构建与安装

构建只产出一个目录 `t3-<version>-<platform>-<arch>/`（例如 `~/tmp/t3-0.1.6-linux-x64/`）：可以直接 `serve` 或整体 `mv`。目录名带版本等信息便于并列保留多份构建，里面的命令始终是 `t3`。安装成后台服务时才由目录内的 `install.sh` 现场打包；构建阶段不生成 tar。

本目录独立于上游文件：所有脚本与说明都放在 `local-build/` 下，不修改 `scripts/`、`docs/` 或任何源码，因此从上游同步时不会产生冲突。唯一的例外是提示词开关本身，它属于一项独立的功能改动，说明见 `docs/operations/minimal-agent-prompts.md`。

## 构建

在仓库根目录执行：

```sh
./local-build/build-local-release.sh
# 输出：~/tmp/t3-0.1.6-linux-x64/（版本与架构随 checkout/主机而定）
```

常用参数：

```sh
./local-build/build-local-release.sh --repo /path/to/t3code   # 指定 checkout
./local-build/build-local-release.sh --output-dir ~/apps      # 指定父目录，得到 ~/apps/t3-0.1.6-linux-x64
./local-build/build-local-release.sh --resource-monitor-binary /path/to/t3-resource-monitor
./local-build/build-local-release.sh --skip-build             # 复用已有构建，只重新组装
./local-build/build-local-release.sh --no-resource-monitor    # 不构建 Rust 资源监控
```

脚本依次执行：

1. `vp run --filter @t3tools/web build`
2. `node apps/server/scripts/cli.ts build`（把 web 复制进 `dist/client`）
3. `node apps/server/scripts/cli.ts build-exe --target <platform>-<arch>`
4. 有 `cargo` 时构建 `t3-resource-monitor`，否则留空（可用 `--resource-monitor-binary` 指定预编译文件）
5. 调用上游 `scripts/build-cli-archive.ts` 生成归档
6. 解压归档为 `t3-<version>-<platform>-<arch>/`，放入 `install.sh`

说明：上游组装脚本内部会临时生成 tar，解压后即删除；最终落盘只有带版本信息的目录。

## 目录结构

```
t3-0.1.6-linux-x64/
├── t3                      # SEA 单文件可执行程序
├── client/                 # web 前端；server 从可执行文件旁查找 index.html
├── resource-monitor/       # Rust sidecar，可选
├── node_modules/           # 运行时外部依赖
├── lib/libatomic.so.1      # Linux 自带，RUNPATH 为 $ORIGIN/lib
└── install.sh              # 安装为后台服务时使用
```

这些路径都相对可执行文件解析，因此 `mv ~/tmp/t3-0.1.6-linux-x64 ~/apps/` 后可直接从新位置运行。必须整体移动，不要只复制 `t3`。

## 安装为后台服务

在布局目录内执行即可，脚本以自己的目录为安装根：

```sh
~/tmp/t3-0.1.6-linux-x64/install.sh
```

`install.sh` 会：读取 `t3 --version` → 在临时目录现场生成 `t3-<version>-<platform>-<arch>.tar.gz` 与 `SHA256SUMS` → 在 `127.0.0.1` 上临时提供该目录 → 用 `T3CODE_RELEASE_BASE_URL` 执行 `t3 up --lan --yes`，让 systemd/launchd 服务运行这份构建，而不是下载上游运行时。安装结束后临时包自动删除。

包名中的 version/platform/arch 是 `t3 up` 的硬性格式，只存在于临时目录，不属于构建产物。

常用参数：

```sh
./install.sh --dir ~/apps/t3-0.1.6-linux-x64   # 指定布局目录；默认取脚本所在目录
./install.sh --base-dir ~/.t3         # T3 数据目录（默认 $T3CODE_HOME 或 ~/.t3）
./install.sh --no-lan                 # 只允许本机访问
./install.sh --reinstall              # 同版本重建后必加：先停服务并移走旧 runtime
./install.sh --pack-only ~/rel        # 只生成 tar + SHA256SUMS，不安装
./install.sh --keep-bundle ~/rel      # 安装同时保留生成的包
```

注意事项：

- 同一版本号重新构建时必须加 `--reinstall`，否则 `.install-complete` 会让安装器跳过下载；旧 runtime 会移到布局目录旁的 `t3-runtime-backups/`。
- 构建机没有 `cargo` 时，用 `--resource-monitor-binary <文件>` 把已有的 `t3-resource-monitor` 打进布局目录，避免功能缺失。
- 没有 systemd 的环境（容器、WSL1 等）直接按“运行”一节前台启动。

### 换到另一台新机器

```sh
rsync -a ~/tmp/t3-0.1.6-linux-x64 user@newhost:~/app/
ssh user@newhost '~/app/t3-0.1.6-linux-x64/install.sh'
```

同架构 Linux，目标机需要 `python3`。用 `rsync -a` 或 `cp -a` 保留符号链接和执行位，整目录一起拷。

## 非 Debian 主机

上游脚本用 `dpkg-query` 读取 libatomic 的包版本。Arch 等主机没有该命令，脚本会在临时构建目录里生成一个 `dpkg-query` shim（从 `pacman -Qoq` / `pacman -Q` 取信息），仅在该次构建的 `PATH` 中生效；解压后再把归档里的许可证头改写为实际的 Arch 包信息。仓库本身不做任何修改。

## 运行

```sh
T3CODE_HOME=/tmp/t3-local-home \
  ~/tmp/t3-0.1.6-linux-x64/t3 serve --host 127.0.0.1 --port 47917 --no-browser
```

打开输出的 pairing URL（直接访问根路径不会通过认证）。`T3CODE_HOME` 用于隔离状态，不要指向正在使用的 `~/.t3`。

提示词开关由二进制读取：

```sh
# 默认：不注入 T3 额外提示词，也不下发 t3-code MCP 工具
~/tmp/t3-0.1.6-linux-x64/t3 serve ...

# 恢复上游行为
T3_CODE_EXTRA_INTEGRATIONS=1 ~/tmp/t3-0.1.6-linux-x64/t3 serve ...
```

## 卸载

- `t3 uninstall --yes`：停止并删除后台服务（systemd 用户单元 `t3code.service` 或 launchd plist）、启动器符号链接，以及整个 `~/.t3/runtime`（所有下载版本与 `service-state.json`）；`~/.t3/userdata`（项目、线程、设置）保留。不会关闭 linger。
- `t3 service uninstall`：只停止并删除服务单元，保留 runtime 与数据。`install.sh --reinstall` 内部使用的就是它。
- 非终端环境必须带 `--yes`，否则命令会直接拒绝执行。
- 它只处理与当前 `T3CODE_HOME`/`--base-dir` 匹配的服务单元；换过数据目录时要显式指定。

## 常见问题

- `node_modules/.bin/vp is missing`：先在 checkout 里安装依赖。
- `Native CLI executables must be built with Node ...`：脚本已固定传 `--target`，若仍出现，确认 checkout 的 `apps/server/scripts/cli.ts` 未被改动。
- `t3 serve` 正常但页面空白：确认 `client/index.html` 与 `t3` 同级。
- 安装时报 `no executable t3` / `client/index.html is missing`：布局目录不完整，重新 `rsync -a` 整个目录。
- 资源监控不可用：`resource-monitor/` 为空。安装 Rust 后重新构建，或构建时用 `--resource-monitor-binary` 指定已有的 `t3-resource-monitor`。
- 找不到 `scripts/build-cli-archive.ts`：脚本按自身位置定位仓库根目录，需保持 `local-build/` 位于 checkout 根目录下，或者用 `--repo` 指定。
