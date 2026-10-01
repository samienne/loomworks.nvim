#!/usr/bin/env bash
# Workspace daemon lifetime end-to-end (spec §19.2, §19.6–§19.11) with REAL
# processes of the fused `lw` binary, on Linux, macOS and Windows:
#   - `lw daemon restart` starts a detached daemon that outlives lw;
#   - piping lw's output (`… | cat`) returns at once: the daemon holds none
#     of lw's standard handles (the 2m56s spike bug, DAEMON.md §6);
#   - `lw daemon stop` ends the process (asserted by pid) and removes the
#     handle, lock and (POSIX) socket;
#   - concurrent `lw daemon run`s leave exactly one daemon (the others exit 3);
#   - `lw daemon kill`, and a suspended daemon: `stop` reports it not
#     responding, `stop --force` recovers (POSIX: SIGSTOP);
#   - no daemon process is left running at the end.
#
#   LW=<path to lw> bash scripts/ci/daemon-e2e.sh
#
# Runs with an isolated data dir (trust key, runtime state) and config dir.
set -u

LW="${LW:-lw}"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) os=windows ;;
  Darwin) os=macos ;;
  *) os=linux ;;
esac

PASS=0; FAIL=0
ok()  { printf '  ok  : %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
say() { printf '\n=== %s ===\n' "$*"; }

TMP=$(mktemp -d)
native() { if [ "$os" = windows ]; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
export LOOMWORKS_DATA_DIR="$(native "$TMP/data")"
export XDG_CONFIG_HOME="$TMP/config" APPDATA="$(native "$TMP/config")"
unset LOOMWORKS_RUNTIME LOOMWORKS_NO_DAEMON CI LW_ROOT || true

WS="$TMP/ws"
mkdir -p "$WS"
printf '{"projects":{}}\n' > "$WS/loomworks.json"
LOCK="$WS/.nvim/loomworks.daemon.lock"
HANDLE="$WS/.nvim/loomworks.daemon.json"

lw() { (cd "$WS" && "$LW" "$@"); }
pid_of() { sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -1; }
alive() {
  if [ "$os" = windows ]; then
    tasklist //FI "PID eq $1" 2>/dev/null | grep -q " $1 "
  else
    kill -0 "$1" 2>/dev/null
  fi
}
wait_gone() { local i=0; while alive "$1" && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; ! alive "$1"; }
force_kill() {
  if [ "$os" = windows ]; then taskkill //F //T //PID "$1" >/dev/null 2>&1; else kill -9 "$1" 2>/dev/null; fi
}
now_ms() { python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo $(( $(date +%s) * 1000 )); }

ALL_PIDS=""
track() { [ -n "$1" ] && ALL_PIDS="$ALL_PIDS $1"; }
cleanup() {
  for p in $ALL_PIDS; do alive "$p" && force_kill "$p"; done
  rm -rf "$TMP"
}
trap cleanup EXIT

say "restart starts a detached daemon; a pipeline returns at once"
t0=$(now_ms)
out=$(lw daemon restart | cat)
t1=$(now_ms)
pid=$(pid_of "$LOCK"); track "$pid"
if [ -n "$pid" ] && alive "$pid"; then ok "daemon pid $pid running ($out)"; else bad "no daemon after restart: $out"; fi
if [ $((t1 - t0)) -lt 15000 ]; then ok "lw daemon restart | cat returned in $((t1 - t0)) ms"; else bad "restart | cat took $((t1 - t0)) ms (inherited std handles?)"; fi
sleep 1
if alive "$pid"; then ok "the daemon outlived lw"; else bad "the daemon died with lw"; fi
st=$(lw daemon status | cat)
case "$st" in *"answers      1 client"*) ok "daemon answers status" ;; *) bad "status: $st" ;; esac
row=$(lw status | cat)
case "$row" in *"Runtime"*"daemon pid $pid"*) ok "Runtime row names the daemon" ;; *) bad "status row: $row" ;; esac
if [ "$os" != windows ]; then
  sock=$(sed -n 's/.*"endpoint":"\([^"]*\)".*/\1/p' "$HANDLE")
  if [ -S "$sock" ]; then ok "socket $sock (${#sock} bytes)"; else bad "no socket at $sock"; fi
  dir=$(dirname "$sock")
  mode=$(stat -c %a "$dir" 2>/dev/null || stat -f %Lp "$dir")
  if [ "$mode" = 700 ]; then ok "socket dir mode 0700"; else bad "socket dir mode $mode"; fi
fi

say "stop ends the process and removes its files"
lw daemon stop || bad "stop failed"
if wait_gone "$pid"; then ok "pid $pid gone"; else bad "pid $pid still running after stop"; fi
[ ! -e "$LOCK" ] && [ ! -e "$HANDLE" ] && ok "lock and handle removed" || bad "lock/handle left behind"
if [ "$os" != windows ] && [ -n "${sock:-}" ]; then [ ! -e "$sock" ] && ok "socket removed" || bad "socket left behind"; fi
out=$(lw daemon stop)
case "$out" in *"no workspace daemon is running"*) ok "stop with none running" ;; *) bad "stop again: $out" ;; esac

say "concurrent launches: exactly one daemon"
WSN=$(native "$WS")
pids=""
for i in 1 2 3; do (cd "$TMP" && exec "$LW" daemon run --root "$WSN" >/dev/null 2>&1) & pids="$pids $!"; done
sleep 6
running=0; for p in $pids; do if kill -0 "$p" 2>/dev/null; then running=$((running + 1)); fi; done
dpid=$(pid_of "$LOCK"); track "$dpid"
held=0
for p in $pids; do
  if ! kill -0 "$p" 2>/dev/null; then wait "$p"; [ $? -eq 3 ] && held=$((held + 1)); fi
done
if [ "$held" -eq 2 ] && [ -n "$dpid" ] && alive "$dpid"; then ok "one daemon (pid $dpid), two exited with status 3"; else bad "held=$held running=$running daemon=$dpid"; fi

say "kill stops it without asking"
out=$(lw daemon kill 2>&1)
if wait_gone "$dpid"; then ok "killed: $out"; else bad "kill left pid $dpid: $out"; fi
[ ! -e "$LOCK" ] && [ ! -e "$HANDLE" ] && ok "files cleared after kill" || bad "files left after kill"
for p in $pids; do wait "$p" 2>/dev/null; done

if [ "$os" != windows ]; then
  say "a suspended daemon: stop reports it, stop --force recovers"
  lw daemon restart >/dev/null
  spid=$(pid_of "$LOCK"); track "$spid"
  kill -STOP "$spid"
  touch -t 200001010000 "$LOCK"
  out=$(lw daemon stop 2>&1); code=$?
  case "$out" in *"not responding"*) [ $code -eq 1 ] && ok "reported not responding" || bad "exit $code" ;; *) bad "stop on hung: $out" ;; esac
  alive "$spid" && ok "nothing killed by plain stop" || bad "plain stop killed it"
  out=$(lw daemon stop --force 2>&1) || bad "stop --force failed: $out"
  if wait_gone "$spid"; then ok "stop --force recovered"; else bad "suspended pid $spid survived"; fi
fi

say "no daemon left running"
left=""
for p in $ALL_PIDS; do alive "$p" && left="$left $p"; done
[ -z "$left" ] && ok "none" || bad "still running:$left"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
