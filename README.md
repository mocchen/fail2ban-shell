# fail2ban.sh — Fail2ban 交互式管理脚本

[![tests](https://github.com/mocchen/fail2ban-shell/actions/workflows/test.yml/badge.svg?branch=mochen)](https://github.com/mocchen/fail2ban-shell/actions/workflows/test.yml)

一个单文件的 Bash 菜单脚本，用于在一台 Linux 服务器上完成 Fail2ban 的**安装、SSH 防护初始化、参数调整、IP 白名单、手动封禁/解封、服务与日志查看**。

设计目标是「不手写配置文件也不把配置写坏」：所有写入都先备份、用 `fail2ban-client -t` 校验、失败自动回滚，并且只改动目标 Jail 段内的指定选项，其余内容原样保留。

- 脚本：[fail2ban.sh](fail2ban.sh)（版本 1.0）
- 无需 Python，只用 Bash + 常用 POSIX 工具
- 所有文案为中文；既可交互操作，也支持 `--check` / `--status` / `--dry-run` 等非交互用法

---

## 目录

- [功能特性](#功能特性)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [命令行选项](#命令行选项)
- [首次运行流程](#首次运行流程)
- [主菜单](#主菜单)
- [子菜单](#子菜单)
- [配置写入机制](#配置写入机制)
- [参数与输入格式](#参数与输入格式)
- [脚本涉及的文件](#脚本涉及的文件)
- [常见任务示例](#常见任务示例)
- [故障排查](#故障排查)
- [退出码与中断处理](#退出码与中断处理)
- [测试](#测试)
- [已知限制](#已知限制)

---

## 功能特性

| 能力 | 说明 |
| --- | --- |
| 环境自检 | 启动时检查 root、Bash 版本、systemd、包管理器、全部依赖命令，缺什么装什么 |
| 首次安装引导 | 检测到 Fail2ban 未安装时，安装完成后强制先完成 SSH 防护配置 |
| 非交互用法 | `--check` 校验、`--status [JAIL]` 输出状态、`--help` / `--version`，可直接用于巡检脚本 |
| 配置托管 | 只改 `jail.local` 中目标 `[Jail]` 段的指定选项，其他段、其他选项、注释、空行保持不变 |
| 安全回滚 | 写入前备份到 `manager-backups/`，校验或重载失败自动恢复原文件 |
| 写入确认 | 保存前展示将要写入的键值并请求确认，回答非 `y` 即放弃，配置文件完全不动 |
| 备份轮转 | `manager-backups/` 只保留最近 20 份，避免长期运行后无限增长 |
| 崩溃自愈 | 启动时清理上次被强制终止或断电后残留的临时目录 |
| 干跑模式 | `--dry-run` 只展示将要写入的键值，不落盘 |
| 冲突检测 | 若后加载的 `jail.d/*.local` 定义了同名选项，拒绝写入并给出提示，避免"改了却没生效" |
| 参数校验 | 时间、端口、次数、IP/CIDR 在写盘前校验格式与取值范围，杜绝配置语法被注入 |
| 原子替换 | 临时工作目录与 `jail.local` 同文件系统，用 `rename` 覆盖，不会写出半截文件 |
| 单实例 | 启动即取 `flock` 排他锁，依赖安装与配置写入都不会并发 |
| 服务管理 | 启动/停止、`-t` 校验 + reload、开机自启、systemd 与文件日志查看 |

---

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | 任意 Linux 发行版 |
| 初始化系统 | **systemd 正在运行**（`/run/systemd/system` 存在），否则直接退出 |
| 权限 | **root**（`sudo bash fail2ban.sh`）；只读菜单也要求 root |
| Shell | Bash **4.4 或更新**（检查 `BASH_VERSINFO`） |
| 包管理器 | `apt` / `dnf` / `yum` 三者之一 |
| 必备命令 | `fail2ban-client` `systemctl` `journalctl` `awk` `flock` `mktemp` `cp` `mv` `chmod` `chown` `cat` `rm` `mkdir` `tail` `cmp` `date` `find` `ls` |
| SSH 初始化依赖 | `python3-systemd`（systemd 日志后端）、`nftables` 或 `iptables`（封禁动作） |

必要的发行版软件包：`fail2ban`、`systemd`、`gawk`、`util-linux`、`coreutils`、`diffutils`、`python3-systemd`、`nftables`、`iptables`。

> Rocky / AlmaLinux / CentOS 上 Fail2ban 与其 `python3-systemd` 依赖通常由 EPEL 提供。脚本会先检查待安装的包在当前已启用仓库里是否可装，装不上才自动启用 `epel-release`。

---

## 快速开始

```bash
# 方式一：直接执行
sudo bash fail2ban.sh

# 方式二：先加执行权限
chmod +x fail2ban.sh
sudo ./fail2ban.sh
```

脚本内已声明 `#!/usr/bin/env bash`，因此两种方式等价。运行环境建议使用 `tmux`/`screen`，避免安装过程断线。

安装完成后启动服务并设置开机自启：

```bash
# 在菜单 5 中依次选择 1（启动）和 4（开机自启），或直接执行：
sudo fail2ban-client -t && sudo systemctl enable --now fail2ban
```

---

## 命令行选项

不带参数时进入交互菜单；带参数时执行对应动作后退出。

| 选项 | 作用 | 需要 root |
| --- | --- | --- |
| `-h`, `--help` | 打印用法后退出 | 否 |
| `-V`, `--version` | 打印版本后退出 | 否 |
| `--check` | 完整环境检查 + `fail2ban-client -t`，通过返回 0，否则返回 1 | 是 |
| `--status [JAIL]` | 输出 Jail 列表；指定 Jail 时再输出状态与 `bantime`/`findtime`/`maxretry`/`ignoreip` | 是 |
| `--dry-run` | 与菜单配合：只预览将要写入的内容，不修改 `jail.local` | 是 |

```bash
sudo ./fail2ban.sh --check              # 巡检：环境 + 配置
sudo ./fail2ban.sh --status             # 只看有哪些 Jail
sudo ./fail2ban.sh --status sshd        # 看 sshd 的封禁数与关键参数
sudo ./fail2ban.sh --dry-run            # 交互操作，但只看结果不落盘
```

`--dry-run` 只影响写入：预览结束后直接返回，不会备份、不会 reload；菜单和参数采集与正常运行时完全一致。

---

## 首次运行流程

1. 判断 Fail2ban 是否已安装（命令是否存在、`dpkg` / `rpm` 数据库是否记录）。
2. 未安装时提示：安装完成后会先配置 SSH 防护。
3. 校验 root、创建锁文件并获取**排他锁**（先拿锁再做安装，避免两个实例同时操作软件包数据库）。
4. 环境检测与自动安装：逐项检查依赖，列出将要安装的包并执行 `apt-get update && install` 或 `dnf/yum install`（含 EPEL 处理）。
5. 清理上次残留的临时目录、创建本次工作目录、注册 `EXIT/INT/TERM/HUP` 清理钩子。
6. 首次安装分支：依次询问 SSH 端口、封禁时间、统计窗口、失败次数，展示即将写入的 `[DEFAULT]` / `[sshd]` 内容并请求确认，然后写入 `jail.local`。
7. 保存后校验并（服务已运行时）reload，然后打印 `sshd` 状态。
8. 进入主菜单。

非首次运行则跳过第 6、7 步，直接进入主菜单。

---

## 主菜单

```text
========== Fail2ban 管理 ==========
1. 查看运行状态、封禁列表及参数
2. 查看配置文件及加载顺序
3. Jail 配置管理
4. 手动封禁 / 解封 IP
5. 服务管理及日志
0. 退出
```

| 选项 | 行为 |
| --- | --- |
| 1 | `fail2ban-client status` 列出所有 Jail，再询问 Jail 名称并显示其状态，最后逐个打印 `bantime` / `findtime` / `maxretry` / `ignoreip` |
| 2 | 打印配置文件实际加载顺序（见下），并输出 `jail.local` 全文；文件不存在时显示"尚未创建" |
| 3 | 进入 Jail 配置管理子菜单 |
| 4 | 进入 IP 封禁管理子菜单 |
| 5 | 进入服务与日志子菜单 |
| 0 | 退出脚本 |

**配置加载顺序（后面的覆盖前面的同名选项）：**

```text
/etc/fail2ban/jail.conf
/etc/fail2ban/jail.d/*.conf
/etc/fail2ban/jail.local      ← 本脚本写入的文件
/etc/fail2ban/jail.d/*.local
```

---

## 子菜单

### Jail 配置管理

| 选项 | 行为 |
| --- | --- |
| 1 | 修改该 Jail 的 `port` / `bantime` / `findtime` / `maxretry`（留空则不修改） |
| 2 | 设置该 Jail 的白名单（写 `ignoreip`，可选**追加**或**整体替换**，自动保留 `127.0.0.1/8 ::1`） |
| 3 | 启用 / 停用该 Jail（写 `enabled=true` / `false`） |
| 4 | 初始化 SSH 防护：配置 `[sshd]`，并**重设 `[DEFAULT]`** 的 `bantime=360000`、`findtime=600`、`maxretry=5`、`ignoreip=127.0.0.1/8 ::1`、`backend=systemd` |
| 0 | 返回主菜单 |

> 选项 4 会改写全局默认值，影响所有继承 `[DEFAULT]` 的 Jail（菜单里会二次提示）。只想改单个 Jail，请用选项 1。

### IP 封禁管理

| 选项 | 行为 |
| --- | --- |
| 1 | `fail2ban-client set <jail> banip <ip>` 手动封禁 |
| 2 | `fail2ban-client set <jail> unbanip <ip>` 解封 |
| 0 | 返回主菜单 |

手动封禁/解封是**运行时操作**，不写配置文件；服务重启或 `fail2ban-client reload` 后可能丢失。

### 服务管理及日志

| 选项 | 行为 |
| --- | --- |
| 1 | `fail2ban-client -t` 校验通过后 `systemctl start fail2ban` |
| 2 | `systemctl stop fail2ban`（通常会一并移除 Fail2ban 管理的封禁规则） |
| 3 | `fail2ban-client -t` 校验通过后 `fail2ban-client reload` |
| 4 | `systemctl enable fail2ban` 开机自启 |
| 5 | `systemctl disable fail2ban` 关闭自启 |
| 6 | `systemctl --no-pager --full status fail2ban` |
| 7 | `journalctl -u fail2ban -n 100 --no-pager` |
| 8 | `tail -n 100 /var/log/fail2ban.log`（文件不存在时提示检查 `logtarget`） |
| 0 | 返回主菜单 |

---

## 配置写入机制

脚本对 `jail.local` 的每次写入都走同一条流水线：

1. **入口检查**：`jail.local` 是符号链接或非普通文件时拒绝写入。
2. **冲突检测**：扫描 `jail.d/*.local`，若其中同一 `[Jail]` 段已显式定义本次要写的同名选项，报错并中止（因为该文件的加载顺序优先于 `jail.local`）。
3. **渲染新配置**：只替换目标段中的同名选项，删除被替换选项的旧续行，新值追加到该段末尾；其他内容原样保留。
4. **排版整理**：统一各段之间一个空行、去掉段名后与文件开头的空行；`[sshd]` 初始化时在文件顶部插入说明头（已存在则不重复插入）。
5. **无变化则跳过**：新内容与原内容 `cmp` 相同则直接返回，不写盘、不 reload。
6. **确认**：打印即将写入的 `[DEFAULT]` / `[Jail]` 键值，回答 `y`（默认）才继续；取消则原文件完全不动。带 `--dry-run` 时打印后直接返回，跳过后续所有步骤。
7. **备份**：把原文件复制到 `/etc/fail2ban/manager-backups/jail.local.XXXXXXXX`（保留原 mtime），并只保留最近 20 份；新文件用 `chmod/chown --reference` 继承原文件权限与属主，原文件不存在时新文件设为 `644`。
8. **原子替换**：`mv` 覆盖 `jail.local`。
9. **校验**：`fail2ban-client -t`；失败则自动恢复备份并报错。
10. **生效**：服务处于 active 时 `fail2ban-client reload`；reload 失败则恢复备份并再次 reload 旧配置。
11. **兜底**：脚本被 Ctrl-C / `kill` / 重载失败中断时，`EXIT` 钩子会发现"有未提交的写入"并自动恢复备份。

脚本还设置了 `umask 077`、`LC_ALL=C`（保证解析稳定），备份目录与临时目录按 700 创建；启动时会清理 24 小时以上、由强制终止或断电残留的 `.manager.*` 临时目录。

---

## 参数与输入格式

| 参数 | 允许值 | 说明 |
| --- | --- | --- |
| Jail 名称 | `^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$`，且不能是 `DEFAULT` | 默认 `sshd` |
| 时间（`bantime` / `findtime`） | `1`–`999999999`，可选后缀 `s` `m` `h` `d` `w` | `bantime` 额外允许 `-1`（永久封禁） |
| `maxretry` | `1`–`999999` 的整数 | |
| `port` | 逗号分隔，每项 `1`–`65535`，如 `22` 或 `22,2222` | 仅用于封禁规则，**不会**修改 SSH 监听端口 |
| `ignoreip` | 空格分隔的 IPv4/IPv6，可带 `/0`–`/999` 形式的 CIDR | 写入时始终前置 `127.0.0.1/8 ::1` |
| 封禁/解封 IP | 仅 `0-9 A-F a-f : .` 组成的地址 | 地址语义交由 Fail2ban 校验；不接受 CIDR |

时间单位换算参考：`30m`=30 分钟，`12h`=12 小时，`7d`=7 天，`1w`=1 周。默认 `bantime=360000` 秒为 100 小时。

---

## 脚本涉及的文件

| 路径 | 用途 |
| --- | --- |
| `/etc/fail2ban/jail.local` | 唯一被写入的配置文件 |
| `/etc/fail2ban/jail.d/` | 只读扫描，用于覆盖冲突检测，以及主菜单 2 的加载顺序展示 |
| `/etc/fail2ban/manager-backups/` | 每次实际写入前生成 `jail.local.XXXXXXXX` 备份，只保留最近 20 份 |
| `/etc/fail2ban/.manager.XXXXXXXX/` | 本次运行的临时工作目录（正常退出时删除；超过 24 小时的残留会在下次启动时清理） |
| `/run/lock/fail2ban-manager.lock` | `flock` 单实例锁 |
| `/run/lock/` | 缺失时自动创建 |
| `/var/log/fail2ban.log` | 子菜单 8 读取的日志文件（取决于 `logtarget`） |

`jail.local` 由脚本生成时，顶部会带有说明头（含生成时间），示例如下：

```ini
# =========================================
# Fail2ban SSH 配置文件 (systemd backend)
# 生成时间: ...
# 注释：
# bantime  : 封禁时间(秒)
# ...
# =========================================

[DEFAULT]
bantime = 360000
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
backend = systemd

[sshd]
enabled = true
filter = sshd
backend = systemd
port = 22
bantime = 360000
findtime = 600
maxretry = 5
```

---

## 常见任务示例

**把 SSH 封禁时间改为 7 天**

菜单 `3` → `1` → Jail 名称填 `sshd` → 封禁时间填 `7d` → 其余留空 → 脚本打印预览、备份并 reload。

**加白名单（办公室出口 IP）**

菜单 `3` → `2` → 选择 `1 追加` → 输入 `203.0.113.7 198.51.100.0/24`，最终写入：

```ini
ignoreip = 127.0.0.1/8 ::1 203.0.113.7 198.51.100.0/24
```

- 选 `1` 追加：保留 `jail.local` 中该 Jail 现有的 `ignoreip`，只追加并去重。
- 选 `2` 替换：整体重写，之前手工加过的地址需要一并输入。
- 无论哪种模式，`127.0.0.1/8 ::1` 始终保留。

**临时解封一个被误封的 IP**

菜单 `4` → `2` → Jail 填 `sshd` → 输入要解封的 IP。

**查看为什么某条规则没生效**

菜单 `2` 确认 `jail.local` 内容与加载顺序，再检查列表末尾的 `jail.d/*.local` 是否覆盖了同名选项。

**回到上一次的配置**

```bash
ls -lt /etc/fail2ban/manager-backups/
sudo cp /etc/fail2ban/manager-backups/jail.local.XXXXXXXX /etc/fail2ban/jail.local
sudo fail2ban-client -t && sudo fail2ban-client reload
```

---

## 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| `自动安装需要 root 权限` | 用 `sudo bash fail2ban.sh` |
| `当前脚本需要 Bash 4.4 或更新版本` | 升级 Bash，或改用 `bash` 4.4+ 的发行版 |
| `当前环境未运行 systemd` | 容器/精简系统缺少 systemd，脚本的服务管理功能不可用 |
| `另一个管理脚本正在运行` | 已有实例持锁。`flock` 随进程退出自动释放，锁文件残留不影响；确认无进程后可忽略或删除锁文件 |
| `覆盖冲突：... [sshd]` | 后加载的 `jail.d/*.local` 定义了同名选项，会盖掉本次写入。删除该文件中的重复项，或直接修改那个文件 |
| `配置检查失败，本次修改未生效` | 自动已回滚，按提示查看备份路径与 `fail2ban-client -t` 输出 |
| `已取消，未修改任何配置` | 在写入确认处回答了非 `y`，配置未动，重新操作即可 |
| `本次加载失败...` | reload 失败但旧配置已恢复；查看子菜单 7/8 的日志，必要时 `systemctl restart fail2ban` |
| `[失败] Fail2ban 客户端无法正常执行` | Fail2ban 装坏了或缺 Python 依赖，重装 `fail2ban` |
| 启动后 SSH 没被拦 | 确认 `sshd` jail 已启用、`backend=systemd` 且 `python3-systemd` 已安装、`port` 与实际监听端口一致 |
| `默认日志文件不存在` | 当前 `logtarget` 未指向 `/var/log/fail2ban.log`，改用子菜单 7（journalctl） |

---

## 退出码与中断处理

| 退出码 | 含义 |
| --- | --- |
| `0` | 正常退出；`--help` / `--version` / `--check` / `--status` 成功 |
| `1` | 环境检测失败、权限不足、未知参数、配置写入/校验/重载失败、`--check` 未通过等 |
| `130` / `143` / `129` | 收到 `SIGINT` / `SIGTERM` / `SIGHUP`，先执行清理与配置回滚再退出 |

脚本使用 `set -uo pipefail`（**故意不启用 `-e`**），因此菜单里单条命令失败不会导致整个脚本终止，而是由各函数显式判断返回值。

---

## 测试

`tests/` 下两套测试都只操作临时目录、用桩命令替代 `fail2ban-client` / `systemctl`，不会碰真实的 `/etc/fail2ban`；GitHub Actions 在每次 push / PR 时自动运行（见 `.github/workflows/test.yml`）。

| 文件 | 覆盖范围 |
| --- | --- |
| `tests/test_units.sh` | 输入校验、`current_ignoreip`、`render_config`、`format_config`、`check_overrides`、`prune_backups`、`render_ssh_config` |
| `tests/test_units2.sh` | `menu`、`merge_ignoreip`、`--dry-run`、`save_config` 的写入 / 取消 / 回滚、新文件权限 |

```bash
cd fail2ban
bash tests/test_units.sh
sudo bash tests/test_units2.sh   # 需要 root：验证 chmod/chown 权限继承
```

两套测试都按「断言计数」输出，最后一行形如 `测试完成：64 通过，0 失败`，退出码 0 表示全过。脚本路径可用 `F2B_SCRIPT=/path/to/fail2ban.sh` 覆盖。

真机冒烟（写入 → reload → 还原）不在仓库里：它会改 `/etc/fail2ban/jail.local`、依赖具体环境，跑错地方代价太大。需要时在一台一次性测试机上走一遍「菜单 3 → 1」，确认预览、备份、`-t` 校验与生效；想先看结果不落盘，加 `--dry-run`。

---

## 已知限制

- **非交互能力有限**：`--check` / `--status` 只读，改配置仍需交互（可配合 `--dry-run` 预览）；批量场景请直接调用 `fail2ban-client`。
- **只认 `jail.local`**：不写 `jail.d/*.conf`，也不合并 `jail.conf` 的内容；`jail.d/*.local` 只做冲突检测。
- **白名单追加只读 `jail.local`**：现有 `ignoreip` 取自本文件对应段；若该值来自 `jail.conf` 或 `jail.d/*.local`，追加模式看不到它（替换模式不受影响）。
- **需要 systemd**：非 systemd 环境（OpenRC、容器、WSL 等）无法使用。
- **仅支持 apt/dnf/yum**：其他包管理器需自行满足依赖。
- **手动封禁不持久**：`banip`/`unbanip` 只作用于运行时。
- 修改选项后该选项会被移动到所在段末尾（不影响语义，但会产生一次"顺序变化"的 diff）。
