# superng6/alpine s6-overlay v3 基础镜像 PRD

本文档记录 `v3` 分支的目标、兼容承诺和边界。修改或审查本分支前请先读第 4、5 节：其中列出的现象是已评估过的设计取舍或上游行为，不是缺陷，不要当成问题重复提出或“修复”。

最后核对：2026-11-15，Alpine 3.24.4，s6-overlay 3.2.3.2。

## 1. 定位

- 这是 SuperNG6 各下游镜像（`docker-aria2`、`docker-qbittorrent`、`Docker-qBittorrent-Enhanced-Edition` 等）共用的 base 层。
- `main` 分支是 s6-overlay v2（2.2.0.3）版本，是当前的正式版本。
- `v3` 分支是 s6-overlay v3 版本，处于开发测试阶段，**暂不取代 v2**。
- 构建方式不变：基于官方 `alpine:${VERSION}`，叠加 s6-overlay 发布包和 `root/` 下的文件。

## 2. 目标与非目标

目标：

1. 使用 v2 base 的下游项目只把 `FROM` 换成 v3 base、其余不修改，就能构建并正常运行。
2. v3 镜像与 v2 镜像并存发布，互不覆盖标签。
3. 兼容行为由 CI 中的测试固定下来，而不是靠文档约定。

非目标：

- 不追求日志文本、进程树、内部目录结构与 v2 逐字节一致。
- 不支持 Docker Mods（`DOCKER_MODS`）。
- 不修补 s6-overlay 上游已弃用的功能（见 5.2）。
- 不引入 LinuxServer.io 的 `init-*` s6-rc 服务骨架。

## 3. 兼容承诺

以下行为与 v2 一致，由 `.github/scripts/test-base-contract.sh` 逐项断言；改动 `Dockerfile`、`install.sh`、`root/` 后必须保持通过。

| 承诺 | 实现方式 |
| --- | --- |
| `/etc/cont-init.d`、`/etc/services.d`、`/etc/cont-finish.d` 照常执行 | s6-overlay v3 的 legacy 支持 |
| 上述目录中的脚本即使是 `0644` 也能执行 | `legacy-compat` 启动时补可执行位 |
| `/var/run/s6/services/<服务名>` 可用于 `s6-svc`、`s6-svstat` | `legacy-compat` 建立 `/run/s6/services -> /run/service` |
| `/bin/execlineb`、`/bin/s6-svc` 等 v2 绝对路径可用 | 构建时把 `/command/*` 链接到 `/bin` |
| `CMD` 能拿到容器环境变量，容器退出码等于 `CMD` 退出码 | `S6_CMD_ARG0=/command/with-contenv` |
| 初始化脚本没有超时限制 | `S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0` |
| `with-contenv`、`PUID`/`PGID`、`UMASK`（仅对服务生效）、`FILE__` 密钥 | `root/usr/bin/with-contenv`、`01-envfile`、`10-adduser` |
| 某个 `cont-init.d` 脚本失败后，后续脚本和服务仍继续 | s6-overlay 默认行为（`S6_BEHAVIOUR_IF_STAGE2_FAILS=0`） |
| `docker exec` 中可直接使用 s6 工具 | s6-overlay 的 symlinks 包（`/usr/bin`） |

`legacy-compat` 指 `root/etc/s6-overlay/scripts/legacy-compat`，通过 `S6_STAGE2_HOOK` 在 `fix-attrs.d`、`cont-init.d`、`services.d` 之前执行。

## 4. 已确定的设计决策

这些是有意为之的选择，不要当成缺陷调整。

### 4.1 镜像标签带 `-s6v3` 后缀

- v3 分支发布 `<完整版本>-s6v3`、`<次版本>-s6v3`、`latest-s6v3`，由 `Build Image.yml` 的 `TAG_SUFFIX` 控制。
- 不带后缀的标签属于 `main` 分支的 v2 镜像，v3 分支不得推送。
- 版本检查只与带同样后缀的已发布标签比较。
- 将来 v3 取代 v2 时，把 `TAG_SUFFIX` 改为空字符串。在此之前不要去掉后缀。

### 4.2 移除 Docker Mods

- `/docker-mods` 脚本已删除，`DOCKER_MODS` 环境变量会被忽略且不报错。
- 原因：项目所有者确认不需要；且现行 LinuxServer.io mod 依赖其 base 独有的 `init-*` s6-rc 服务，在本镜像上会让 `s6-rc-compile` 失败、容器无法完成启动。

### 4.3 启动时修改脚本权限

- `legacy-compat` 只对缺少可执行位的文件执行 `chmod a+x`，已可执行的文件不动。
- 这会在容器可写层产生少量改动，属于预期。

### 4.4 `S6_VERBOSITY=1`

- 启动日志不再逐个打印 `[cont-init.d] xx: executing...`，沿用 LinuxServer.io 的取值。
- 排查问题时在运行容器时加 `-e S6_VERBOSITY=2`。

### 4.5 `with-contenv` 包装脚本

- `/usr/bin/with-contenv` 是 bash 包装脚本，用 `pwdx` 判断当前是否为服务进程，只对服务应用 `UMASK`，然后转交 `/command/with-contenv`。这是 LinuxServer.io 的做法，`cont-init.d` 脚本和 `CMD` 不受 `UMASK` 影响与 v2 一致。
- `/bin/with-contenv` 是指向 `/command/with-contenv` 的链接，不经过包装脚本。v2 没有 `/bin/with-contenv`，没有下游依赖它。

### 4.6 s6-overlay 发布包的校验

- `install.sh` 下载发布包及同一 release 中的 `.sha256` 文件并校验，目的是发现下载损坏，不是验证来源真实性。

### 4.7 CPU 架构映射

`install.sh` 的映射已用各架构发布包的 ELF 头核对：

| Docker 平台 | s6-overlay 包 |
| --- | --- |
| `linux/amd64` | `x86_64` |
| `linux/arm64` | `aarch64` |
| `linux/arm/v7` | `arm` |
| `linux/arm/v6` | `armhf` |
| `linux/386` | `i686` |
| `linux/ppc64le` | `powerpc64le` |
| `linux/riscv64` | `riscv64` |
| `linux/s390x` | `s390x` |

`arm/v7` 使用 `arm` 而不是 `armhf` 是 s6-overlay 官方文档给出的对应关系，不是写错。

## 5. 边界：已评估、不是问题的现象

### 5.1 与 v2 不同但属于预期

| 现象 | 结论 |
| --- | --- |
| `s6-svstat` 输出为 `up (pid N pgid N) ...`，比 v2 多了 `pgid` | 新版 s6 的输出格式，base 无法也不应改回。解析该文本的脚本需要放宽匹配（已知：`docker-aria2` 的 `tests/root.sh` 有两处正则只匹配旧格式，属于下游测试脚本的问题，生产代码不受影响） |
| 停止容器时日志出现 `s6-rc: warning: service s6rc-oneshot-runner is marked as essential, not stopping it` | s6-overlay v3 正常的关闭日志 |
| `docker stop` 约需 3 秒 | TERM 与 KILL 之间的固定等待（`S6_KILL_GRACETIME` 默认 3000ms），v2 同样约 3 秒 |
| `PATH` 以 `/command` 开头；服务工作目录是 `/run/s6/legacy-services/<服务名>`；`cont-init.d` 脚本的工作目录不再是 `/` | v3 的内部结构。脚本不应依赖初始工作目录 |
| 进程树中多出 `s6-linux-init-shutdownd`、`s6rc-oneshot-runner`、`s6rc-fdholder` | v3 的内部服务 |
| v2 的 `/bin` 中有、v3 中没有的工具：`minidentd`、`s6-fillurandompool`、`s6-ftrigrd`、`s6-overlay-preinit`、`s6-rc-bundle`、`s6-tcpserver4*`、`s6-tcpserver6*`、`s6-test`、`s6lockd` | 上游在新版本中移除或改名，无法补回。已知下游均未使用 |
| 使用默认 `PUID`/`PGID` 启动时日志出现 `usermod: no changes` | v2 同样如此 |

### 5.2 明确不支持

| 项目 | 说明 |
| --- | --- |
| `/etc/fix-attrs.d` | s6-overlay v3 已弃用。上游 `fix-attrs` 脚本在递归规则遇到包含多个条目的目录时会报 `s6-chown: fatal` 并中止（截至 3.2.3.2 及上游 master 仍存在）。项目所有者决定不修补。下游应在 `cont-init.d` 脚本里用 `chown`/`chmod`。已知下游均未使用 |
| `s6-svscanctl -t /var/run/s6/services` 停止容器 | 上游说明 v3 下不可用，应改用 `/run/s6/basedir/bin/halt`。未实测，已知下游均未使用 |
| Docker Mods | 见 4.2 |
| 只读根文件系统（`--read-only`） | 未验证，不在支持范围。`10-adduser` 需要写 `/etc/passwd`，`legacy-compat` 需要修改 `/etc` 下的权限 |
| 以非 root 用户启动容器（`--user`） | 未验证，不在支持范围 |

### 5.3 下游需要注意的用法

- 下游若自行设置 `S6_CMD_ARG0`，会覆盖 base 的取值，`CMD` 将拿不到容器环境变量，需要自己在 `CMD` 前加 `with-contenv`。
- 下游若用 `apk add` 安装 Alpine 自带的 `s6`、`execline` 包，包内文件会替换 `/usr/bin` 下对应的符号链接；镜像自身的 init 使用 `/command` 下的版本，不受影响。

### 5.4 CI 相关

- 默认分支的 `publish-s6v3.yml` 每周一 02:17 UTC 检查 Alpine 和 s6-overlay v3 的稳定版本，也支持手动触发。复用的 `build-s6v3.yml` 从 `v3` 检出源码。上游有更新或镜像仓库缺少当前版本时才构建并发布。
- 版本检查从 Docker Hub 和 GHCR 已发布的镜像中读取 Alpine 与 s6-overlay 版本。发现更新时，构建使用检查阶段选定的版本。
- `version.txt` 当前没有被任何工作流引用。

## 6. 验证方式

| 测试 | 位置 | 覆盖内容 |
| --- | --- | --- |
| base 契约测试 | `.github/scripts/test-base-contract.sh` | 第 3 节的全部承诺，使用 v2 风格夹具镜像（脚本故意设为 `0644`） |
| 下游启动测试 | `.github/scripts/test-docker-aria2-s6v3-startup.sh` | `docker-aria2` master 的 a2b 变体在本 base 上启动、受监管、被杀后重启 |

两者都由 `Test Downstream.yml` 在 `v3` 分支的相关改动上运行。

2026-11-15 的人工验证结果：

- 契约测试在 `linux/arm64` 和 `linux/arm/v7` 上实际构建并通过。
- `docker-aria2` master 只替换 `FROM`：启动测试通过；其自带回归套件 standard 38/38 通过，a2b 39/40，唯一失败项是 5.1 中的 `s6-svstat` 正则，放宽后通过。
- `docker-qbittorrent`、`Docker-qBittorrent-Enhanced-Edition` 只替换 `FROM`：构建成功，WebUI 可访问，服务以 `abc` 身份受监管，停止退出码为 0。
- `amd64`、`386`、`ppc64le` 等架构只做了发布包 ELF 头的静态核对，没有实际运行。

## 7. 修改与审查约定

1. 只报告能够复现的问题：给出触发条件、实际输出，以及与 v2 镜像的对比。不报告推测性问题。
2. 第 4、5 节已列出的现象不再作为问题提出；除非某次改动让它产生了新的实际危害。
3. 发现新的 v2/v3 差异时，先判断是否有真实下游受影响，再决定在 base 兼容、要求下游修改，或记录为边界；结论补进本文档。
4. 新增兼容行为时，同时在 `test-base-contract.sh` 里加断言。
5. 升级 s6-overlay 版本后，重新跑契约测试和下游启动测试，并复查 5.1、5.2 中依赖上游行为的条目是否仍然成立。
