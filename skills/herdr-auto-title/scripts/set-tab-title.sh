#!/bin/sh
# herdr-auto-title: rename the calling agent's own Herdr tab.
#
# Usage:
#   set-tab-title.sh [--force] <title words...>   rename the caller's tab
#   set-tab-title.sh --status                     print gates and current label, mutate nothing
#
# Exit status:
#   0  renamed (or --status printed)
#   1  Herdr command failed
#   2  usage error / unusable title
#   3  skipped by policy (outside Herdr, opted out, not the owner, label preserved)
#
# Only touches the tab that hosts the calling pane, resolved live through
# `herdr pane current --current`. Never reads HERDR_TAB_ID (stale after pane
# moves), never uses the focused tab, never changes focus or layout.
set -u

MAX_TITLE_CHARS=60
MAX_WORD_CHARS=24

usage() {
	printf 'usage: %s [--force] <title words...> | --status\n' "${0##*/}" >&2
	exit 2
}

skip() {
	printf 'skip: %s\n' "$1"
	exit 3
}

fail() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

force=0
status=0
while [ $# -gt 0 ]; do
	case "$1" in
	--force) force=1 ;;
	--status) status=1 ;;
	--help | -h) usage ;;
	--) shift; break ;;
	-*) usage ;;
	*) break ;;
	esac
	shift
done

if [ "$status" -eq 0 ] && [ $# -eq 0 ]; then
	usage
fi

# Gate 1: inside a Herdr-managed pane with caller identity. Nothing below runs
# outside Herdr, so no socket is ever contacted from a foreign shell.
[ "${HERDR_ENV:-}" = 1 ] || skip "not running inside Herdr (HERDR_ENV is not 1)"
[ -n "${HERDR_PANE_ID:-}" ] || skip "HERDR_PANE_ID is not set; caller pane unknown"
[ -n "${HERDR_WORKSPACE_ID:-}" ] || skip "HERDR_WORKSPACE_ID is not set; caller workspace unknown"

# Gate 2: opt-out. HERDR_AUTO_TITLE is this skill's own switch, not a Herdr variable.
case "${HERDR_AUTO_TITLE:-}" in
0 | off | false | no) skip "HERDR_AUTO_TITLE=${HERDR_AUTO_TITLE} disables automatic titles" ;;
esac

if command -v herdr >/dev/null 2>&1; then
	HERDR=herdr
elif [ -n "${HERDR_BIN_PATH:-}" ] && [ -x "$HERDR_BIN_PATH" ]; then
	HERDR=$HERDR_BIN_PATH
else
	fail "herdr binary not found in PATH"
fi
command -v jq >/dev/null 2>&1 || fail "jq is required to parse Herdr JSON responses"

# Title normalization (only when renaming): join args, drop control characters
# and escape sequences, collapse whitespace, strip leading dashes so the label
# can never be parsed as a flag. The label is passed as one argv element and is
# never evaluated by a shell.
title=""
if [ "$status" -eq 0 ]; then
	esc=$(printf '\033')
	title=$(printf '%s ' "$@" |
		LC_ALL=C sed -e "s/${esc}\\[[0-9;?]*[ -/]*[@-~]//g" -e "s/${esc}[@-_]//g" |
		tr '\t\n\r' '   ' | tr -d '\000-\037\177' | tr -s ' ' | sed -e 's/^[ -]*//' -e 's/ *$//')
	[ -n "$title" ] || { printf 'error: title is empty after sanitizing\n' >&2; exit 2; }
	chars=$(printf '%s' "$title" | wc -m | tr -d ' ')
	if [ "$chars" -gt "$MAX_TITLE_CHARS" ]; then
		printf 'error: title is %s characters; keep it to 3-6 words (max %s)\n' "$chars" "$MAX_TITLE_CHARS" >&2
		exit 2
	fi
	for word in $title; do
		wlen=$(printf '%s' "$word" | wc -m | tr -d ' ')
		if [ "$wlen" -gt "$MAX_WORD_CHARS" ]; then
			printf 'error: word "%s" is too long for a title; it looks like an identifier or secret\n' "$word" >&2
			exit 2
		fi
		case "$word" in
		sk-* | sk_* | ghp_* | gho_* | ghs_* | github_pat_* | xox[abps]-* | AKIA* | eyJ*)
			printf 'error: word "%s" looks like a credential; titles must not contain secrets\n' "$word" >&2
			exit 2
			;;
		esac
	done
fi

# Live caller lookup: pane IDs stay valid aliases after moves, tab IDs do not.
pane_json=$("$HERDR" pane current --current) || fail "herdr pane current --current failed"
tab_id=$(printf '%s' "$pane_json" | jq -r '.result.pane.tab_id // empty')
pane_id=$(printf '%s' "$pane_json" | jq -r '.result.pane.pane_id // empty')
workspace_id=$(printf '%s' "$pane_json" | jq -r '.result.pane.workspace_id // empty')
[ -n "$tab_id" ] && [ -n "$pane_id" ] && [ -n "$workspace_id" ] || fail "could not resolve the caller's tab from herdr pane current"

tab_json=$("$HERDR" tab get "$tab_id") || fail "herdr tab get $tab_id failed"
label=$(printf '%s' "$tab_json" | jq -r '.result.tab.label // empty')
pane_count=$(printf '%s' "$tab_json" | jq -r '.result.tab.pane_count // 0')

# Ownership: another recognized agent in the same tab means the tab is shared;
# do not compete for its title.
other_agents=0
if [ "$pane_count" -gt 1 ]; then
	panes_json=$("$HERDR" pane list --workspace "$workspace_id") || fail "herdr pane list failed"
	other_agents=$(printf '%s' "$panes_json" | jq -r --arg t "$tab_id" --arg me "$pane_id" \
		'[.result.panes[] | select(.tab_id == $t and .pane_id != $me and .agent != null)] | length')
fi

# Memory of titles this skill set, keyed per server socket and tab, so a label
# changed by the user or another tool is recognized and preserved.
state_dir=${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/herdr-auto-title
state_key=$(printf '%s|%s' "${HERDR_SOCKET_PATH:-default}" "$tab_id" | cksum | cut -d' ' -f1)
state_file=$state_dir/$state_key
last_set=""
[ -r "$state_file" ] && last_set=$(cat "$state_file")

# Owned label: empty, Herdr's default bare number, or the last title we set.
owned_label=0
if [ -z "$label" ] || [ "$label" = "$last_set" ]; then
	owned_label=1
else
	case "$label" in *[!0-9]*) ;; *) owned_label=1 ;; esac
fi

if [ "$status" -eq 1 ]; then
	printf 'tab_id=%s\npane_id=%s\nlabel=%s\npane_count=%s\nother_agent_panes=%s\nlast_set_by_skill=%s\nauto_rename_allowed=%s\n' \
		"$tab_id" "$pane_id" "$label" "$pane_count" "$other_agents" "$last_set" \
		"$([ "$other_agents" -eq 0 ] && [ "$owned_label" -eq 1 ] && echo yes || echo no)"
	exit 0
fi

if [ "$force" -eq 0 ]; then
	[ "$other_agents" -eq 0 ] || skip "tab $tab_id hosts $other_agents other agent pane(s); shared tabs keep their title"
	[ "$owned_label" -eq 1 ] || skip "tab $tab_id label \"$label\" was not set by this skill; preserved (use --force only when the user asked)"
fi

[ "$label" = "$title" ] && { printf 'unchanged %s: "%s"\n' "$tab_id" "$title"; exit 0; }

result=$("$HERDR" tab rename "$tab_id" "$title") || fail "herdr tab rename $tab_id failed"
new_label=$(printf '%s' "$result" | jq -r '.result.tab.label // empty')
[ "$new_label" = "$title" ] || fail "rename returned unexpected label: $result"

mkdir -p "$state_dir" 2>/dev/null && printf '%s' "$title" >"$state_file" 2>/dev/null
printf 'renamed %s: "%s" -> "%s"\n' "$tab_id" "$label" "$new_label"
