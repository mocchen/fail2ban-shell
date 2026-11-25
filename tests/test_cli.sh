#!/usr/bin/env bash
# 进程级测试：CLI 参数、--dry-run、真实写入与还原。
#
# 注意：会临时修改 /etc/fail2ban/jail.local 并 reload fail2ban。
# 只应在一台可随意折腾的测试机上运行，跑完会自动还原（以开头的快照为准）。
#
#   F2B_SCRIPT=/path/to/fail2ban.sh bash test_cli.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script=${F2B_SCRIPT:-$here/../fail2ban.sh}
cd "$here" || exit 1

PASS=0
FAIL=0
ck() {
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n  expected: %q\n  actual  : %q\n' "$1" "$2" "$3"
    fi
}
ckcode() {
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n  expected exit: %s  actual exit: %s\n' "$1" "$2" "$3"
    fi
}
has() { # has <desc> <file> <pattern>
    if grep -q -- "$3" "$2"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s（未找到 %q）\n' "$1" "$3"
    fi
}

JAILLOCAL=/etc/fail2ban/jail.local
cp -p "$JAILLOCAL" "$here/snap.local"

# ---------- 1. CLI ----------
bash "$script" --help > out_help.txt 2>&1
ckcode "--help 退出码" 0 $?
has "--help 用法" out_help.txt '用法：fail2ban.sh'
has "--help 列出 dry-run" out_help.txt 'dry-run'

bash "$script" --version > out_ver.txt 2>&1
ckcode "--version 退出码" 0 $?
ck "--version 内容" "fail2ban.sh 1.0" "$(cat out_ver.txt)"

bash "$script" --bogus > out_bad.txt 2>&1
ckcode "未知参数退出码" 1 $?
has "未知参数提示" out_bad.txt '未知参数：--bogus'

bash "$script" --check > out_check.txt 2>&1
ckcode "--check 退出码" 0 $?
has "--check 结论" out_check.txt '配置检查通过'

bash "$script" --status > out_status.txt 2>&1
ckcode "--status 退出码" 0 $?
has "--status 列出 Jail" out_status.txt 'sshd'

bash "$script" --status sshd > out_status2.txt 2>&1
ckcode "--status sshd 退出码" 0 $?
has "--status sshd 输出 bantime" out_status2.txt 'bantime'
has "--status sshd 输出 maxretry" out_status2.txt 'maxretry'

# ---------- 2. --dry-run 不落盘 ----------
# 菜单 3 → 1 → sshd → 端口 22 → bantime 7d → 其余留空
printf '3\n1\nsshd\n22\n7d\n\n\n0\n0\n' | bash "$script" --dry-run > out_dry.txt 2>&1
ckcode "dry-run 交互退出码" 0 $?
has "dry-run 提示" out_dry.txt '--dry-run：以上内容未写入'
cmp -s "$JAILLOCAL" snap.local; ckcode "dry-run 未修改 jail.local" 0 $?

# ---------- 3. 真实写入 ----------
printf '3\n1\nsshd\n22\n7d\n\n\ny\n0\n0\n' | bash "$script" > out_write.txt 2>&1
ckcode "交互写入退出码" 0 $?
has "写入 bantime 7d" "$JAILLOCAL" '^bantime = 7d$'
has "保留 port" "$JAILLOCAL" '^port = 22$'
ck "生效的 bantime" "604800" "$(fail2ban-client get sshd bantime 2>/dev/null)"
has "写入后配置检查通过" out_write.txt '配置已保存并加载'
has "生成备份" out_write.txt '备份：'

# 还原
cp -p snap.local "$JAILLOCAL"
fail2ban-client reload > /dev/null 2>&1
ck "还原后 bantime" "2592000" "$(fail2ban-client get sshd bantime 2>/dev/null)"

# ---------- 4. 菜单渲染 ----------
ck "主菜单项数" "6" \
    "$(awk '/^========== Fail2ban 管理 ==========$/{on=1} on && /^[0-9]\./{n++} on && /^0\. 退出$/{print n; exit}' out_dry.txt)"
ck "Jail 菜单项数" "5" \
    "$(awk '/^========== Jail 配置管理 ==========$/{on=1} on && /^[0-9]\./{n++} on && /^0\. 返回主菜单$/{print n; exit}' out_dry.txt)"

rm -rf /etc/fail2ban/manager-backups snap.local
printf '\n测试完成：%s 通过，%s 失败\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
