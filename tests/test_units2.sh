#!/usr/bin/env bash
# 函数级单元测试：菜单、白名单合并、dry-run、save_config 写入/取消/回滚。
# 通过临时目录 + 桩命令模拟 fail2ban-client / systemctl，不触碰真实配置。
#
#   F2B_SCRIPT=/path/to/fail2ban.sh bash test_units2.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script=${F2B_SCRIPT:-$here/../fail2ban.sh}

TMP=$(mktemp -d)
funcs=$TMP/f2b-funcs.sh
trap 'rm -rf "$TMP"' EXIT

sed '$d' "$script" > "$funcs"
# shellcheck disable=SC1090
source "$funcs"

CONFIG=$TMP/jail.local
JAIL_DIR=$TMP/jail.d
BACKUP_DIR=$TMP/backups
WORK=$TMP/work
mkdir -p "$JAIL_DIR" "$BACKUP_DIR" "$WORK"

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

# ---------- 1. merge_ignoreip ----------
ck "merge 追加去重" "127.0.0.1/8 ::1 203.0.113.7 198.51.100.0/24" \
    "$(merge_ignoreip 1 "127.0.0.1/8 ::1 203.0.113.7" 203.0.113.7 198.51.100.0/24)"
ck "merge 追加保留旧值" "127.0.0.1/8 ::1 10.0.0.1 10.0.0.2" \
    "$(merge_ignoreip 1 "10.0.0.1 10.0.0.2" "")"
ck "merge 替换丢弃旧值" "127.0.0.1/8 ::1 5.6.7.8" \
    "$(merge_ignoreip 2 "1.2.3.4" 5.6.7.8)"
ck "merge 替换空输入只留本机" "127.0.0.1/8 ::1" \
    "$(merge_ignoreip 2 "1.2.3.4")"
ck "merge 本机地址不重复" "127.0.0.1/8 ::1" \
    "$(merge_ignoreip 1 "127.0.0.1/8 ::1")"

# ---------- 2. menu ----------
menu "T" "1|one" "2|two" "0|back" > "$TMP/menu.out" <<< $'9\n2'
ckcode "menu 正常返回" 0 $?
ck "menu SELECTED" "2" "$SELECTED"
ck "menu 无效输入后重绘菜单" "2" \
    "$(grep -c '^========== T ==========$' "$TMP/menu.out")"
grep -q '^1\. one$' "$TMP/menu.out"; ckcode "menu 条目格式" 0 $?
grep -q '无效选项' "$TMP/menu.out"; ckcode "menu 提示无效选项" 0 $?

menu "T" "1|one" > /dev/null < /dev/null
ckcode "menu EOF 返回 1" 1 $?

# ---------- 3. save_config：dry-run ----------
printf '[sshd]\nport = 22\n' > "$CONFIG"
cp "$CONFIG" "$TMP/before"
WORK=$TMP/work1
mkdir -p "$WORK"
printf 'bantime=7d\n' > "$WORK/changes"
JAIL=sshd
DRY_RUN=1
save_config > "$TMP/dry.out" 2>&1
ckcode "dry-run 返回 0" 0 $?
grep -q -- '--dry-run：以上内容未写入' "$TMP/dry.out"
ckcode "dry-run 提示未写入" 0 $?
cmp -s "$CONFIG" "$TMP/before"; ckcode "dry-run 配置未变" 0 $?
ck "dry-run 不产生备份" "0" "$(find "$BACKUP_DIR" -type f | wc -l)"
DRY_RUN=0

# ---------- 4. save_config：真正写入 ----------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/fail2ban-client" <<'STUB'
#!/usr/bin/env bash
if [[ "${1-}" == "-t" ]]; then
    exit "${F2B_TEST_T_FAIL:-0}"
fi
exit 0
STUB
cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$TMP/bin/fail2ban-client" "$TMP/bin/systemctl"
PATH="$TMP/bin:$PATH"

chmod 640 "$CONFIG"
WORK=$TMP/work2
mkdir -p "$WORK"
printf 'bantime=7d\n' > "$WORK/changes"
save_config <<< "y" > "$TMP/write.out" 2>&1
ckcode "save_config 写入成功" 0 $?
grep -q '^bantime = 7d$' "$CONFIG"; ckcode "写入 bantime" 0 $?
grep -q '^port = 22$' "$CONFIG"; ckcode "保留原有选项" 0 $?
ck "保留原文件权限 640" "640" "$(stat -c %a "$CONFIG")"
ck "生成一份备份" "1" "$(find "$BACKUP_DIR" -type f | wc -l)"
grep -q '^备份：' "$TMP/write.out"; ckcode "输出备份路径" 0 $?

# 取消写入
WORK=$TMP/work3
mkdir -p "$WORK"
printf 'bantime=9d\n' > "$WORK/changes"
cp "$CONFIG" "$TMP/before2"
save_config <<< "n" > "$TMP/cancel.out" 2>&1
ckcode "取消写入返回 1" 1 $?
cmp -s "$CONFIG" "$TMP/before2"; ckcode "取消后配置未变" 0 $?

# ---------- 5. save_config：校验失败自动回滚 ----------
WORK=$TMP/work4
mkdir -p "$WORK"
printf 'bantime=11d\n' > "$WORK/changes"
cp "$CONFIG" "$TMP/before3"
F2B_TEST_T_FAIL=1 save_config <<< "y" > "$TMP/rollback.out" 2>&1
ckcode "校验失败返回 1" 1 $?
cmp -s "$CONFIG" "$TMP/before3"; ckcode "校验失败已回滚" 0 $?
grep -q '已恢复原配置' "$TMP/rollback.out"; ckcode "提示已恢复" 0 $?

# ---------- 6. 首次写入（文件不存在）----------
CONFIG=$TMP/newdir/jail.local
mkdir -p "$TMP/newdir"
WORK=$TMP/work5
mkdir -p "$WORK"
printf 'enabled=true\nport=22\n' > "$WORK/changes"
save_config <<< "y" > "$TMP/first.out" 2>&1
ckcode "文件不存在时创建成功" 0 $?
[[ -f "$CONFIG" ]]; ckcode "jail.local 已创建" 0 $?
ck "新建文件权限 644" "644" "$(stat -c %a "$CONFIG")"

printf '\n测试完成：%s 通过，%s 失败\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
