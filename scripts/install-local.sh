#!/usr/bin/env bash
# Builds sideload from this checkout and installs it for the owner (README "Updating the installed build"): the CLI at
# ~/.local/bin/sideload, which the launchd agents run, and the menu bar app at ~/Applications/SideloadMenu.app.
#
# Owner-run: agents never run it (it replaces the installed build and restarts the menu bar app). It never loads,
# unloads or reloads a launchd agent. --kick starts one run of the refresh agent now, a normal `refresh --auto` that
# renews whatever is due. --check installs nothing and only reads the agents' state and the last refresh run.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install-local.sh [--kick] [--allow-dirty]
       scripts/install-local.sh --check

  (no flags)     build from a clean main, install the CLI and the menu bar app, show the agents' state
  --kick         also start one refresh agent run now and wait for it (it renews whatever is due)
  --allow-dirty  install from another branch or uncommitted changes
  --check        install nothing: show the agents' state and the last refresh run
EOF
}

kick=false
allow_dirty=false
check_only=false
while (($#)); do
  case "$1" in
  --kick) kick=true ;;
  --allow-dirty) allow_dirty=true ;;
  --check) check_only=true ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "install-local.sh: unknown option $1" >&2
    usage >&2
    exit 2
    ;;
  esac
  shift
done
if $check_only && { $kick || $allow_dirty; }; then
  echo "install-local.sh: --check takes no other flag" >&2
  exit 2
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "install-local.sh: Apple Silicon (arm64) only; got $(uname -m)" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

# The agents and the app use the default home, whatever this shell's SIDELOAD_HOME says.
home="$HOME/.sideload"
cli="$HOME/.local/bin/sideload"
app_dest="$HOME/Applications/SideloadMenu.app"
domain="gui/$(id -u)"
refresh_label="io.github.dividedby.sideload.refresh"
status_label="io.github.dividedby.sideload.status"
refresh_log="$home/logs/refresh.jsonl"
# The refresh agent's StartInterval (RefreshAgent.swift).
refresh_interval=1800
kick_timeout=900

log() { echo "install-local.sh: $*" >&2; }
die() {
  log "$*"
  exit 1
}

agent_loaded() { launchctl print "$domain/$1" >/dev/null 2>&1; }

# One top-level field of `launchctl print` (one tab deep: "runs", "job state", ...); empty when absent. awk reads all
# of its input, so launchctl never gets SIGPIPE under pipefail.
agent_field() {
  launchctl print "$domain/$1" 2>/dev/null |
    awk -F' = ' -v f="$2" '!found && $1 == "\t" f { print $2; found = 1 }'
}

last_run_line() {
  [[ -f "$refresh_log" ]] || return 0
  tail -n 400 "$refresh_log" | grep '"event":"run"' | tail -n 1 || true
}

# The first occurrence of one scalar field of a log line ("ok", "renewed", ...), unquoted; empty when absent.
line_field() {
  grep -o "\"$2\":[^,}]*" <<<"$1" | head -n 1 | sed 's/^[^:]*://; s/"//g' || true
}

# Epoch seconds of a log line's "ts" (UTC, ISO 8601); empty when the line has none.
line_epoch() {
  local ts
  ts="$(line_field "$1" ts)"
  [[ -n "$ts" ]] || return 0
  ts="${ts%Z}"
  date -j -u -f '%Y-%m-%dT%H:%M:%S' "${ts%%.*}" +%s 2>/dev/null || true
}

local_time() { date -r "$1" '+%-I:%M %p %Z'; }

# "at 7:57 PM CST: ok true, renewed 0, failed 0" for a run line: counts only, as the log keeps them.
run_summary() {
  local epoch
  epoch="$(line_epoch "$1")"
  echo "${epoch:+at $(local_time "$epoch"): }ok $(line_field "$1" ok), renewed $(line_field "$1" renewed), failed $(line_field "$1" failed)"
}

# Prints both agents' state and the last refresh run; returns 1 when launchd could not start an agent.
report_agents() {
  local label name runs state code reason program line agents_ok=true
  for label in "$refresh_label" "$status_label"; do
    name="${label##*.}"
    if ! agent_loaded "$label"; then
      log "$name agent: not loaded (README \"Turning on auto-refresh\" / \"Turning on expiry notifications\")"
      continue
    fi
    runs="$(agent_field "$label" runs)"
    state="$(agent_field "$label" "job state")"
    code="$(agent_field "$label" "last exit code")"
    reason="$(agent_field "$label" "last exit reason")"
    log "$name agent: runs ${runs:-?}, job state ${state:-?}, last exit code ${code:-?}${reason:+, last exit reason $reason}"
    if [[ "$state" == "spawn failed" || "$reason" == *CODESIGNING* ]]; then
      agents_ok=false
      log "  launchd could not start the new binary. Run: launchctl kickstart $domain/$label"
      log "  If that fails too: run its bootout line, then its install lines, from ~/.local/bin/sideload $name --print-agent"
    fi
    program="$(agent_field "$label" program)"
    if [[ -n "$program" && "$program" != "$cli" ]]; then
      log "  note: this agent runs $program, not $cli"
    fi
  done
  line="$(last_run_line)"
  [[ -z "$line" ]] || log "last refresh run $(run_summary "$line")"
  $agents_ok
}

# A busy operation lock or a running refresh agent stops here, so a Renew, Add app or renewal is never cut off. The
# probe holds the lock for an instant only. Called before the build and again before each replace; $1 says what is
# already installed by then.
ensure_idle() {
  local done_note="${1:-nothing has been installed}" probe=0
  if [[ -e "$home/.op.lock" ]]; then
    perl -MFcntl=:flock -e 'open(my $l, ">>", $ARGV[0]) or exit 2; flock($l, LOCK_EX | LOCK_NB) or exit 1; exit 0' \
      "$home/.op.lock" || probe=$?
    case "$probe" in
    0) ;;
    1) die "a sideload operation holds ~/.sideload/.op.lock (the menu bar app, the refresh agent or the lab); $done_note; re-run when it finishes" ;;
    *) die "could not open ~/.sideload/.op.lock to check it; $done_note" ;;
    esac
  fi
  if agent_loaded "$refresh_label" && [[ "$(agent_field "$refresh_label" state)" == "running" ]]; then
    die "the refresh agent is running; $done_note; re-run when it finishes"
  fi
}

if $check_only; then
  report_agents
  exit $?
fi

# Preflight.
branch="$(git symbolic-ref --quiet --short HEAD || echo "(detached)")"
tree_changes="$(git status --porcelain)"
if ! $allow_dirty; then
  [[ "$branch" == "main" ]] || die "on $branch, not main; switch to main or pass --allow-dirty"
  [[ -z "$tree_changes" ]] || die "the working tree has uncommitted changes; commit or stash them, or pass --allow-dirty"
fi
commit="$(git rev-parse --short HEAD)"
dirty=""
[[ -z "$tree_changes" ]] || dirty=" (with uncommitted changes)"
if $kick && ! agent_loaded "$refresh_label"; then
  die "--kick: the refresh agent is not loaded (README \"Turning on auto-refresh\")"
fi
ensure_idle

log "building $commit on $branch$dirty (release, arm64)"
swift build -c release --arch arm64 >&2
bin="$(swift build -c release --arch arm64 --show-bin-path)"
[[ -x "$bin/sideload" ]] || die "$bin/sideload was not built"
log "building SideloadMenu.app"
scripts/make-app.sh >/dev/null

# The CLI goes in as a new file (copy beside it, then rename over it): copying over a signed binary in place can get it
# killed by macOS (README "Turning on auto-refresh"), and the rename leaves no moment without a binary.
ensure_idle
log "installing $cli"
mkdir -p "$(dirname "$cli")"
staged="$cli.new.$$"
trap 'rm -rf "$staged"' EXIT
cp "$bin/sideload" "$staged"
mv -f "$staged" "$cli"
cmp -s "$bin/sideload" "$cli" || die "$cli does not match the build"
env -u SIDELOAD_HOME "$cli" status >/dev/null 2>&1 ||
  die "$cli status did not answer ok; run it to see the errors"

ensure_idle "the new CLI is installed, the app is not"
staged="$app_dest.new.$$"
mkdir -p "$(dirname "$app_dest")"
ditto .build/app/SideloadMenu.app "$staged"
if pkill -x SideloadMenu; then
  log "quitting the running SideloadMenu"
  for _ in {1..20}; do
    pgrep -x SideloadMenu >/dev/null || break
    sleep 0.5
  done
  ! pgrep -x SideloadMenu >/dev/null || die "SideloadMenu did not quit within 10 s; quit it from its panel and re-run"
fi
log "installing $app_dest"
rm -rf "$app_dest"
mv "$staged" "$app_dest"
trap - EXIT
open "$app_dest"

next_note=""
kick_ok=true
if $kick; then
  before="$(agent_field "$refresh_label" runs)"
  kicked_at="$(date +%s)"
  log "starting one refresh agent run (it renews whatever is due)"
  waited=0
  finished=false
  if ! launchctl kickstart "$domain/$refresh_label"; then
    kick_ok=false
    waited=$kick_timeout
    log "launchctl kickstart failed; see the agent state below"
  fi
  while ((waited < kick_timeout)); do
    sleep 2
    waited=$((waited + 2))
    if [[ "$(agent_field "$refresh_label" runs)" != "$before" && "$(agent_field "$refresh_label" state)" != "running" ]]; then
      finished=true
      break
    fi
    if ((waited % 60 == 0)); then log "still running ($((waited / 60)) min)"; fi
  done
  if ! $finished; then
    $kick_ok && log "the run has not finished after $((kick_timeout / 60)) min; check later with scripts/install-local.sh --check"
  else
    line="$(last_run_line)"
    epoch="$(line_epoch "$line")"
    if [[ -z "$epoch" ]] || ((epoch < kicked_at - 5)); then
      kick_ok=false
      log "the kicked run logged no run line (the newest is older); see ~/.sideload/logs/refresh.jsonl and launchd-refresh.err"
    elif [[ "$(line_field "$line" ok)" == "true" ]]; then
      log "kicked run finished: $(run_summary "$line")"
    else
      kick_ok=false
      log "kicked run did not log ok: ${line:+$(run_summary "$line")}; see ~/.sideload/logs/refresh.jsonl and launchd-refresh.err"
    fi
  fi
elif agent_loaded "$refresh_label"; then
  epoch="$(line_epoch "$(last_run_line)")"
  if [[ -n "$epoch" ]]; then
    next=$((epoch + refresh_interval))
    now="$(date +%s)"
    while ((next < now)); do next=$((next + refresh_interval)); done
    next_note="the next timed refresh run, about $(local_time "$next"), is the first on the new binary"
  else
    next_note="the next timed refresh run (every $((refresh_interval / 60)) min) is the first on the new binary"
  fi
fi

log "installed $commit$dirty: $cli and $app_dest"
agents_ok=true
report_agents || agents_ok=false
[[ -z "$next_note" ]] || log "$next_note; then run scripts/install-local.sh --check"
$agents_ok && $kick_ok
