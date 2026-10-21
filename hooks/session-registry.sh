#!/usr/bin/env bash
# Records interactive Claude Code sessions so claude-restore can relaunch them.
# Runs on SessionStart, UserPromptSubmit (heartbeat) and SessionEnd.
#
# SessionEnd marks the entry rather than deleting it. A v1 that deleted lost
# sessions to some event that fired SessionEnd on a session that was still
# running, so the process being gone is now the only thing that retires an
# entry, and every invocation is logged so the next failure is diagnosable.
#
# Writes are serialised with a registry lock and go through a unique temp file
# that must hold a valid entry before it replaces the old one. The heartbeat
# runs async, and v2 shared one fixed temp name per entry, so overlapping
# invocations could rename a truncated file into place. jq turns an empty
# input into an empty output, so such an entry then stayed empty for good.
#
# One session can be open in several processes at once (resumed in a second
# terminal). v3 kept a single pid per entry, so a second resume replaced the
# first process and either one exiting marked the session ended while the
# other was still running. The entry now lists every process holding the
# session in .holders, and SessionEnd marks it ended only when none is left.
set -uo pipefail

REG="${CLAUDE_SESSION_REGISTRY:-$HOME/.claude/open-sessions}"
LOG="$REG/.events.log"
mkdir -p "$REG" 2>/dev/null || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "${payload:-}" ] || exit 0

mapfile -t F < <(
  printf '%s' "$payload" |
  jq -r '.hook_event_name // "", .session_id // "", .cwd // "",
         .transcript_path // "", .agent_id // "", (.source // .reason // "")' 2>/dev/null
) || exit 0
[ "${#F[@]}" -eq 6 ] || exit 0
event=${F[0]}; sid=${F[1]}; cwd=${F[2]}; tpath=${F[3]}; aid=${F[4]}; src=${F[5]}

[ -n "${sid:-}" ] || exit 0
[ -z "${aid:-}" ] || exit 0   # subagents are not separately resumable windows

# Shared with claude-restore. Short wait: SessionEnd hooks get little time.
exec 8>>"$REG/.lock" 2>/dev/null || exit 0
flock -w 3 8 || exit 0

log() {
  [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 2000000 ] &&
    mv -f "$LOG" "$LOG.1" 2>/dev/null
  printf '%s %-17s %s %-8s pid=%-8s %s\n' "$(date -Is)" "$event" "${sid:0:8}" \
    "${src:-none}" "${cpid:-?}" "$1" >> "$LOG" 2>/dev/null
}

ppid_of() { awk '/^PPid:/{print $2}' "/proc/$1/status" 2>/dev/null; }

find_claude_pid() {
  local p="${PPID:-0}" i comm
  for ((i = 0; i < 12; i++)); do
    [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || break
    comm=$(cat "/proc/$p/comm" 2>/dev/null) || break
    [ "$comm" = "claude" ] && { printf '%s' "$p"; return; }
    p=$(ppid_of "$p")
  done
  printf '0'
}

starttime_of() {
  local s
  s=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
  s=${s#*") "}
  awk '{print $20}' <<<"$s" 2>/dev/null
}

cpid=$(find_claude_pid)
entry="$REG/$sid.json"
now=$(date -Is)
boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
stime=$(starttime_of "$cpid")

valid() { jq -e 'type == "object" and (.session_id | type == "string")' "$1" >/dev/null 2>&1; }

self=$(jq -nc --argjson pid "${cpid:-0}" --arg stime "${stime:-}" --arg boot "${boot:-}" \
  'if $pid > 1 then [{pid: $pid, stime: $stime, boot: $boot}] else [] end')

# The entry's holders, other than this process, that are still running. An
# entry from before .holders existed has just its own pid.
other_holders() {
  local pid st bt keep=()
  valid "$entry" || { printf '[]'; return; }
  while IFS=$'\t' read -r pid st bt; do
    [ "$pid" -gt 1 ] 2>/dev/null && [ "$pid" != "$cpid" ] && [ "$bt" = "$boot" ] || continue
    [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = claude ] || continue
    [ -z "$st" ] || [ "$(starttime_of "$pid")" = "$st" ] || continue
    keep+=("$(jq -nc --argjson pid "$pid" --arg st "$st" --arg bt "$bt" \
      '{pid: $pid, stime: $st, boot: $bt}')")
  done < <(jq -r '(.holders // [{pid, stime: .pid_starttime, boot: .boot_id}])[]
                  | [.pid // 0, .stime // "", .boot // ""] | @tsv' "$entry" 2>/dev/null)
  printf '%s\n' "${keep[@]}" | jq -sc 'map(select(. != null))' 2>/dev/null || printf '[]'
}

# Run jq into a fresh temp file and install it only if it holds a valid entry.
commit() {
  local tmp
  tmp=$(mktemp "$REG/.$sid.XXXXXX.tmp" 2>/dev/null) || return 1
  if jq "$@" > "$tmp" 2>/dev/null && valid "$tmp"; then
    mv -f "$tmp" "$entry" 2>/dev/null && return 0
  fi
  rm -f "$tmp"
  return 1
}

write_full() {  # write_full <holders other than this process, JSON array>
  local tab
  tab=$(tr '\0' '\n' < "/proc/$cpid/environ" 2>/dev/null |
        sed -n 's/^GNOME_TERMINAL_SCREEN=//p' | head -1)
  commit -n --arg sid "$sid" --arg cwd "$cwd" --arg tp "$tpath" \
        --arg boot "${boot:-}" --arg tab "${tab:-}" --arg src "${src:-}" \
        --argjson pid "${cpid:-0}" --arg stime "${stime:-}" --arg at "$now" \
        --argjson holders "$(jq -nc --argjson o "${1:-[]}" --argjson s "$self" '$o + $s')" \
    '{session_id:$sid, cwd:$cwd, transcript_path:$tp, pid:$pid,
      pid_starttime:$stime, boot_id:$boot, terminal_tab:$tab,
      source:$src, recorded_at:$at, last_seen:$at,
      ended_at:null, end_reason:null, holders:$holders}'
}

case "$event" in
  SessionEnd)
    # Mark, never delete. Whether the session really ended is decided later by
    # whether the process is actually gone.
    others=$(other_holders)
    if [ "$others" != "[]" ]; then
      # Still open elsewhere: hand the entry to the newest remaining holder.
      commit --argjson o "$others" \
        '.holders = $o | .pid = $o[-1].pid | .pid_starttime = $o[-1].stime
         | .boot_id = $o[-1].boot' "$entry"
      log "closed here, still open in pid $(jq -r 'map(.pid) | join(",")' <<<"$others"); not marked"
    elif valid "$entry"; then
      commit --arg at "$now" --arg r "${src:-other}" \
        '.ended_at = $at | .end_reason = $r | .holders = []' "$entry"
      log "marked ended (reason=${src:-other})"
    elif [ -e "$entry" ]; then
      write_full && commit --arg at "$now" --arg r "${src:-other}" \
        '.ended_at = $at | .end_reason = $r' "$entry"
      log "rebuilt unreadable entry, marked ended (reason=${src:-other})"
    else
      log "end for unknown entry, ignored"
    fi
    ;;
  UserPromptSubmit)
    # Heartbeat: proves the session is alive, heals any spurious end mark, and
    # refreshes the process identity so a rebuilt entry counts as live.
    if valid "$entry"; then
      commit --arg at "$now" --argjson pid "${cpid:-0}" \
             --arg boot "${boot:-}" --arg stime "${stime:-}" \
             --argjson h "$(jq -nc --argjson o "$(other_holders)" --argjson s "$self" '$o + $s')" \
        '.last_seen = $at | .ended_at = null | .end_reason = null
         | if $pid > 1 then .pid = $pid | .boot_id = $boot | .pid_starttime = $stime
                            | .holders = $h
           else . end' "$entry"
    else
      [ -e "$entry" ] && msg="rebuilt unreadable entry from heartbeat" ||
        msg="recreated from heartbeat"
      write_full
      log "$msg"
    fi
    ;;
  *)
    # A second process resuming an open session joins its holders rather than
    # replacing the first.
    others=$(other_holders)
    write_full "$others"
    if [ "$others" = "[]" ]; then
      log "registered"
    else
      log "registered, also open in pid $(jq -r 'map(.pid) | join(",")' <<<"$others")"
    fi
    ;;
esac
exit 0
