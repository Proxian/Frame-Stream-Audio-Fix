#!/bin/bash
# frame-stream-audio-fix.sh - UNOFFICIAL workaround for Steam Frame audio dying
# while streaming from a PC (volume popup, then silence until you restart the stream).
#
# Cause: during PC streaming the Frame's PipeWire (audio server) gets SIGKILLed by
# the kernel's real-time CPU limit (RLIMIT_RTTIME, 200 ms). PipeWire restarts, but
# the stream's audio never reconnects.
#
# Fix: while a PC stream (vrlink) is running, this moves PipeWire's real-time audio
# threads to high-priority normal scheduling (the limit only applies to real-time
# threads), and puts them back to real-time when the stream ends. Standalone play
# is untouched. User-level only: no sudo, no system files changed.
#
#   bash frame-stream-audio-fix.sh install     install + start (runs at every boot)
#   bash frame-stream-audio-fix.sh status      is it running? how many PipeWire kills?
#   bash frame-stream-audio-fix.sh uninstall   remove everything (do this once Valve fixes it)

NAME=frame-stream-audio-fix
BIN="$HOME/.local/bin/$NAME"
UNIT="$HOME/.config/systemd/user/$NAME.service"
LOG="$HOME/.local/state/$NAME.log"
# Always use the real user session. In Desktop Mode, Konsole runs inside a nested
# Plasma session with XDG_RUNTIME_DIR=/run/user/<uid>/nested_plasma, which has no
# systemd user manager ("Failed to connect to user scope bus").
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
[ -S "$XDG_RUNTIME_DIR/bus" ] && export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
RK="org.freedesktop.RealtimeKit1 /org/freedesktop/RealtimeKit1 org.freedesktop.RealtimeKit1"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# vrlink renames its main thread ("vrlinkrunthread"), so match the executable path
streaming() {
  for p in $(pgrep -f vrlink); do
    [[ "$(readlink "/proc/$p/exe" 2>/dev/null)" == */vrlink ]] && return 0
  done
  return 1
}

rt_threads() {  # "pid tid prio" for every real-time thread of the PipeWire services
  for s in pipewire pipewire-pulse wireplumber; do
    p=$(systemctl --user show "$s" -p MainPID --value 2>/dev/null)
    [ "${p:-0}" -gt 0 ] || continue
    ps -L -o tid=,cls=,rtprio= -p "$p" 2>/dev/null | awk -v p="$p" '$2=="RR"||$2=="FF"{print p, $1, $3}'
  done
}

run_guard() {
  declare -A demoted
  restore_all() {
    for k in "${!demoted[@]}"; do
      p=${k%%:*}; t=${k##*:}
      [ -d "/proc/$p/task/$t" ] && busctl call $RK MakeThreadRealtimeWithPID ttu -- "$p" "$t" "${demoted[$k]}" 2>/dev/null \
        && log "restored thread $t to real-time ${demoted[$k]}"
    done
    demoted=()
  }
  trap 'restore_all; log "stopped"; exit 0' TERM INT
  log "started"
  while true; do
    if streaming; then
      while read -r p t prio; do
        # -R keeps rtkit's reset-on-fork flag (clearing it is not allowed without root)
        if chrt -o -R -p 0 "$t" 2>/dev/null; then
          busctl call $RK MakeThreadHighPriorityWithPID tti -- "$p" "$t" -11 2>/dev/null || true
          demoted["$p:$t"]=$prio
          log "stream running: moved $(cat "/proc/$p/comm" 2>/dev/null) thread $t off real-time (was $prio)"
        fi
      done < <(rt_threads)
    elif [ ${#demoted[@]} -gt 0 ]; then
      log "stream ended"; restore_all
    fi
    sleep 2 & wait $!
  done
}

case "${1:-}" in
  install)
    for c in chrt busctl pgrep systemctl; do command -v "$c" >/dev/null || { echo "missing '$c', not installing"; exit 1; }; done
    mkdir -p "$(dirname "$BIN")" "$(dirname "$UNIT")" "$(dirname "$LOG")"
    cp "$(readlink -f "$0")" "$BIN" && chmod +x "$BIN"
    cat > "$UNIT" <<EOF
[Unit]
Description=Unofficial fix: keep PipeWire from being killed during Steam Frame PC streaming
After=pipewire.service

[Service]
ExecStart=$BIN run
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload && systemctl --user enable --now "$NAME.service"
    echo "Installed and running. Check it anytime with: bash $BIN status"
    echo "Remove it with: bash $BIN uninstall" ;;
  uninstall)
    systemctl --user disable --now "$NAME.service" 2>/dev/null   # stopping restores real-time
    rm -f "$UNIT" "$BIN"
    systemctl --user daemon-reload
    echo "Removed. PipeWire is back to exactly how SteamOS ships it. (Log left at $LOG)" ;;
  status)
    echo "service: $(systemctl --user is-enabled "$NAME" 2>/dev/null || echo not-installed) / $(systemctl --user is-active "$NAME" 2>/dev/null)"
    echo "PipeWire SIGKILLs in the last 7 days: $(journalctl --user -u pipewire --since '7 days ago' --no-pager 2>/dev/null | grep -c 'status=9/KILL')"
    streaming && echo "PC stream: running" || echo "PC stream: not running"
    [ -f "$LOG" ] && { echo "last log lines:"; tail -n 5 "$LOG"; } ;;
  run) run_guard ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
