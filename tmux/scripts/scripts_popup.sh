#!/usr/bin/env bash

tmux_outer() {
    if [[ -n "${OUTER_TMUX_SOCKET:-}" ]]; then
        command tmux -S "$OUTER_TMUX_SOCKET" "$@"
    else
        command tmux "$@"
    fi
}

jump_to_pane_outer() {
    local pane_id="${1:-}"
    local session_id_arg="${2:-}"
    local window_id_arg="${3:-}"
    local client="${4:-}"
    local session_id=""
    local window_id=""
    local target=""

    [[ -n "$pane_id" ]] || return 1

    # Always trust pane_id and derive session/window from tmux,
    # because fzf output can be affected by --with-nth display columns.
    session_id="$(tmux_outer display-message -p -t "$pane_id" '#{session_id}' 2>/dev/null || true)"
    window_id="$(tmux_outer display-message -p -t "$pane_id" '#{window_id}' 2>/dev/null || true)"
    [[ -n "$session_id" ]] || session_id="$session_id_arg"
    [[ -n "$window_id" ]] || window_id="$window_id_arg"

    target="$pane_id"
    if [[ -n "$session_id" && -n "$window_id" ]]; then
        target="${session_id}:${window_id}"
    elif [[ -n "$session_id" ]]; then
        target="$session_id"
    fi

    if [[ -n "$client" ]]; then
        tmux_outer switch-client -c "$client" -t "$target" >/dev/null 2>&1 || true
    else
        tmux_outer switch-client -t "$target" >/dev/null 2>&1 || true
    fi

    tmux_outer select-pane -t "$pane_id" >/dev/null 2>&1 || true
}

new_window() {
    [[ -x $(command -v fzf 2>/dev/null) ]] || return
    pane_id=$(tmux_outer show -gqv '@fzf_pane_id')
    [[ -n $pane_id ]] && tmux_outer kill-pane -t $pane_id >/dev/null 2>&1
    tmux_outer new-window "bash $0 do_action" >/dev/null 2>&1
}

keys_help() {
    cat <<'EOF'
快捷键
Enter 跳转
Tab 多选
C-r 刷新
C-x 关 pane
C-v 横移
C-s 纵移
C-t 交换
Esc 取消
EOF
    while true; do sleep 3600; done
}

kill_nested_server() {
    [[ -n "${NESTED_SERVER:-}" ]] || return 0
    command tmux -L "$NESTED_SERVER" kill-server >/dev/null 2>&1 || true
}

close_panes_popup() {
    local nested_server="${1:-${NESTED_SERVER:-}}"
    tmux_outer set -gu @panes_popup_open >/dev/null 2>&1 || true
    tmux_outer set -gu @panes_popup_client >/dev/null 2>&1 || true
    [[ -n "$nested_server" ]] || return 0
    command tmux -L "$nested_server" kill-server >/dev/null 2>&1 || true
}

popup_ui() {
    # Runs inside tmux display-popup; creates a nested tmux to fully control layout (avoid outer hooks).
    outer_socket="${OUTER_TMUX_SOCKET:-}"
    if [[ -z "$outer_socket" && -n "${TMUX:-}" ]]; then
        outer_socket="${TMUX%%,*}"
    fi

    help_width="${TMUX_FZF_PANES_HELP_WIDTH:-13}"
    preview_pct="${TMUX_FZF_PANES_PREVIEW_PCT:-70}"

    nested_server="fzf_panes_popup_$$"
    nested_session="popup"

    preview_file="/tmp/tmux_fzf_panes_preview_${USER}_${nested_server}"
    : >"$preview_file" 2>/dev/null || true

    cleanup() {
        rm -f "$preview_file" "${preview_file}.tmp" 2>/dev/null || true
        command tmux -L "$nested_server" kill-server >/dev/null 2>&1 || true
    }
    trap cleanup EXIT SIGINT SIGTERM SIGHUP

    command tmux -L "$nested_server" -f /dev/null new-session -d -s "$nested_session" -n panes >/dev/null 2>&1 || true
    command tmux -L "$nested_server" set -g status off >/dev/null 2>&1 || true
    command tmux -L "$nested_server" set -g mouse off >/dev/null 2>&1 || true
    command tmux -L "$nested_server" bind-key -n M-a run-shell "OUTER_TMUX_SOCKET='$outer_socket' bash '$0' close_panes_popup '$nested_server'" >/dev/null 2>&1 || true

    # Layout: whole window split vertically (bottom = preview full width),
    # then top split horizontally (right = fixed-width keys help).
    command tmux -L "$nested_server" split-window -v -p "$preview_pct" -t "$nested_session:0.0" -d \
        "bash '$0' preview_tail '$preview_file'" >/dev/null 2>&1 || true

    command tmux -L "$nested_server" split-window -h -l "$help_width" -t "$nested_session:0.0" -d \
        "bash '$0' keys_help" >/dev/null 2>&1 || true

    # Start fzf selector without "typing a command" (no send-keys), so UI shows immediately.
    command tmux -L "$nested_server" respawn-pane -k -t "$nested_session:0.0" \
        "OUTER_TMUX_SOCKET='$outer_socket' OUTER_CLIENT='${ORIGIN_CLIENT:-}' ORIGIN_PANE_ID='${ORIGIN_PANE_ID:-}' NESTED_SERVER='$nested_server' PREVIEW_FILE='$preview_file' bash '$0' do_action_popup" \
        >/dev/null 2>&1 || true

    command tmux -L "$nested_server" -f /dev/null attach-session -t "$nested_session" >/dev/null 2>&1 || true
}

preview_tail() {
    preview_file="${1:-}"
    [[ -n "$preview_file" ]] || exit 0

    if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; then
        stat_sig() { stat -f '%i:%m:%z' "$1" 2>/dev/null || echo 0; }
    else
        stat_sig() { stat -c '%i:%Y:%s' "$1" 2>/dev/null || echo 0; }
    fi

    last_sig=""
    while true; do
        sig="$(stat_sig "$preview_file")"
        if [[ "$sig" != "$last_sig" ]]; then
            last_sig="$sig"
            printf '\033[H\033[J'
            if [[ -s "$preview_file" ]]; then
                cat "$preview_file"
            else
                printf '%s\n' "（暂无预览）"
            fi
        fi
        sleep 0.08
    done
}

write_preview() {
    preview_file="${1:-}"
    target_pane="${2:-}"
    [[ -n "$preview_file" && -n "$target_pane" ]] || exit 0

    tmp_file="${preview_file}.tmp"
    {
        tmux_outer display-message -p -t "$target_pane" 'PANE #{pane_id}  #{session_name}:#{window_index}.#{pane_index}  #{pane_current_command}'
        tmux_outer display-message -p -t "$target_pane" 'PATH #{pane_current_path}'
        printf '%s\n' '----'
        capture="$(tmux_outer capture-pane -p -t "$target_pane" -S -200 2>/dev/null || true)"
        if [[ -n "$capture" ]]; then
            printf '%s\n' "$capture"
        else
            printf '%s\n' "（该 pane 无 scrollback）"
        fi
    } >"$tmp_file" 2>/dev/null || printf '%s\n' "预览失败：$target_pane" >"$tmp_file"

    mv -f "$tmp_file" "$preview_file" 2>/dev/null || cp -f "$tmp_file" "$preview_file" 2>/dev/null || true
}

# invoked by pane-focus-in event
update_mru_pane_ids() {
    o_data=($(tmux_outer show -gqv '@mru_pane_ids'))
    current_pane_id=$(tmux_outer display-message -p '#D')
    n_data=($current_pane_id)
    for i in ${!o_data[@]}; do
        [[ $current_pane_id != ${o_data[i]} ]] && n_data+=(${o_data[i]})
    done
    tmux_outer set -g '@mru_pane_ids' "${n_data[*]}"
}

do_action() {
    trap 'tmux_outer set -gu @fzf_pane_id; tmux_outer set -gu @fzf_exclude_window_id; tmux_outer set -gu @panes_popup_open; tmux_outer set -gu @panes_popup_client' EXIT SIGINT SIGTERM
    current_pane_id=$(tmux_outer display-message -p '#D')
    tmux_outer set -g @fzf_pane_id $current_pane_id
    tmux_outer set -gu @fzf_exclude_window_id >/dev/null 2>&1 || true

    cmd="bash $0 panes_src_simple"
    if [[ -n "${OUTER_TMUX_SOCKET:-}" ]]; then
        preview_cmd="tmux -S '$OUTER_TMUX_SOCKET' capture-pane -p -t {1} -S -200 2>/dev/null | tail -n 200"
        last_pane_cmd='$(tmux -S '"$OUTER_TMUX_SOCKET"' show -gqv "@mru_pane_ids" | cut -d\  -f1)'
        tmux_in_fzf="tmux -S '$OUTER_TMUX_SOCKET'"
    else
        preview_cmd="tmux capture-pane -p -t {1} -S -200 2>/dev/null | tail -n 200"
        last_pane_cmd='$(tmux show -gqv "@mru_pane_ids" | cut -d\  -f1)'
        tmux_in_fzf="tmux"
    fi

    selected=$(FZF_DEFAULT_COMMAND=$cmd fzf -m --preview="$preview_cmd" \
        --preview-window='down,70%,wrap,follow' --reverse --info=inline --header-lines=1 --no-hscroll --no-sort \
        --tabstop="${TMUX_FZF_PANES_TABSTOP:-16}" \
        --header=$'Enter=跳转  Tab=多选  Alt-p=预览  Ctrl-r=刷新\nCtrl-x=关闭  Ctrl-v=横移  Ctrl-s=纵移  Ctrl-t=交换' \
        --delimiter='\t' --with-nth=1,4,5,6,7,8,9 --nth=1,4,5,6,7,8,9 \
        --bind="alt-a:abort" \
        --bind="alt-p:toggle-preview" \
        --bind="ctrl-r:reload($cmd)" \
        --bind="ctrl-x:execute-silent($tmux_in_fzf kill-pane -t {1})+reload($cmd)" \
        --bind="ctrl-v:execute($tmux_in_fzf move-pane -h -t $last_pane_cmd -s {1})+accept" \
        --bind="ctrl-s:execute($tmux_in_fzf move-pane -v -t $last_pane_cmd -s {1})+accept" \
        --bind="ctrl-t:execute-silent($tmux_in_fzf swap-pane -t $last_pane_cmd -s {1})+reload($cmd)")
    (($?)) && return

    ids_o=($(tmux_outer show -gqv '@mru_pane_ids'))
    ids=()
    for id in ${ids_o[@]}; do
        while read pane_line; do
            pane_info=($pane_line)
            pane_id=${pane_info[0]}
            [[ $id == $pane_id ]] && ids+=($id)
        done <<<$selected
    done

    id_n=${#ids[@]}
    id1=${ids[0]}
    if ((id_n == 1)); then
        selected_first="$(printf '%s\n' "$selected" | head -n 1)"
        sel_pane_id="$(printf '%s' "$selected_first" | cut -f 1 | awk '{print $1}')"
        jump_to_pane_outer "$sel_pane_id" "" "" "${OUTER_CLIENT:-}"
    elif ((id_n > 1)); then
        tmux_outer break-pane -s$id1
        i=1
        if [[ -n "${OUTER_TMUX_SOCKET:-}" ]]; then
            tmux_cmd="tmux -S '$OUTER_TMUX_SOCKET' "
        else
            tmux_cmd="tmux "
        fi
        while ((i < id_n)); do
            tmux_cmd+="move-pane -t${ids[i-1]} -s${ids[i]} \; select-layout -t$id1 'tiled' \; "
            ((i++))
        done

        # my personally configuration
        if (( id_n == 2 )); then
            w_size=($(tmux display-message -p '#{window_width} #{window_height}'))
            w_wid=${w_size[0]}
            w_hei=${w_size[1]}
            if (( 9*w_wid > 16*w_hei )); then
                layout='even-horizontal'
            else
                layout='even-vertical'
            fi
	        else
	            layout='tiled'
	        fi

        if [[ -n "${OUTER_CLIENT:-}" ]]; then
            tmux_cmd+="switch-client -c '$OUTER_CLIENT' -t$id1 \; "
        else
            tmux_cmd+="switch-client -t$id1 \; "
        fi
        tmux_cmd+="select-layout -t$id1 $layout \; "
        eval $tmux_cmd
    fi
}

do_action_outer() {
    do_action
    kill_nested_server
}

do_action_popup() {
    [[ -x $(command -v fzf 2>/dev/null) ]] || return

    preview_file="${PREVIEW_FILE:-}"

    export OUTER_TMUX_SOCKET OUTER_CLIENT NESTED_SERVER

    trap '
        tmux_outer set -gu @fzf_pane_id;
        tmux_outer set -gu @fzf_exclude_window_id;
        tmux_outer set -gu @panes_popup_open;
        tmux_outer set -gu @panes_popup_client;
        if [[ -n "'"$preview_file"'" ]]; then
            rm -f "'"$preview_file"'" "'"$preview_file"'.tmp" 2>/dev/null || true
        fi
    ' EXIT SIGINT SIGTERM SIGHUP

    current_pane_id="$(tmux_outer display-message -p '#D')"
    tmux_outer set -g @fzf_pane_id "$current_pane_id"
    tmux_outer set -gu @fzf_exclude_window_id >/dev/null 2>&1 || true

    cmd="bash $0 panes_src_simple"
    last_pane_cmd='$(tmux_outer show -gqv "@mru_pane_ids" | cut -d\  -f1)'

    if [[ -n "${OUTER_TMUX_SOCKET:-}" ]]; then
        tmux_in_fzf="tmux -S '$OUTER_TMUX_SOCKET'"
    else
        tmux_in_fzf="tmux"
    fi

    preview_update=""
    if [[ -n "$preview_file" ]]; then
        preview_update="bash $0 write_preview '$preview_file' {1}"
    fi

    if [[ -n "$preview_file" ]]; then
        first_id="$(bash "$0" panes_src_simple | sed 1d | head -n 1 | cut -f 1)"
        if [[ -n "${first_id:-}" ]]; then
            bash "$0" write_preview "$preview_file" "$first_id" >/dev/null 2>&1 || true
        fi
    fi

    selected=$(FZF_DEFAULT_COMMAND=$cmd fzf -m --reverse --info=inline --header-lines=1 --no-hscroll --no-sort \
        --tabstop="${TMUX_FZF_PANES_TABSTOP:-16}" \
        --prompt='panes> ' \
        --delimiter='\t' --with-nth=1,4,5,6,7,8,9 --nth=1,4,5,6,7,8,9 \
        --bind="start:execute-silent($preview_update)" \
        --bind="load:execute-silent($preview_update)" \
        --bind="focus:execute-silent($preview_update)" \
        --bind="ctrl-r:reload($cmd)" \
        --bind="ctrl-x:execute-silent($tmux_in_fzf kill-pane -t {1})+reload($cmd)" \
        --bind="ctrl-v:execute($tmux_in_fzf move-pane -h -t $last_pane_cmd -s {1})+accept" \
        --bind="ctrl-s:execute($tmux_in_fzf move-pane -v -t $last_pane_cmd -s {1})+accept" \
        --bind="ctrl-t:execute-silent($tmux_in_fzf swap-pane -t $last_pane_cmd -s {1})+reload($cmd)")

    if (($?)); then
        kill_nested_server
        return
    fi

    ids_o=($(tmux_outer show -gqv '@mru_pane_ids'))
    ids=()
    for id in ${ids_o[@]}; do
        while read pane_line; do
            pane_info=($pane_line)
            pane_id=${pane_info[0]}
            [[ $id == $pane_id ]] && ids+=($id)
        done <<<$selected
    done

    id_n=${#ids[@]}
    id1=${ids[0]}
    if ((id_n == 1)); then
        selected_first="$(printf '%s\n' "$selected" | head -n 1)"
        sel_pane_id="$(printf '%s' "$selected_first" | cut -f 1 | awk '{print $1}')"
        jump_to_pane_outer "$sel_pane_id" "" "" "${OUTER_CLIENT:-}"
    elif ((id_n > 1)); then
        tmux_outer break-pane -s"$id1"
        i=1
        if [[ -n "${OUTER_TMUX_SOCKET:-}" ]]; then
            tmux_cmd="tmux -S '$OUTER_TMUX_SOCKET' "
        else
            tmux_cmd="tmux "
        fi
        while ((i < id_n)); do
            tmux_cmd+="move-pane -t${ids[i-1]} -s${ids[i]} \; select-layout -t$id1 'tiled' \; "
            ((i++))
        done

        if (( id_n == 2 )); then
            w_size=($(tmux_outer display-message -p '#{window_width} #{window_height}'))
            w_wid=${w_size[0]}
            w_hei=${w_size[1]}
            if (( 9*w_wid > 16*w_hei )); then
                layout='even-horizontal'
            else
                layout='even-vertical'
            fi
        else
            layout='tiled'
        fi

        if [[ -n "${OUTER_CLIENT:-}" ]]; then
            tmux_cmd+="switch-client -c '$OUTER_CLIENT' -t$id1 \; "
        else
            tmux_cmd+="switch-client -t$id1 \; "
        fi
        tmux_cmd+="select-layout -t$id1 $layout \; "
        eval $tmux_cmd
    fi

    tmux_outer set -gu @panes_popup_open >/dev/null 2>&1 || true
    tmux_outer set -gu @panes_popup_client >/dev/null 2>&1 || true
    kill_nested_server
}

do_action_3pane() {
    [[ -x $(command -v fzf 2>/dev/null) ]] || return

    origin_pane="${ORIGIN_PANE:-}"
    origin_window="${ORIGIN_WINDOW:-}"

    selector_window_id="$(tmux display-message -p '#{window_id}')"
    selector_pane_id="$(tmux display-message -p '#{pane_id}')"
    tmux set -g @fzf_exclude_window_id "$selector_window_id"

    preview_file="/tmp/tmux_fzf_panes_preview_${USER}_${selector_window_id}_$$"
    : >"$preview_file" 2>/dev/null || true

    trap '
        tmux set -gu @fzf_pane_id;
        tmux set -gu @fzf_exclude_window_id;
        rm -f "'"$preview_file"'" "'"$preview_file"'.tmp" 2>/dev/null || true
    ' EXIT SIGINT SIGTERM

    help_width="${TMUX_FZF_PANES_HELP_WIDTH:-13}"
    preview_pct="${TMUX_FZF_PANES_PREVIEW_PCT:-70}"

    preview_pane_id="$(tmux split-window -v -p "$preview_pct" -d -P -F '#{pane_id}' "bash $0 preview_tail '$preview_file'")"
    help_pane_id="$(tmux split-window -h -l "$help_width" -d -P -F '#{pane_id}' "bash $0 keys_help")"

    tmux select-pane -t "$preview_pane_id" -T "preview" >/dev/null 2>&1 || true
    tmux select-pane -t "$help_pane_id" -T "keys" >/dev/null 2>&1 || true
    tmux select-pane -t "$selector_pane_id" -T "panes" >/dev/null 2>&1 || true

    # after-split-window hook 可能会自动等分布局；这里强制回到期望尺寸
    tmux resize-pane -t "$help_pane_id" -x "$help_width" >/dev/null 2>&1 || true
    window_height="$(tmux display-message -p '#{window_height}' 2>/dev/null || echo 0)"
    if [[ "$window_height" =~ ^[0-9]+$ ]] && (( window_height > 0 )); then
        preview_height=$(( window_height * preview_pct / 100 ))
        (( preview_height < 5 )) && preview_height=5
        tmux resize-pane -t "$preview_pane_id" -y "$preview_height" >/dev/null 2>&1 || true
    fi

    tmux set -g @fzf_pane_id "$selector_pane_id"

    cmd="bash $0 panes_src_simple"
    last_pane_cmd='$(tmux show -gqv "@mru_pane_ids" | cut -d\  -f1)'
    preview_update="bash $0 write_preview '$preview_file' {1}"

    selected=$(FZF_DEFAULT_COMMAND=$cmd fzf -m --reverse --info=inline --header-lines=1 --no-hscroll --no-sort \
        --tabstop="${TMUX_FZF_PANES_TABSTOP:-16}" \
        --prompt='panes> ' \
        --delimiter='\t' --with-nth=1,4,5,6,7,8,9 --nth=1,4,5,6,7,8,9 \
        --bind="load:execute-silent($preview_update)" \
        --bind="start:execute-silent($preview_update)" \
        --bind="focus:execute-silent($preview_update)" \
        --bind="ctrl-r:reload($cmd)" \
        --bind="ctrl-x:execute-silent(tmux kill-pane -t {1})+reload($cmd)" \
        --bind="ctrl-v:execute(tmux move-pane -h -t $last_pane_cmd -s {1})+accept" \
        --bind="ctrl-s:execute(tmux move-pane -v -t $last_pane_cmd -s {1})+accept" \
        --bind="ctrl-t:execute-silent(tmux swap-pane -t $last_pane_cmd -s {1})+reload($cmd)")

    if (($?)); then
        if [[ -n "$origin_pane" ]]; then
            tmux switch-client -t "$origin_pane" >/dev/null 2>&1 || true
        elif [[ -n "$origin_window" ]]; then
            tmux switch-client -t "$origin_window" >/dev/null 2>&1 || true
        fi
        tmux kill-window -t "$selector_window_id" >/dev/null 2>&1 || true
        return
    fi

    ids_o=($(tmux show -gqv '@mru_pane_ids'))
    ids=()
    for id in ${ids_o[@]}; do
        while read pane_line; do
            pane_info=($pane_line)
            pane_id=${pane_info[0]}
            [[ $id == $pane_id ]] && ids+=($id)
        done <<<$selected
    done

    id_n=${#ids[@]}
    id1=${ids[0]}
    if ((id_n == 1)); then
        tmux switch-client -t$id1
        tmux kill-window -t "$selector_window_id" >/dev/null 2>&1 || true
    elif ((id_n > 1)); then
        tmux break-pane -s$id1
        i=1
        tmux_cmd="tmux "
        while ((i < id_n)); do
            tmux_cmd+="move-pane -t${ids[i-1]} -s${ids[i]} \; select-layout -t$id1 'tiled' \; "
            ((i++))
        done

        if (( id_n == 2 )); then
            w_size=($(tmux display-message -p '#{window_width} #{window_height}'))
            w_wid=${w_size[0]}
            w_hei=${w_size[1]}
            if (( 9*w_wid > 16*w_hei )); then
                layout='even-horizontal'
            else
                layout='even-vertical'
            fi
        else
            layout='tiled'
        fi

        tmux_cmd+="switch-client -t$id1 \; select-layout -t$id1 $layout \; "
        eval $tmux_cmd
        tmux kill-window -t "$selector_window_id" >/dev/null 2>&1 || true
    fi
}

panes_src() {
    printf "%-6s  %-16s  %5s  %8s  %4s  %4s  %5s  %-8s  %-7s  %s\n" \
        'PANEID' 'SESSION' 'PANE' 'PID' '%CPU' '%MEM' 'THCNT' 'TIME' 'TTY' 'CMD'
    exclude_window_id="$(tmux show -gqv '@fzf_exclude_window_id')"
    panes_info=$(tmux list-panes -aF \
        '#D #{window_id} #{=|16|…:session_name} #I.#P #{pane_tty} #T' |
        awk -v self="$TMUX_PANE" -v ex="$exclude_window_id" \
            '$1 != self && (ex == "" || $2 != ex) { $2=""; sub(/^ +/, "", $0); print }')
    ttys=$(awk '{printf("%s,", $4)}' <<<$panes_info | sed 's/,$//')
    if [[ $(uname -s) == 'Darwin' ]]; then
        ps_info=$(ps -t$ttys -o state,pid,pcpu,pmem,wq,time,tty,command | awk '$1~/\+/ {$1="";print $0}')
    else
        ps_info=$(ps -t$ttys -o stat,pid,pcpu,pmem,thcount,time,tname,cmd | awk '$1~/\+/ {$1="";print $0}')
    fi
    ids=()
    hostname=$(hostname)
    for id in $(tmux show -gqv '@mru_pane_ids'); do
        while read pane_line; do
            pane_info=($pane_line)
            pane_id=${pane_info[0]}
            if [[ $id == $pane_id ]]; then
                ids+=($id)
                session=${pane_info[1]}
                pane=${pane_info[2]}
                tty=${pane_info[3]#/dev/}
                title=${pane_info[@]:4}
                while read ps_line; do
                    p_info=($ps_line)
                    if [[ $tty == ${p_info[5]} ]]; then
                        printf "%-6s  %-7s  %5s  %8s  %4s  %4s  %5s  %-8s  %-7s  " \
                            $pane_id $session $pane ${p_info[@]::6}
                        cmd=${p_info[@]:6}
                        # vim path of current buffer if it setted the title
                        if [[ $cmd =~ ^n?vim && $title != $hostname ]]; then
                            cmd_arr=($cmd)
                            cmd="${cmd_arr[0]} $title"
                        fi
                        echo $cmd
                        break
                    fi
                done <<<$ps_info
            fi
        done <<<$panes_info
    done
    tmux set -g '@mru_pane_ids' "${ids[*]}"
}

panes_src_simple() {
    exclude_window_id="$(tmux_outer show -gqv '@fzf_exclude_window_id')"
    mru="$(tmux_outer show -gqv '@mru_pane_ids')"
    origin_pane_id="${ORIGIN_PANE_ID:-}"
    if [[ -z "$origin_pane_id" && -n "${OUTER_CLIENT:-}" ]]; then
        origin_pane_id="$(tmux_outer display-message -p -t "$OUTER_CLIENT" '#{pane_id}' 2>/dev/null || true)"
    fi
    format=$'#D\t#{session_id}\t#{window_id}\t#{window_activity_flag}\t#{=|48|…:session_name}\t#I:#{=|56|…:window_name}\t#P\t#{=|80|…:pane_title}\t#{pane_current_command}\t#{pane_current_path}'

    out="$(
        tmux_outer list-panes -aF "$format" |
            awk -v ex="$exclude_window_id" -v mru="$mru" -v origin="$origin_pane_id" -F'\t' '
                BEGIN {
                  print "PANEID\tSESSION_ID\tWINDOW_ID\tSESSION\tWIN\tPANE\tTITLE\tCMD\tPATH"
                  n = split(mru, order, " ")
                  seen_n = 0
                }
                ex == "" || $3 != ex || $1 == origin {
                  # PANEID SESSION_ID WINDOW_ID ACTIVITY SESSION WIN PANE TITLE CMD PATH
                  id = $1
                  is_unread = ($4 == 1 ? 1 : 0)
                  unread_mark = (is_unread == 1 ? "● " : "  ")
                  win = unread_mark $6
                  row[id] = id "\t" $2 "\t" $3 "\t" $5 "\t" win "\t" $7 "\t" $8 "\t" $9 "\t" $10
                  unread[id] = is_unread
                  seen[++seen_n] = id
                }
                END {
                  # 0) origin pane first (if present)
                  if (origin != "" && (origin in row)) {
                    print row[origin]
                    delete row[origin]
                    delete unread[origin]
                  }
                  # 1) unread first (MRU order)
                  for (i = 1; i <= n; i++) {
                    id = order[i]
                    if (id in row && unread[id] == 1) {
                      print row[id]
                      delete row[id]
                      delete unread[id]
                    }
                  }
                  # 2) unread remaining (source order)
                  for (j = 1; j <= seen_n; j++) {
                    id = seen[j]
                    if (id in row && unread[id] == 1) {
                      print row[id]
                      delete row[id]
                      delete unread[id]
                    }
                  }
                  # 3) read (MRU order)
                  for (i = 1; i <= n; i++) {
                    id = order[i]
                    if (id in row) {
                      print row[id]
                      delete row[id]
                      delete unread[id]
                    }
                  }
                  # 4) read remaining (source order)
                  for (j = 1; j <= seen_n; j++) {
                    id = seen[j]
                    if (id in row) {
                      print row[id]
                      delete row[id]
                      delete unread[id]
                    }
                  }
                }
            '
    )"

    ids="$(printf '%s\n' "$out" | sed 1d | awk -F'\t' '{print $1}' | tr '\n' ' ')"
    ids="${ids% }"
    tmux_outer set -g '@mru_pane_ids' "$ids"
    printf '%s\n' "$out"
}

$@
