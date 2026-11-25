#!/usr/bin/env bash
# 函数级单元测试：输入校验、配置渲染、覆盖检测、备份轮转、SSH 初始化。
# 不触碰 /etc/fail2ban，可在任意 Linux 上运行。
#
#   F2B_SCRIPT=/path/to/fail2ban.sh bash test_units.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script=${F2B_SCRIPT:-$here/../fail2ban.sh}

TMP=$(mktemp -d)
funcs=$TMP/f2b-funcs.sh
trap 'rm -rf "$TMP"' EXIT

sed '$d' "$script" > "$funcs"   # 去掉最后的 main "$@"，只加载函数
# shellcheck disable=SC1090
source "$funcs"

CONFIG=$TMP/jail.local
JAIL_DIR=$TMP/jail.d
BACKUP_DIR=$TMP/backups
WORK=$TMP/work
mkdir -p "$JAIL_DIR" "$BACKUP_DIR" "$WORK"

PASS=0
FAIL=0
ck() { # ck <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n  expected: %q\n  actual  : %q\n' "$1" "$2" "$3"
    fi
}
ckcode() { # ckcode <desc> <expected-code> <actual-code>
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n  expected exit: %s  actual exit: %s\n' "$1" "$2" "$3"
    fi
}

# ---------- 1. 输入校验 ----------
for v in 600 30m 7d 1w 999999999 1s; do
    valid_time "$v"; ckcode "valid_time 接受 $v" 0 $?
done
for v in 0 0300 abc 30x "" 1234567890 1y; do
    valid_time "$v"; ckcode "valid_time 拒绝 '$v'" 1 $?
done

for v in 22 22,2222 1 65535 022; do
    valid_ports "$v"; ckcode "valid_ports 接受 $v" 0 $?
done
for v in 0 65536 22, 22,abc "" "22, 2222" -1; do
    valid_ports "$v"; ckcode "valid_ports 拒绝 '$v'" 1 $?
done

for v in 1.2.3.4 203.0.113.0/24 ::1 fe80::1/64; do
    valid_ignoreip_item "$v"; ckcode "valid_ignoreip_item 接受 $v" 0 $?
done
# 字符级校验，a-f 组成的字符串也会过；语义由 fail2ban 兜底
for v in "1.2.3.4/24 " 1.2.3.4/ 10.0.0.0/24, "1.2.3.4 5.6.7.8" abcdefg; do
    valid_ignoreip_item "$v"; ckcode "valid_ignoreip_item 拒绝 '$v'" 1 $?
done

valid_address_chars 1.2.3.4; ckcode "valid_address_chars 接受 IPv4" 0 $?
valid_address_chars 1.2.3.0/24; ckcode "valid_address_chars 拒绝 CIDR" 1 $?

# ---------- 2. current_ignoreip ----------
cat > "$TMP/cfgA" <<'EOF'
# 头部注释
[DEFAULT]
bantime = 360000
ignoreip = 127.0.0.1/8 ::1
backend = systemd

[sshd]
enabled = true
ignoreip = 203.0.113.7 198.51.100.0/24
           10.0.0.0/8
# 缩进注释
port = 22
EOF
CONFIG=$TMP/cfgA
ck "current_ignoreip sshd" "203.0.113.7 198.51.100.0/24 10.0.0.0/8" "$(current_ignoreip sshd)"
ck "current_ignoreip DEFAULT" "127.0.0.1/8 ::1" "$(current_ignoreip DEFAULT)"
ck "current_ignoreip 未知段" "" "$(current_ignoreip nope)"

printf '[sshd]\r\nenabled = true\r\nignoreip = 1.2.3.4 ; 内联注释\r\nport = 22\r\n' > "$TMP/cfgB"
CONFIG=$TMP/cfgB
ck "current_ignoreip CRLF+内联注释" "1.2.3.4 " "$(current_ignoreip sshd)"

printf '[sshd]\nbantime = 7d\n' > "$TMP/cfgC"
CONFIG=$TMP/cfgC
ck "current_ignoreip 无该项" "" "$(current_ignoreip sshd)"

CONFIG=$TMP/missing
ck "current_ignoreip 文件不存在" "" "$(current_ignoreip sshd)"

# ---------- 3. render_config ----------
CONFIG=$TMP/cfgA
printf 'bantime=30d\nport=22,2222\nignoreip=1.2.3.4\n' > "$WORK/changes"
render_config sshd "$WORK/changes" "$TMP/cfgA" "$TMP/out1"
ckcode "render_config 正常渲染" 0 $?
grep -q '^\[DEFAULT\]$' "$TMP/out1"; ckcode "render_config 保留 DEFAULT 段" 0 $?
grep -q '^ignoreip = 127.0.0.1/8 ::1$' "$TMP/out1"
ckcode "render_config 未改的选项原样保留" 0 $?
grep -q '^bantime = 30d$' "$TMP/out1"; ckcode "render_config 写入新 bantime" 0 $?
grep -q '^port = 22,2222$' "$TMP/out1"; ckcode "render_config 写入 port" 0 $?
grep -q '203.0.113.7' "$TMP/out1"
ckcode "render_config 删除被替换选项的续行" 1 $?
grep -q '^ignoreip = 1.2.3.4$' "$TMP/out1"; ckcode "render_config 写入新 ignoreip" 0 $?
ck "render_config 两个段各一条 ignoreip" "2" "$(grep -c '^ignoreip = ' "$TMP/out1")"

printf '[sshd]\n[sshd]\n' > "$TMP/dup"
printf 'port=22\n' > "$WORK/changes"
render_config sshd "$WORK/changes" "$TMP/dup" "$TMP/out2" 2>/dev/null
ckcode "render_config 拒绝重复段" 1 $?

: > "$WORK/empty"
printf 'port=22\n' > "$WORK/changes"
render_config sshd "$WORK/changes" "$WORK/empty" "$WORK/new"
format_config
ck "render_config 空文件新建段（格式化后）" "[sshd]
port = 22" "$(cat "$WORK/new")"

# ---------- 4. format_config ----------
printf '\n\n[A]\n\n\nkey = 1\n\n\n[B]\n\nkey = 2\n\n\n' > "$WORK/new"
format_config
ck "format_config 段落间保留一空行" "[A]
key = 1

[B]
key = 2" "$(cat "$WORK/new")"

# ---------- 5. check_overrides ----------
CONFIG=$TMP/jail.local
printf '[sshd]\nport = 22\n' > "$CONFIG"
printf 'bantime=30d\nport=22\n' > "$WORK/changes"
printf '[sshd]\nbantime = 1d\n' > "$JAIL_DIR/zz.local"
check_overrides sshd "$WORK/changes" 2>/dev/null
ckcode "check_overrides 检出后加载文件冲突" 1 $?

printf '[sshd]\nenabled = false\n' > "$JAIL_DIR/zz.local"
check_overrides sshd "$WORK/changes" 2>/dev/null
ckcode "check_overrides 无同名项时放行" 0 $?

printf '[foo]\nbantime = 1d\n' > "$JAIL_DIR/zz.local"
check_overrides sshd "$WORK/changes" 2>/dev/null
ckcode "check_overrides 其他 Jail 不算冲突" 0 $?
rm -f "$JAIL_DIR/zz.local"

# ---------- 6. prune_backups ----------
for i in $(seq 1 25); do
    printf 'x\n' > "$BACKUP_DIR/jail.local.bk$i"
    touch -t "2026010100$(printf '%02d' "$i")" "$BACKUP_DIR/jail.local.bk$i"
done
BACKUP=$BACKUP_DIR/jail.local.bk1   # 故意指向最旧的一份
touch "$BACKUP"
prune_backups
ck "prune_backups 保留 20 份" "20" "$(find "$BACKUP_DIR" -maxdepth 1 -name 'jail.local.*' | wc -l)"
[[ -f "$BACKUP" ]]; ckcode "prune_backups 不删除当前备份" 0 $?
rm -f "$BACKUP_DIR"/jail.local.*
BACKUP=""

# ---------- 7. render_ssh_config ----------
CONFIG=$TMP/fresh.local
: > "$CONFIG"
: > "$WORK/original"
printf 'enabled=true\nfilter=sshd\nbackend=systemd\nport=22\nbantime=30d\nfindtime=10m\nmaxretry=5\n' > "$WORK/changes"
render_ssh_config
ckcode "render_ssh_config 成功" 0 $?
grep -q '^# Fail2ban SSH 配置文件 (systemd backend)$' "$WORK/new"
ckcode "render_ssh_config 插入说明头" 0 $?
grep -q '^bantime = 360000$' "$WORK/new"
ckcode "render_ssh_config 写入 DEFAULT bantime" 0 $?
grep -q '^port = 22$' "$WORK/new"; ckcode "render_ssh_config 写入 sshd port" 0 $?
grep -q '^ignoreip = 127.0.0.1/8 ::1$' "$WORK/new"
ckcode "render_ssh_config 写入 ignoreip" 0 $?
render_ssh_config
ck "render_ssh_config 不重复插入头部" "1" \
    "$(grep -c '^# Fail2ban SSH 配置文件 (systemd backend)$' "$WORK/new")"

printf '\n测试完成：%s 通过，%s 失败\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
