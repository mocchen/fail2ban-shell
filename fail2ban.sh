#!/usr/bin/env bash
# Bash 4+；不调用 Python。
set -uo pipefail
export LC_ALL=C
umask 077

CONFIG=/etc/fail2ban/jail.local
JAIL_DIR=/etc/fail2ban/jail.d
BACKUP_DIR=/etc/fail2ban/manager-backups

VERSION="1.0"

WORK=""
BACKUP=""
PENDING=0
EXISTED=0
DRY_RUN=0
REPLY=""
JAIL=""
SELECTED=""
PARAM_PORT=""
PARAM_BAN=""
PARAM_FIND=""
PARAM_RETRY=""

error() {
    printf '错误：%s\n' "$*" >&2
    return 1
}

usage() {
    cat <<'EOF'
用法：fail2ban.sh [选项]

交互式管理 Fail2ban：环境自检、SSH 初始化、Jail 参数、
白名单、手动封禁、服务与日志。

选项：
  -h, --help          显示本帮助后退出
  -V, --version       显示版本后退出
      --check         只做环境检查与配置校验，不进入菜单
      --status [JAIL] 输出状态（可指定 Jail），不进入菜单
      --dry-run       配合菜单使用：只预览将要写入的内容

不带选项时进入交互菜单。
EOF
}

ask() {
    local prompt="$1" default="${2-}"
    if [[ -n "$default" ]]; then
        printf '%s [%s]：' "$prompt" "$default"
    else
        printf '%s：' "$prompt"
    fi
    IFS= read -r REPLY || return 1
    # 非交互输入（管道/重定向）时终端不回显换行，这里补一个，方便阅读日志。
    [[ -t 0 ]] || printf '\n'
    REPLY="${REPLY:-$default}"
}

is_active() {
    systemctl is-active --quiet fail2ban
}

# 通用菜单：$1 为标题，其余为 "键|说明"。
# 选中后把键写入 SELECTED；读取失败（EOF）返回 1。
menu() {
    local title="$1" line i
    local -a keys=()
    local -a texts=()

    shift
    for line in "$@"; do
        keys+=("${line%%|*}")
        texts+=("${line#*|}")
    done

    while true; do
        printf '\n========== %s ==========\n' "$title"
        for (( i = 0; i < ${#keys[@]}; i++ )); do
            printf '%s. %s\n' "${keys[i]}" "${texts[i]}"
        done

        ask "请选择" || return 1

        for (( i = 0; i < ${#keys[@]}; i++ )); do
            if [[ "$REPLY" == "${keys[i]}" ]]; then
                SELECTED="$REPLY"
                return 0
            fi
        done

        printf '无效选项。\n'
    done
}

choose_jail() {
    ask "Jail 名称" "sshd" || return 1
    [[ "$REPLY" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] ||
        { error "Jail 名称格式不正确。"; return 1; }
    [[ "$REPLY" != DEFAULT ]] ||
        { error "请填写具体 Jail 名称。"; return 1; }
    JAIL="$REPLY"
}

valid_time() {
    [[ "$1" =~ ^[1-9][0-9]{0,8}[smhdw]?$ ]]
}

valid_ports() {
    local value="$1" port
    local -a items
    [[ "$value" =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || return 1
    IFS=, read -r -a items <<< "$value"
    for port in "${items[@]}"; do
        (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
    done
}

# 防止地址输入变成配置语法；地址语义由 Fail2ban 校验。
valid_address_chars() {
    [[ "$1" =~ ^[0-9A-Fa-f:.]+$ ]]
}

# 白名单条目：IPv4/IPv6，可带 CIDR 前缀。
valid_ignoreip_item() {
    [[ "$1" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]
}

restore_config() {
    (( PENDING == 1 )) || return 0

    if (( EXISTED == 1 )); then
        cp -p -- "$BACKUP" "$WORK/restore" &&
            mv -f -- "$WORK/restore" "$CONFIG" || {
                error "自动恢复失败，备份位于：$BACKUP"
                return 1
            }
    else
        rm -f -- "$CONFIG" || return 1
    fi

    PENDING=0
    printf '已恢复原配置。\n'
}

cleanup() {
    local rc=$?
    trap - EXIT
    if (( PENDING == 1 )); then
        if restore_config; then
            if is_active; then
                fail2ban-client reload ||
                    printf '旧配置加载失败，请检查服务日志。\n' >&2
            fi
        fi
    fi
    [[ -z "$WORK" ]] || rm -rf -- "$WORK"
    exit "$rc"
}

# 查找后加载的 .local 文件中，同一 Jail 的同名显式配置项。
# changes 文件格式：key=value
check_overrides() {
    local target="${1:-$JAIL}"
    local changes="${2:-$WORK/changes}"
    local file result
    local -a files=("$JAIL_DIR"/*.local)

    for file in "${files[@]}"; do
        [[ -f "$file" ]] || continue
        result=$(
            awk -v target="$target" '
                FILENAME == ARGV[1] {
                    p = index($0, "=")
                    wanted[substr($0, 1, p - 1)] = 1
                    next
                }
                {
                    line = $0
                    sub(/\r$/, "", line)

                    if (line ~ /^[ \t]*\[/) {
                        section = line
                        sub(/^[ \t]*\[/, "", section)
                        sub(/\].*$/, "", section)
                        next
                    }

                    if (section != target ||
                        line ~ /^[ \t]*([#;]|$)/)
                        next

                    if (match(line, /^[ \t]*[A-Za-z0-9_.-]+[ \t]*[:=]/)) {
                        key = substr(line, 1, RLENGTH)
                        gsub(/^[ \t]+|[ \t]*[:=]$/, "", key)
                        key = tolower(key)
                        if (key in wanted)
                            print key
                    }
                }
            ' "$changes" "$file"
        ) || return 1

        if [[ -n "$result" ]]; then
            printf '覆盖冲突：%s [%s]\n%s\n' \
                "$file" "$target" "$result" >&2
            error "该文件在 jail.local 之后加载，会覆盖本次修改；请删除其中的重复项，或直接修改该文件。"
            return 1
        fi
    done
}

# 仅替换指定段中的指定选项，保留其他段及未修改的选项。
# 被替换选项的旧续行也会一起移除。
render_config() {
    local target="${1:-$JAIL}"
    local changes="${2:-$WORK/changes}"
    local original="${3:-$WORK/original}"
    local output="${4:-$WORK/new}"
    awk -v target="$target" '
        FILENAME == ARGV[1] {
            p = index($0, "=")
            key = substr($0, 1, p - 1)
            values[key] = substr($0, p + 1)
            order[++count] = key
            next
        }

        function emit( i, key) {
            for (i = 1; i <= count; i++) {
                key = order[i]
                print key " = " values[key]
            }
        }

        {
            line = $0
            sub(/\r$/, "", line)

            if (line ~ /^[ \t]*\[/) {
                if (inside)
                    emit()

                section = line
                sub(/^[ \t]*\[/, "", section)
                sub(/\].*$/, "", section)

                inside = (section == target)
                dropping = 0
                if (inside)
                    seen++

                print line
                next
            }

            if (!inside) {
                print line
                next
            }

            if (line ~ /^[ \t]*([#;]|$)/) {
                print line
                next
            }

            match(line, /^[ \t]*/)
            indent = RLENGTH

            if (dropping && indent > previous_indent)
                next

            dropping = 0

            if (match(line, /^[ \t]*[A-Za-z0-9_.-]+[ \t]*[:=]/)) {
                key = substr(line, 1, RLENGTH)
                gsub(/^[ \t]+|[ \t]*[:=]$/, "", key)
                key = tolower(key)

                if (key in values) {
                    dropping = 1
                    previous_indent = indent
                    next
                }
            }

            print line
        }

        END {
            if (seen > 1) {
                print "发现重复的目标 Jail 段，请先手动整理。" > "/dev/stderr"
                exit 1
            }
            if (inside)
                emit()
            if (!seen) {
                print ""
                print "[" target "]"
                emit()
            }
        }
    ' "$changes" "$original" > "$output"
}

render_ssh_config() {
    cat > "$WORK/defaults" <<'EOF'
bantime=360000
findtime=600
maxretry=5
ignoreip=127.0.0.1/8 ::1
backend=systemd
EOF

    # 检查后加载的 .local 文件是否覆盖这些全局默认值。
    check_overrides DEFAULT "$WORK/defaults" || return 1

    # 先写入固定的全局默认值，保留其他配置项。
    render_config \
        DEFAULT \
        "$WORK/defaults" \
        "$WORK/original" \
        "$WORK/with-defaults" || return 1

    # 再写入用户自定义的 sshd 参数。
    render_config \
        "$JAIL" \
        "$WORK/changes" \
        "$WORK/with-defaults" \
        "$WORK/new" || return 1

    # 已有说明头时不重复添加。
    if awk '
        /^# Fail2ban SSH 配置文件 \(systemd backend\)[[:space:]]*$/ {
            found = 1
        }
        END {
            exit !found
        }
    ' "$WORK/new"; then
        return 0
    fi

    {
        cat <<EOF
# =========================================
# Fail2ban SSH 配置文件 (systemd backend)
# 生成时间: $(date '+%F %T %Z')
# 注释：
# bantime  : 封禁时间(秒)
# findtime : 失败次数统计时间窗口(秒)
# maxretry : 最大失败次数
# ignoreip : 忽略的 IP 列表
# backend  : 使用 systemd 日志
# sshd     : SSH 服务监控
# =========================================
EOF
        cat -- "$WORK/new"
    } > "$WORK/with-header" || return 1

    mv -f -- "$WORK/with-header" "$WORK/new"
}

format_config() {
    local input="$WORK/new"
    local output="$WORK/formatted"

    awk '
        function flush_blanks() {
            while (blanks > 0) {
                print ""
                blanks--
            }
        }

        {
            line = $0
            sub(/\r$/, "", line)

            # 段落之间统一保留一个空行。
            if (line ~ /^[ \t]*\[/) {
                blanks = 0
                if (printed)
                    print ""

                print line
                printed = 1
                after_header = 1
                next
            }

            # 暂存空行，等下一行确定是否需要保留。
            if (line ~ /^[ \t]*$/) {
                blanks++
                next
            }

            # 删除文件开头及段名后面的空行。
            # 段内其他位置的空行保持原样。
            if (printed && !after_header)
                flush_blanks()

            blanks = 0
            print line
            printed = 1
            after_header = 0
        }
    ' "$input" > "$output" || return 1

    mv -f -- "$output" "$input"
}

# 备份目录只保留最近的若干份，避免长期运行后无限增长。
prune_backups() {
    local keep=20 file
    local -a files

    files=("$BACKUP_DIR"/jail.local.*)
    (( ${#files[@]} > keep )) || return 0

    # 按修改时间排序，跳过最新的 keep 份。
    # 本次刚生成的备份永不删除，供校验失败时回滚使用。
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        [[ "$file" == "$BACKUP" ]] && continue
        rm -f -- "$file"
    done < <(ls -1t -- "${files[@]}" 2>/dev/null | tail -n "+$((keep + 1))")
}

save_config() {
    [[ -s "$WORK/changes" ]] || {
        printf '没有需要修改的参数。\n'
        return 0
    }

    [[ ! -L "$CONFIG" ]] ||
        { error "$CONFIG 是符号链接，请先手动检查。"; return 1; }
    if [[ -e "$CONFIG" && ! -f "$CONFIG" ]]; then
        error "$CONFIG 不是普通文件。"
        return 1
    fi

    check_overrides || return 1

    EXISTED=0
    if [[ -f "$CONFIG" ]]; then
        EXISTED=1
        cp -p -- "$CONFIG" "$WORK/original" || return 1
    else
        : > "$WORK/original" || return 1
    fi

    if [[ "${1-}" == ssh-defaults ]]; then
        render_ssh_config || return 1
    else
        render_config || return 1
    fi

    # 保存前统一整理段落空行。
    format_config || return 1

    if cmp -s "$WORK/original" "$WORK/new"; then
        printf '配置没有变化。\n'
        return 0
    fi

    if [[ "${1-}" == ssh-defaults ]]; then
        printf '\n将写入 %s 的 [DEFAULT]：\n' "$CONFIG"
        cat -- "$WORK/defaults"
    fi

    printf '\n将写入 %s 的 [%s]：\n' "$CONFIG" "$JAIL"
    cat -- "$WORK/changes"

    if (( DRY_RUN == 1 )); then
        printf '\n--dry-run：以上内容未写入，%s 保持不变。\n' "$CONFIG"
        return 0
    fi

    ask "确认写入并使其生效" "y" || return 1
    case "$REPLY" in
        [yY]*) : ;;
        *)
            printf '已取消，未修改任何配置。\n'
            return 1
            ;;
    esac

    BACKUP=""
    if (( EXISTED == 1 )); then
        mkdir -p -- "$BACKUP_DIR" || return 1
        BACKUP=$(mktemp "$BACKUP_DIR/jail.local.XXXXXXXX") || return 1
        cp -p -- "$CONFIG" "$BACKUP" || return 1
        chmod --reference="$CONFIG" "$WORK/new" || return 1
        chown --reference="$CONFIG" "$WORK/new" || return 1
        printf '备份：%s\n' "$BACKUP"
        prune_backups
    else
        chmod 644 "$WORK/new" || return 1
    fi

    # WORK 与 CONFIG 位于同一文件系统，使用 rename 替换。
    PENDING=1
    if ! mv -f -- "$WORK/new" "$CONFIG"; then
        restore_config || exit 1
        return 1
    fi

    printf '\n检查配置……\n'
    if ! fail2ban-client -t; then
        restore_config || exit 1
        error "配置检查失败，本次修改未生效。"
        return 1
    fi

    if is_active; then
        printf '加载配置……\n'
        if ! fail2ban-client reload; then
            restore_config || exit 1
            fail2ban-client reload ||
                printf '旧配置加载也失败，请检查日志。\n' >&2
            error "本次加载失败，请检查运行状态；加载过程可能部分执行。"
            return 1
        fi
        PENDING=0
        printf '配置已保存并加载。\n'
    else
        PENDING=0
        printf '配置已保存；服务未运行，可从服务菜单启动。\n'
    fi
}

# 输出单个 Jail 的状态与关键参数；
# 旧版本不支持 get ignoreip 时只跳过该项，不影响其他输出。
show_jail_status() {
    local jail="$1" key

    fail2ban-client status "$jail" || return 1

    for key in bantime findtime maxretry ignoreip; do
        printf '\n%s：\n' "$key"
        fail2ban-client get "$jail" "$key" 2>/dev/null ||
            printf '（当前 Fail2ban 版本无法读取该项）\n'
    done
}

show_status() {
    fail2ban-client status || return 1
    choose_jail || return 1
    show_jail_status "$JAIL"
}

show_config() {
    local file
    printf '\n配置加载顺序，后加载的同名配置项优先：\n'
    for file in \
        /etc/fail2ban/jail.conf \
        "$JAIL_DIR"/*.conf \
        "$CONFIG" \
        "$JAIL_DIR"/*.local
    do
        [[ ! -f "$file" ]] || printf '%s\n' "$file"
    done

    printf '\n%s 内容：\n' "$CONFIG"
    if [[ -f "$CONFIG" ]]; then
        cat -- "$CONFIG"
    else
        printf '尚未创建。\n'
    fi
}

# 采集 SSH 相关参数，结果写入 PARAM_* 全局变量。
# mode=edit：留空表示不修改；mode=init：留空则取默认值。
collect_ssh_params() {
    local mode="$1"
    local def_port="" def_ban="" def_find="" def_retry=""

    PARAM_PORT=""
    PARAM_BAN=""
    PARAM_FIND=""
    PARAM_RETRY=""

    if [[ "$mode" == init ]]; then
        def_port=22
        def_ban=360000
        def_find=600
        def_retry=5
    fi

    ask "SSH 端口，多个用逗号分隔" "$def_port" || return 1
    if [[ -n "$REPLY" ]]; then
        valid_ports "$REPLY" ||
            { error "端口格式错误或超出 1～65535。"; return 1; }
        PARAM_PORT="$REPLY"
    fi

    ask "封禁时间，-1 表示永久，支持 30d 等单位" "$def_ban" || return 1
    if [[ -n "$REPLY" ]]; then
        [[ "$REPLY" == -1 ]] || valid_time "$REPLY" ||
            { error "封禁时间格式错误。"; return 1; }
        PARAM_BAN="$REPLY"
    fi

    ask "统计时间窗口" "$def_find" || return 1
    if [[ -n "$REPLY" ]]; then
        valid_time "$REPLY" ||
            { error "统计时间格式错误。"; return 1; }
        PARAM_FIND="$REPLY"
    fi

    ask "触发封禁的失败次数" "$def_retry" || return 1
    if [[ -n "$REPLY" ]]; then
        [[ "$REPLY" =~ ^[1-9][0-9]{0,5}$ ]] ||
            { error "次数必须是 1～999999。"; return 1; }
        PARAM_RETRY="$REPLY"
    fi
}

edit_parameters() {
    choose_jail || return 1
    : > "$WORK/changes"
    printf '留空保持原配置；时间支持秒数或 30m、12h、7d。\n'

    collect_ssh_params edit || return 1

    [[ -z "$PARAM_BAN" ]] ||
        printf 'bantime=%s\n' "$PARAM_BAN" >> "$WORK/changes"
    [[ -z "$PARAM_FIND" ]] ||
        printf 'findtime=%s\n' "$PARAM_FIND" >> "$WORK/changes"
    [[ -z "$PARAM_RETRY" ]] ||
        printf 'maxretry=%s\n' "$PARAM_RETRY" >> "$WORK/changes"
    [[ -z "$PARAM_PORT" ]] ||
        printf 'port=%s\n' "$PARAM_PORT" >> "$WORK/changes"

    save_config
}

# 生成 ignoreip 的新值：本机地址始终保留，
# mode 1 追加现有值，mode 2 整体替换；按顺序去重。
merge_ignoreip() {
    local mode="$1" current="$2" item value=""
    local -a known=()
    local -a existing=()

    shift 2

    known=("127.0.0.1/8" "::1")
    if [[ "$mode" == 1 ]]; then
        read -r -a existing <<< "$current"
        known+=("${existing[@]}")
    fi
    known+=("$@")

    for item in "${known[@]}"; do
        [[ -n "$item" ]] || continue
        [[ " $value " == *" $item "* ]] && continue
        value="${value:+$value }$item"
    done

    printf '%s' "$value"
}

# 从 jail.local 读取目标 Jail 当前的 ignoreip，供追加模式使用。
current_ignoreip() {
    local target="$1"
    local line value=""
    local in_section=0 collecting=0

    [[ -f "$CONFIG" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"

        if [[ "$line" =~ ^[[:space:]]*\[([^]]*)\] ]]; then
            in_section=0
            collecting=0
            [[ "${BASH_REMATCH[1]}" == "$target" ]] && in_section=1
            continue
        fi

        (( in_section == 1 )) || continue

        # 续行只接受形如地址的缩进行，避免把注释当成地址。
        if (( collecting == 1 )); then
            if [[ "$line" =~ ^[[:space:]]+([0-9A-Fa-f:.]+(/[0-9]{1,3})?)[[:space:]]*$ ]]; then
                value+=" ${BASH_REMATCH[1]}"
                continue
            fi
            collecting=0
        fi

        [[ "$line" =~ ^[[:space:]]*([#;].*)?$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_.-]+)[[:space:]]*[:=][[:space:]]*(.*)$ ]] ||
            continue

        [[ "${BASH_REMATCH[1]}" == ignoreip ]] || continue
        value="${BASH_REMATCH[2]}"
        value="${value%%;*}"
        value="${value%%#*}"
        collecting=1
    done < "$CONFIG"

    printf '%s' "$value"
}

edit_whitelist() {
    local item current mode value
    local -a entries=()

    choose_jail || return 1

    current=$(current_ignoreip "$JAIL")
    if [[ -n "$current" ]]; then
        printf '当前 ignoreip：%s\n' "$current"
    else
        printf '当前 jail.local 中没有设置该 Jail 的 ignoreip。\n'
    fi

    ask "1 追加到现有白名单；2 整体替换" "1" || return 1
    mode="$REPLY"
    case "$mode" in
        1|2) : ;;
        *) error "无效选项。"; return 1 ;;
    esac

    ask "IP/CIDR，空格分隔；留空则不添加" || return 1
    read -r -a entries <<< "$REPLY"

    for item in "${entries[@]}"; do
        valid_ignoreip_item "$item" ||
            { error "地址格式不正确：$item"; return 1; }
    done

    value=$(merge_ignoreip "$mode" "$current" "${entries[@]}")

    printf 'ignoreip=%s\n' "$value" > "$WORK/changes"
    save_config
}

toggle_jail() {
    choose_jail || return 1
    ask "1 启用；2 停用" || return 1
    case "$REPLY" in
        1) printf 'enabled=true\n' > "$WORK/changes" ;;
        2) printf 'enabled=false\n' > "$WORK/changes" ;;
        *) error "无效选项。"; return 1 ;;
    esac
    save_config
}

manage_ip() {
    local action="$1"
    choose_jail || return 1
    ask "IP 地址" || return 1
    valid_address_chars "$REPLY" ||
        { error "请输入 IPv4 或 IPv6 地址。"; return 1; }
    fail2ban-client set "$JAIL" "$action" "$REPLY"
}

initialize_ssh() {
    JAIL=sshd

    printf '初始化 SSH 防护，日志后端为 systemd。\n'
    printf '全局默认值：封禁 360000 秒，统计窗口 600 秒，失败 5 次。\n'
    printf '下面填写 sshd 的参数；直接回车使用提示中的默认值。\n'
    printf 'SSH 端口用于封禁规则，不会修改 SSH 服务的监听端口。\n\n'

    collect_ssh_params init || return 1

    cat > "$WORK/changes" <<EOF
enabled=true
filter=sshd
backend=systemd
port=$PARAM_PORT
bantime=$PARAM_BAN
findtime=$PARAM_FIND
maxretry=$PARAM_RETRY
EOF

    save_config ssh-defaults
}

jail_menu() {
    local choice

    while true; do
        menu "Jail 配置管理" \
            "1|修改端口、封禁时间、统计窗口及失败次数" \
            "2|设置 IP 白名单" \
            "3|启用 / 停用 Jail" \
            "4|初始化 SSH 防护并重设全局默认值" \
            "0|返回主菜单" || return 1

        choice="$SELECTED"

        case "$choice" in
            1) edit_parameters ;;
            2) edit_whitelist ;;
            3) toggle_jail ;;
            4)
                printf '\n此操作将配置 sshd，并重设 [DEFAULT] 中的以下参数：\n'
                printf 'bantime=360000，findtime=600，maxretry=5\n'
                printf 'ignoreip=127.0.0.1/8 ::1，backend=systemd\n'
                printf '继承这些默认值的其他 Jail 也可能受到影响。\n'
                printf '仅修改现有 Jail 参数，请选择本菜单的选项 1。\n\n'
                initialize_ssh
                ;;
            0) return 0 ;;
        esac
    done
}

ip_menu() {
    local choice

    while true; do
        menu "IP 封禁管理" \
            "1|封禁 IP" \
            "2|解封 IP" \
            "0|返回主菜单" || return 1

        choice="$SELECTED"

        case "$choice" in
            1) manage_ip banip ;;
            2) manage_ip unbanip ;;
            0) return 0 ;;
        esac
    done
}

service_menu() {
    local choice

    while true; do
        menu "服务管理及日志" \
            "1|启动服务" \
            "2|停止服务（通常会移除 Fail2ban 管理的封禁规则）" \
            "3|检查并重新加载配置" \
            "4|开启开机自启" \
            "5|关闭开机自启" \
            "6|查看服务状态" \
            "7|查看最近服务日志" \
            "8|查看最近 Fail2ban 文件日志" \
            "0|返回主菜单" || return 1

        choice="$SELECTED"

        case "$choice" in
            1)
                fail2ban-client -t &&
                    systemctl start fail2ban
                ;;
            2)
                systemctl stop fail2ban
                ;;
            3)
                fail2ban-client -t &&
                    fail2ban-client reload
                ;;
            4)
                systemctl enable fail2ban
                ;;
            5)
                systemctl disable fail2ban
                ;;
            6)
                systemctl --no-pager --full status fail2ban
                ;;
            7)
                journalctl -u fail2ban -n 100 --no-pager
                ;;
            8)
                if [[ -f /var/log/fail2ban.log ]]; then
                    tail -n 100 /var/log/fail2ban.log
                else
                    error "默认日志文件不存在，请检查 logtarget 配置。"
                fi
                ;;
            0)
                return 0
                ;;
        esac
    done
}

# 判断软件包在当前已启用的仓库中是否可安装。
# 用于决定 RHEL 系是否需要先启用 EPEL，而不是只看 fail2ban 是否存在。
packages_available() {
    local package

    for package in "$@"; do
        "$PKG_MANAGER" -q list available "$package" >/dev/null 2>&1 ||
            return 1
    done
}

# 判断发行版软件包是否安装。
# PKG_MANAGER 由 check_environment 设置。
package_installed() {
    local status

    case "$PKG_MANAGER" in
        apt)
            status=$(
                dpkg-query -W -f='${Status}' "$1" 2>/dev/null
            ) || return 1
            [[ "$status" == "install ok installed" ]]
            ;;
        dnf|yum)
            rpm -q "$1" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

# 加入安装队列，并去重。
queue_package() {
    local existing

    for existing in "${INSTALL_PACKAGES[@]}"; do
        [[ "$existing" != "$1" ]] || return 0
    done

    INSTALL_PACKAGES+=("$1")
}

# 自动安装所需软件包。
install_missing_packages() {
    local distro_id=""
    local id_line=""

    (( ${#INSTALL_PACKAGES[@]} > 0 )) || return 0

    printf '\n将自动安装以下组件：\n'
    printf '  %s\n' "${INSTALL_PACKAGES[@]}"

    case "$PKG_MANAGER" in
        apt)
            printf '\n更新软件包索引……\n'
            apt-get update || {
                error "更新软件包索引失败，请检查网络和软件源。"
                return 1
            }

            printf '\n安装缺失组件……\n'
            DEBIAN_FRONTEND=noninteractive \
                apt-get install -y "${INSTALL_PACKAGES[@]}" || {
                    error "安装失败，请检查上面的 apt 错误信息。"
                    return 1
                }
            ;;

        dnf|yum)
            # Rocky / AlmaLinux / CentOS 的 Fail2ban
            # 通常由 EPEL 仓库提供。
            if [[ -r /etc/os-release ]]; then
                while IFS= read -r id_line; do
                    case "$id_line" in
                        ID=*)
                            distro_id="${id_line#ID=}"
                            distro_id="${distro_id//\"/}"
                            distro_id="${distro_id//\'/}"
                            break
                            ;;
                    esac
                done < /etc/os-release
            fi

            case "$distro_id" in
                rocky|almalinux|centos|rhel)
                    # Fail2ban 及其 python3-systemd 依赖通常由 EPEL 提供。
                    # 按"待安装包在已启用仓库中是否可装"判断，
                    # 而不是只看 fail2ban-client 是否存在。
                    if ! package_installed epel-release &&
                       ! packages_available "${INSTALL_PACKAGES[@]}"; then
                        printf '\n安装 EPEL 软件源，以获取 Fail2ban 及其依赖……\n'
                        "$PKG_MANAGER" install -y epel-release || {
                            error "EPEL 安装失败，请检查软件源和系统版本。"
                            return 1
                        }
                    fi
                    ;;
            esac

            printf '\n安装缺失组件……\n'
            "$PKG_MANAGER" install -y "${INSTALL_PACKAGES[@]}" || {
                error "安装失败，请检查上面的软件源或依赖错误。"
                return 1
            }
            ;;

        *)
            error "不支持的软件包管理器：$PKG_MANAGER"
            return 1
            ;;
    esac

    # 清理 Bash 对命令路径的缓存。
    hash -r
}

check_environment() {
    local required package output state
    local missing=0
    local -a requirements

    # 使用全局变量，供上面的安装函数读取。
    PKG_MANAGER=""
    INSTALL_PACKAGES=()

    printf '\n========== 环境检测与自动安装 ==========\n'

    if (( EUID != 0 )); then
        error "自动安装需要 root 权限，请执行：sudo bash $0"
        return 1
    fi

    if (( BASH_VERSINFO[0] < 4 ||
          (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
        error "当前脚本需要 Bash 4.4 或更新版本。"
        return 1
    fi

    printf '[通过] root 权限，Bash %s\n' "$BASH_VERSION"

    # 当前脚本的服务管理依赖已经运行的 systemd。
    # 安装 systemd 软件包不能直接改变当前系统的 init。
    if [[ ! -d /run/systemd/system ]]; then
        error "当前环境未运行 systemd，无法使用此脚本的服务管理功能。"
        return 1
    fi

    printf '[通过] systemd 运行环境\n'

    if command -v apt-get >/dev/null 2>&1 &&
       command -v dpkg-query >/dev/null 2>&1; then
        PKG_MANAGER=apt
    elif command -v dnf >/dev/null 2>&1 &&
         command -v rpm >/dev/null 2>&1; then
        PKG_MANAGER=dnf
    elif command -v yum >/dev/null 2>&1 &&
         command -v rpm >/dev/null 2>&1; then
        PKG_MANAGER=yum
    else
        error "自动安装目前支持 apt、dnf 和 yum。"
        return 1
    fi

    printf '[通过] 软件包管理器：%s\n' "$PKG_MANAGER"

    # 格式：命令:提供该命令的软件包
    requirements=(
        "fail2ban-client:fail2ban"
        "systemctl:systemd"
        "journalctl:systemd"
        "awk:gawk"
        "flock:util-linux"
        "mktemp:coreutils"
        "cp:coreutils"
        "mv:coreutils"
        "chmod:coreutils"
        "chown:coreutils"
        "cat:coreutils"
        "rm:coreutils"
        "mkdir:coreutils"
        "tail:coreutils"
        "cmp:diffutils"
        "date:coreutils"
        "find:findutils"
        "ls:coreutils"
    )

    for required in "${requirements[@]}"; do
        package="${required#*:}"
        required="${required%%:*}"

        if ! command -v "$required" >/dev/null 2>&1; then
            printf '[缺少] %s，将安装 %s\n' "$required" "$package"
            queue_package "$package"
        fi
    done

    # SSH 初始化使用 backend=systemd，需要这个绑定。
    # 通过软件包数据库检查，不在 Shell 脚本中执行 Python 代码。
    case "$PKG_MANAGER" in
        apt) package=python3-systemd ;;
        dnf|yum) package=python3-systemd ;;
    esac

    if ! package_installed "$package"; then
        printf '[缺少] systemd 日志后端依赖：%s\n' "$package"
        queue_package "$package"
    fi

    # 同时没有常见底层防火墙工具时，安装两种常见 action
    # 使用的工具。具体采用哪一种仍由现有 Jail 的 action 决定。
    if ! command -v nft >/dev/null 2>&1 &&
       ! command -v iptables >/dev/null 2>&1; then
        printf '[缺少] nftables / iptables 防火墙工具\n'
        queue_package nftables
        queue_package iptables
    fi

    if (( ${#INSTALL_PACKAGES[@]} > 0 )); then
        install_missing_packages || return 1
    else
        printf '[通过] 所需组件已安装\n'
    fi

    printf '\n========== 安装后复检 ==========\n'

    for required in "${requirements[@]}"; do
        required="${required%%:*}"

        if ! command -v "$required" >/dev/null 2>&1; then
            printf '[失败] 安装后仍找不到命令：%s\n' "$required"
            missing=$((missing + 1))
        fi
    done

    if ! package_installed python3-systemd; then
        printf '[失败] systemd 日志后端依赖未安装成功\n'
        missing=$((missing + 1))
    fi

    if ! command -v nft >/dev/null 2>&1 &&
       ! command -v iptables >/dev/null 2>&1; then
        printf '[失败] 安装后仍找不到 nft 或 iptables\n'
        missing=$((missing + 1))
    fi

    if (( missing > 0 )); then
        error "仍有 $missing 项依赖不可用，请检查安装输出。"
        return 1
    fi

    printf '[通过] 必要命令及后端依赖完整\n'

    if [[ ! -d /etc/fail2ban ]]; then
        error "安装后仍缺少 /etc/fail2ban，请检查 Fail2ban 软件包。"
        return 1
    fi

    if [[ ! -r /etc/fail2ban ||
          ! -w /etc/fail2ban ||
          ! -x /etc/fail2ban ]]; then
        error "无法读写 /etc/fail2ban。"
        return 1
    fi

    # 某些精简环境可能没有预先创建该目录。
    mkdir -p /run/lock || {
        error "无法创建 /run/lock。"
        return 1
    }

    if [[ ! -w /run/lock || ! -x /run/lock ]]; then
        error "锁文件目录 /run/lock 不可用。"
        return 1
    fi

    printf '[通过] 配置目录和锁文件目录可用\n'

    if output=$(fail2ban-client -V 2>&1); then
        printf '[信息] %s\n' "$output"
    else
        printf '[失败] Fail2ban 客户端无法正常执行：\n%s\n' "$output"
        return 1
    fi

    if [[ -L "$CONFIG" ]]; then
        printf '[提示] %s 是符号链接，配置编辑会拒绝写入\n' "$CONFIG"
    elif [[ -e "$CONFIG" && ! -f "$CONFIG" ]]; then
        printf '[提示] %s 不是普通文件，配置编辑会拒绝写入\n' "$CONFIG"
    elif [[ ! -e "$CONFIG" ]]; then
        printf '[信息] jail.local 将在首次保存配置时创建\n'
    fi

    printf '\n检查 Fail2ban 配置……\n'
    if output=$(fail2ban-client -t 2>&1); then
        printf '[通过] 配置检查通过\n'
    else
        printf '[提示] 当前配置检查失败：\n%s\n' "$output"
        printf '       将继续进入菜单，方便修改配置。\n'
    fi

    state=$(
        systemctl show fail2ban.service \
            --property=LoadState --value 2>/dev/null
    ) || state=unknown
    printf '[信息] 服务单元状态：%s\n' "${state:-未知}"

    state=$(systemctl is-active fail2ban 2>/dev/null) || :
    printf '[信息] 服务运行状态：%s\n' "${state:-未知}"

    if [[ "$state" == active ]]; then
        if output=$(fail2ban-client ping 2>&1); then
            printf '[通过] Fail2ban 服务连接正常\n'
        else
            printf '[提示] Fail2ban 服务连接失败：\n%s\n' "$output"
        fi
    fi

    state=$(systemctl is-enabled fail2ban 2>/dev/null) || :
    printf '[信息] 开机自启状态：%s\n' "${state:-未知}"

    printf '\n环境检测与依赖安装完成。\n'
    return 0
}

fail2ban_is_installed() {
    local package status

    if command -v fail2ban-client >/dev/null 2>&1 ||
       command -v fail2ban-server >/dev/null 2>&1; then
        return 0
    fi

    if command -v dpkg-query >/dev/null 2>&1; then
        status=$(
            dpkg-query -W -f='${Status}' fail2ban 2>/dev/null
        ) || status=""

        [[ "$status" != "install ok installed" ]] || return 0
    fi

    if command -v rpm >/dev/null 2>&1; then
        for package in fail2ban fail2ban-server; do
            if rpm -q "$package" >/dev/null 2>&1; then
                return 0
            fi
        done
    fi

    return 1
}

main() {
    local first_install=0
    local mode="menu"
    local target_jail=""

    # --help / --version 不需要 root，放在最前面处理。
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                usage
                return 0
                ;;
            -V|--version)
                printf 'fail2ban.sh %s\n' "$VERSION"
                return 0
                ;;
            --check)
                mode="check"
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --status)
                mode="status"
                if [[ -n "${2-}" && "${2-}" != -* ]]; then
                    target_jail="$2"
                    shift
                fi
                ;;
            *)
                error "未知参数：$1"
                usage >&2
                return 1
                ;;
        esac
        shift
    done

    # 必须在自动安装之前记录状态。
    if ! fail2ban_is_installed; then
        first_install=1
        [[ "$mode" != "menu" ]] ||
            printf '\n首次安装 Fail2ban：依赖安装完成后将先配置 SSH 防护。\n'
    fi

    # 依赖安装会修改系统状态，先拿排他锁再安装，
    # 避免两个实例同时操作软件包数据库。
    if (( EUID != 0 )); then
        error "需要 root 权限，请执行：sudo bash $0"
        exit 1
    fi

    mkdir -p -- /run/lock 2>/dev/null || :
    exec 9>/run/lock/fail2ban-manager.lock || {
        error "无法创建锁文件。"
        exit 1
    }

    flock -n 9 || {
        error "另一个管理脚本正在运行。"
        exit 1
    }

    # 每次启动自动检测环境，并安装缺失组件。
    check_environment || exit 1

    # 非交互模式：检查或输出状态后直接退出，不创建临时目录。
    if [[ "$mode" == "check" ]]; then
        if fail2ban-client -t; then
            printf '\n配置检查通过。\n'
            return 0
        fi
        error "配置检查未通过。"
        return 1
    fi

    if [[ "$mode" == "status" ]]; then
        fail2ban-client status || return 1
        [[ -z "$target_jail" ]] || show_jail_status "$target_jail"
        return 0
    fi

    # 清理上次被强制终止或断电后留下的临时目录。
    find /etc/fail2ban -maxdepth 1 -name '.manager.*' -type d -mtime +0 \
        -exec rm -rf -- {} + 2>/dev/null || :

    WORK=$(mktemp -d /etc/fail2ban/.manager.XXXXXXXX) || {
        error "无法创建临时工作目录。"
        exit 1
    }

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    shopt -s nullglob

    # 首次安装时，必须先完成 sshd 配置。
    if (( first_install == 1 )); then
        printf '\n========== 首次安装：配置 SSH 防护 ==========\n'
        printf '请填写 SSH 实际监听的端口，多个端口使用逗号分隔。\n'
        printf '这里的端口用于封禁规则，不会修改 SSH 服务的监听端口。\n\n'

        if ! initialize_ssh; then
            error "首次 SSH 防护配置未完成。"
            printf '再次运行脚本后，可选择主菜单 3 → 子菜单 4 重新配置。\n' >&2
            exit 1
        fi

        printf '\nSSH 防护配置已保存并通过配置检查。\n'

        if is_active; then
            printf '\n检查 sshd Jail 运行状态……\n'
            if ! fail2ban-client status sshd; then
                printf '[提示] 无法获取 sshd Jail 状态，请通过主菜单 5 查看日志。\n'
            fi
        else
            printf 'Fail2ban 服务尚未运行，可通过主菜单 5 启动并开启开机自启。\n'
        fi
    fi

    while true; do
        menu "Fail2ban 管理" \
            "1|查看运行状态、封禁列表及参数" \
            "2|查看配置文件及加载顺序" \
            "3|Jail 配置管理" \
            "4|手动封禁 / 解封 IP" \
            "5|服务管理及日志" \
            "0|退出" || break

        case "$SELECTED" in
            1) show_status ;;
            2) show_config ;;
            3) jail_menu ;;
            4) ip_menu ;;
            5) service_menu ;;
            0) break ;;
        esac
    done
}

# 被 source 时只加载函数，不执行 main。
# BASH_SOURCE 为空表示脚本从标准输入读入（bash < file），此时仍应执行。
if [[ -z "${BASH_SOURCE[0]-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi