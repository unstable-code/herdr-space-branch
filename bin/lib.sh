#!/usr/bin/env bash
# Shared helpers for bin/report (event hooks) and bin/watch (branch-change daemon).

herdr=${HERDR_BIN_PATH:-herdr}
source_id=unstable-code.herdr-space-branch
state_dir=${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-space-branch}
config_dir=${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-space-branch}

# config.toml is read with grep rather than a TOML parser: this plugin is three shell scripts and
# has a handful of scalar settings. Unknown keys are ignored.
config_value() {
    local key=$1 default=$2 value
    value=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$config_dir/config.toml" 2>/dev/null |
        head -1 | tr -d '"'"'"' \t\r')
    printf '%s\n' "${value:-$default}"
}

# strict = false (default): when the pane you are on is not a git work tree, fall back to another
#   pane of the same tab, so a shell sitting in $HOME does not blank the row.
# strict = true: show only the repository of the pane you are on, and clear the row otherwise.
strict_pane=$(config_value strict false)
case "$strict_pane" in true | 1 | yes | on) strict_pane=1 ;; *) strict_pane=0 ;; esac

# Millisecond clock. herdr keeps the highest sequence per source, so a late event cannot
# resurrect an older value.
now_ms() { date +%s%3N 2>/dev/null || date +%s; }

# git dir of a work tree, so the daemon can watch HEAD without running git.
git_head_file() {
    local dir
    dir=$(git -C "$1" rev-parse --git-dir 2>/dev/null) || return 1
    case "$dir" in
        /*) printf '%s/HEAD\n' "$dir" ;;
        *) printf '%s/%s/HEAD\n' "$1" "$dir" ;;
    esac
}

# Branch name, or detached@<short sha>. Empty when $1 is not a work tree.
git_branch_label() {
    git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    local branch
    branch=$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null) || {
        local sha
        sha=$(git -C "$1" rev-parse --short HEAD 2>/dev/null) || return 1
        branch="detached@$sha"
    }
    [ -n "$branch" ] || return 1
    printf '%s\n' "$branch"
}

# "↑N ↓M" against the upstream, matching herdr's built-in git_status column
# (src/ui/sidebar.rs). Empty when there is no upstream or no difference.
git_ahead_behind() {
    local counts behind ahead out=""
    counts=$(git -C "$1" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null) || return 0
    behind=${counts%%[[:space:]]*}
    ahead=${counts##*[[:space:]]}
    [ "${ahead:-0}" -gt 0 ] 2>/dev/null && out="↑$ahead"
    if [ "${behind:-0}" -gt 0 ] 2>/dev/null; then
        [ -n "$out" ] && out="$out "
        out="$out↓$behind"
    fi
    printf '%s\n' "$out"
}

# Start bin/watch unless it is already running. The [[startup]] hook only fires when the herdr
# server starts, so a plugin installed into a running server would otherwise have no daemon until
# the next restart; this also brings it back if it was killed.
ensure_watch() {
    local pidfile="$state_dir/watch.pid" pid
    pid=$(cat "$pidfile" 2>/dev/null) || pid=""
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    "$(dirname "${BASH_SOURCE[0]}")/watch" --spawn >/dev/null 2>&1 &
    return 0
}

# publish <workspace> <cwd>: report branch/git_status tokens for that workspace, and remember
# the cwd, the watched HEAD file and the last published value so the daemon can skip no-ops.
# Clears both tokens when the directory is not a git work tree.
publish() {
    local workspace=$1 cwd=$2 seq branch status value head_file
    [ -n "$workspace" ] || return 0
    mkdir -p "$state_dir" 2>/dev/null || return 0
    seq=$(now_ms)

    if [ -z "$cwd" ] || [ ! -d "$cwd" ] || ! branch=$(git_branch_label "$cwd"); then
        "$herdr" workspace report-metadata "$workspace" --source "$source_id" --seq "$seq" \
            --clear-token branch --clear-token git_status >/dev/null 2>&1
        printf '' >"$state_dir/$workspace.value"
        printf '' >"$state_dir/$workspace.head"
        return 0
    fi

    status=$(git_ahead_behind "$cwd")
    if [ -n "$status" ]; then
        "$herdr" workspace report-metadata "$workspace" --source "$source_id" --seq "$seq" \
            --token "branch=$branch" --token "git_status=$status" >/dev/null 2>&1
    else
        "$herdr" workspace report-metadata "$workspace" --source "$source_id" --seq "$seq" \
            --token "branch=$branch" --clear-token git_status >/dev/null 2>&1
    fi

    value="$branch|$status"
    printf '%s\n' "$value" >"$state_dir/$workspace.value"
    printf '%s\n' "$cwd" >"$state_dir/$workspace.cwd"
    head_file=$(git_head_file "$cwd") && printf '%s\n' "$head_file" >"$state_dir/$workspace.head"
    return 0
}

# "<workspace>\t<cwd>\t<cwd>..." — every candidate directory of a workspace's active tab, the
# focused pane first, then the rest in layout order.
#
# One snapshot covers all workspaces, which is what makes this cheap enough to run on every hook
# and every daemon tick. Updating only the workspace an event carries is not enough: switching tabs
# inside a workspace changes which repository is visible there, and the sidebar draws every row.
#
# Ordering matters because only the globally focused pane carries `focused: true`: in every other
# workspace nothing in the snapshot marks the pane you were last in. So the order is
#   ① the pane focused right now, ② the pane this workspace was last focused on (remembered by the
#   hooks, see remember_pane), ③ the rest in layout order,
# and `pick_repo_cwd` then takes the first candidate that really is a work tree. Picking the first
# pane blindly used to land on whatever shell sat there — often a directory that is not a
# repository at all, which wiped a perfectly good branch the moment the workspace lost focus.
workspace_cwds() {
    local last_panes=""
    local file workspace
    for file in "$state_dir"/*.pane; do
        [ -e "$file" ] || continue
        workspace=$(basename "$file" .pane)
        last_panes="$last_panes$workspace=$(cat "$file" 2>/dev/null)"$'\n'
    done
    "$herdr" api snapshot 2>/dev/null | jq -r --arg last "$last_panes" '
        ($last | split("\n") | map(select(length > 0) | split("=") | {key: .[0], value: .[1]})
            | from_entries) as $last_pane
        | .result.snapshot as $s
        | $s.workspaces[]
        | . as $w
        | ($s.panes
            | map(select(.workspace_id == $w.workspace_id and .tab_id == $w.active_tab_id))) as $panes
        | ($last_pane[$w.workspace_id] // "") as $remembered
        | (($panes | map(select(.focused)))
            + ($panes | map(select(.pane_id == $remembered)))
            + $panes) as $ordered
        | [$w.workspace_id]
            + (reduce $ordered[] as $p ([];
                (($p.foreground_cwd // $p.cwd) // "") as $c
                | if $c == "" or (. | index($c)) then . else . + [$c] end))
        | @tsv' 2>/dev/null
}

# Remember which pane a workspace was last focused on, so its row keeps showing that repository
# after the focus moves elsewhere.
remember_pane() {
    local workspace=$1 pane=$2
    [ -n "$workspace" ] && [ -n "$pane" ] || return 0
    mkdir -p "$state_dir" 2>/dev/null || return 0
    printf '%s\n' "$pane" >"$state_dir/$workspace.pane"
    return 0
}

# First candidate that is a git work tree; empty when none is (then the row is cleared on purpose).
# With strict = true only the first candidate — the pane you are actually on — is considered.
pick_repo_cwd() {
    local cwd
    [ "$strict_pane" -eq 1 ] && set -- "${1:-}"
    for cwd in "$@"; do
        [ -n "$cwd" ] && [ -d "$cwd" ] || continue
        if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            printf '%s\n' "$cwd"
            return 0
        fi
    done
    return 1
}

# Publish every workspace whose rendered value would change.
publish_all() {
    local line workspace candidates cwd branch status want have
    local -a cwds
    while IFS= read -r line; do
        IFS=$'\t' read -r workspace candidates <<<"$line"
        [ -n "$workspace" ] || continue
        # No candidate at all means "unknown", not "no repository" — a pane can report none while it
        # is still starting. Clearing on that would blank a row that is fine, so leave it as it is.
        [ -n "${candidates:-}" ] || continue
        IFS=$'\t' read -r -a cwds <<<"$candidates"
        cwd=$(pick_repo_cwd "${cwds[@]}") || cwd=""
        branch=""
        status=""
        if [ -n "$cwd" ] && branch=$(git_branch_label "$cwd"); then
            status=$(git_ahead_behind "$cwd")
            want="$branch|$status"
        else
            want=""
        fi
        # Skip the report when the sidebar already shows this, for this same directory.
        have=$(cat "$state_dir/$workspace.value" 2>/dev/null)
        [ "$want" = "$have" ] && [ -f "$state_dir/$workspace.cwd" ] &&
            [ "$(cat "$state_dir/$workspace.cwd" 2>/dev/null)" = "$cwd" ] && continue
        publish "$workspace" "$cwd"
    done < <(workspace_cwds)
    return 0
}
