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

log() { echo "install-local.sh: $*" >&2; }
die() {
  log "$*"
  exit 1
}

agent_loaded() { launchctl print "$domain/$1" >/dev/null 2>&1; }

# One top-level field of `launchctl print` ("runs", "job state", "last exit code", ...); empty when absent.
agent_field() {
  launchctl print "$domain/$1" 2>/dev/null |
    awk -F' = ' -v f="$2" '$1 ~ "^[[:space:]]*" f "$" { print $2; exit }'
}

last_run_line() {
  [[ -f "$refresh_log" ]] || return 0
  tail -n 400 "$refresh_log" | grep '"event":"run"' | tail -n 1 || true
}

# Epoch seconds of a log line's "ts" (UTC, ISO 8601); empty when the line has none.
line_epoch() {
  local ts
  ts="$(sed -n 's/.*"ts":"\([^"]*\)".*/\1/p' <<<"$1")"
  [[ -n "$ts" ]] || return 0
  ts="${ts%Z}"
  date -j -u -f '%Y-%m-%dT%H:%M:%S' "${ts%%.*}" +%s 2>/dev/null || true
}

local_time() { date -r "$1" '+%-I:%M %p %Z'; }

report_agents() {
  local label name runs state code reason line epoch healthy=true
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
      healthy=false
      log "  launchd could not start the new binary. Run: launchctl kickstart $domain/$label"
      log "  If that fails too: run its bootout line, then its install lines, from ~/.local/bin/sideload $name --print-agent"
    fi
    local program
    program="$(agent_field "$label" program)"
    if [[ -n "$program" && "$program" != "$cli" ]]; then
      log "  note: this agent runs $program, not $cli"
    fi
  done
  line="$(last_run_line)"
  if [[ -n "$line" ]]; then
    epoch="$(line_epoch "$line")"
    log "last refresh run${epoch:+ at $(local_time "$epoch")}: $line"
  fi
  $healthy
}

if $check_only; then
  report_agents
  exit $?
fi

# --- Preflight -----------------------------------------------------------------------------------------------------
branch="$(git symbolic-ref --quiet --short HEAD || echo "(detached)")"
if ! $allow_dirty; then
  [[ "$branch" == "main" ]] || die "on $branch, not main; switch to main or pass --allow-dirty"
  [[ -z "$(git status --porcelain)" ]] || die "the working tree has uncommitted changes; commit or stash them, or pass --allow-dirty"
fi
commit="$(git rev-parse --short HEAD)"
dirty=""
[[ -z "$(git status --porcelain)" ]] || dirty=" (with uncommitted changes)"

# Replacing the app mid-action would kill a running Renew or Add app, so a busy operation lock stops here.
if [[ -e "$home/.op.lock" ]]; then
  perl -MFcntl=:flock -e 'open(my $l, ">>", $ARGV[0]) or exit 2; flock($l, LOCK_EX | LOCK_NB) or exit 1; exit 0' \
    "$home/.op.lock" ||
    die "a sideload operation holds ~/.sideload/.op.lock (the menu bar app, the refresh agent or the lab); try again when it finishes"
fi
if agent_loaded "$refresh_label" && [[ "$(agent_field "$refresh_label" state)" == "running" ]]; then
  die "the refresh agent is running; try again when it finishes"
fi

# --- CLI -----------------------------------------------------------------------------------------------------------
log "building $commit on $branch$dirty (release, arm64)"
swift build -c release --arch arm64
bin="$(swift build -c release --arch arm64 --show-bin-path)"
[[ -x "$bin/sideload" ]] || die "$bin/sideload was not built"

# rm, then copy: copying over a signed binary in place can get it killed by macOS (README "Turning on auto-refresh").
log "installing $cli"
mkdir -p "$(dirname "$cli")"
rm -f "$cli"
cp "$bin/sideload" "$cli"
cmp -s "$bin/sideload" "$cli" || die "$cli does not match the build"
env -u SIDELOAD_HOME "$cli" status >/dev/null 2>&1 ||
  die "$cli status did not answer ok; run it to see the errors"

# --- Menu bar app --------------------------------------------------------------------------------------------------
log "building SideloadMenu.app"
scripts/make-app.sh >/dev/null
if pkill -x SideloadMenu; then
  log "quitting the running SideloadMenu"
  for _ in {1..20}; do
    pgrep -x SideloadMenu >/dev/null || break
    sleep 0.5
  done
  ! pgrep -x SideloadMenu >/dev/null || die "SideloadMenu did not quit within 10 s; quit it from its panel and re-run"
fi
log "installing $app_dest"
mkdir -p "$(dirname "$app_dest")"
rm -rf "$app_dest"
ditto .build/app/SideloadMenu.app "$app_dest"
open "$app_dest"

# --- Agents --------------------------------------------------------------------------------------------------------
next_note=""
if $kick; then
  agent_loaded "$refresh_label" || die "--kick: the refresh agent is not loaded"
  before="$(agent_field "$refresh_label" runs)"
  log "starting one refresh agent run (it renews whatever is due)"
  launchctl kickstart "$domain/$refresh_label"
  waited=0
  while ((waited < 900)); do
    sleep 2
    waited=$((waited + 2))
    if [[ "$(agent_field "$refresh_label" runs)" != "$before" && "$(agent_field "$refresh_label" state)" != "running" ]]; then
      break
    fi
    ((waited % 60 == 0)) && log "still running ($((waited / 60)) min)"
  done
  if ((waited >= 900)); then
    log "the run has not finished after 15 min; check later with scripts/install-local.sh --check"
  fi
else
  line="$(last_run_line)"
  epoch="$(line_epoch "$line")"
  if [[ -n "$epoch" ]]; then
    next=$((epoch + 1800))
    now="$(date +%s)"
    while ((next < now)); do next=$((next + 1800)); done
    next_note="the next timed refresh run, about $(local_time "$next"), is the first on the new binary"
  fi
fi

log "installed $commit$dirty: $cli and $app_dest"
healthy=true
report_agents || healthy=false
if [[ -n "$next_note" ]]; then
  log "$next_note; then run scripts/install-local.sh --check"
fi
$healthy
