#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
REAL_USER="${SUDO_USER:-$USER}"
REAL_UID=$(id -u "$REAL_USER")
GUI_DOMAIN="gui/${REAL_UID}"
DRY_RUN=0
INCLUDE_SPOTLIGHT=0
SPOTLIGHT_ON=0
INCLUDE_EXTRAS=0
PERSIST=1
STATUS_ONLY=0

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Safely stop optional background apps/helpers without touching core macOS daemons.
Default targets: AdGuard, LogiOptionsPlus, Figma.
Persistent disable is on by default for known third-party launchd jobs.

Options:
  --spotlight       Disable Spotlight indexing and stop current Spotlight workers.
  --spotlight-on    Re-enable Spotlight indexing.
  --extras          Also stop BetterDisplay.
  --persist         Keep persistent launchd disable on (default).
  --no-persist      Disable only for the current session.
  --status          Show matching processes and exit.
  --dry-run         Print actions without executing them.
  -h, --help        Show this help.

Examples:
  ./${SCRIPT_NAME} --dry-run
  ./${SCRIPT_NAME} --spotlight
  sudo ./${SCRIPT_NAME} --spotlight --extras
EOF
}

log() {
  printf '%s\n' "$*"
}

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    eval "$@"
  fi
}

run_as_user() {
  local cmd="$1"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[dry-run] launchctl asuser %s %s\n' "$REAL_UID" "$cmd"
  else
    launchctl asuser "$REAL_UID" /bin/zsh -lc "$cmd"
  fi
}

quit_app() {
  local app_name="$1"
  run_as_user "osascript -e 'tell application id \"${app_name}\" to quit' >/dev/null 2>&1 || osascript -e 'tell application \"${app_name}\" to quit' >/dev/null 2>&1 || true"
}

kill_pattern() {
  local pattern="$1"
  local signal="${2:-TERM}"
  run "pkill -${signal} -if '$pattern' >/dev/null 2>&1 || true"
}

bootout_label() {
  local label="$1"
  run "launchctl bootout '${GUI_DOMAIN}/${label}' >/dev/null 2>&1 || true"
  if [[ $PERSIST -eq 1 ]]; then
    run "launchctl disable '${GUI_DOMAIN}/${label}' >/dev/null 2>&1 || true"
  fi
}

bootout_system_label() {
  local label="$1"
  if [[ $EUID -ne 0 ]]; then
    log "Skipping system label ${label}: requires sudo."
    return 0
  fi
  run "launchctl bootout 'system/${label}' >/dev/null 2>&1 || true"
  if [[ $PERSIST -eq 1 ]]; then
    run "launchctl disable 'system/${label}' >/dev/null 2>&1 || true"
  fi
}

enable_label() {
  local label="$1"
  run "launchctl enable '${GUI_DOMAIN}/${label}' >/dev/null 2>&1 || true"
}

enable_system_label() {
  local label="$1"
  if [[ $EUID -ne 0 ]]; then
    return 0
  fi
  run "launchctl enable 'system/${label}' >/dev/null 2>&1 || true"
}

show_status() {
  ps -axo pid,pcpu,pmem,rss,args | \
    rg -i 'Helium|Arc|ChatGPT|Adguard|Figma|BetterDisplay|Raycast|T3 Code|logi|Logitech|spotlight|corespotlight|mds|mdworker|duetexpertd|suggestd|assistantd|intelligenceplatformd|WindowServer'
}

disable_spotlight() {
  log "Disabling Spotlight indexing."
  if [[ $EUID -ne 0 ]]; then
    log "Spotlight indexing changes require sudo. Re-run with sudo for --spotlight."
    return 1
  fi

  run "mdutil -a -i off >/dev/null"
  kill_pattern '(^|/)mds($| )'
  kill_pattern '(^|/)mdworker($| )'
  kill_pattern '(^|/)mdbulkimport($| )'
  kill_pattern 'corespotlightd|managedcorespotlightd|spotlightknowledged|Spotlight'
}

enable_spotlight() {
  log "Re-enabling Spotlight indexing."
  if [[ $EUID -ne 0 ]]; then
    log "Spotlight indexing changes require sudo. Re-run with sudo for --spotlight-on."
    return 1
  fi

  run "mdutil -a -i on >/dev/null"
}

stop_logitech() {
  log "Stopping Logitech helpers."
  quit_app "com.logi.optionsplus"
  bootout_label "com.logi.cp-dev-mgr"
  bootout_label "com.logitech.LogiRightSight.Agent"
  bootout_system_label "com.logi.optionsplus.updater"
  bootout_system_label "com.logi.ghub.updater"
  kill_pattern 'logioptionsplus_agent|logioptionsplus_updater|LogiRightSight'
}

stop_adguard() {
  log "Stopping AdGuard app and helpers."
  quit_app "com.adguard.mac.adguard"
  bootout_label "com.adguard.mac.adguard.loginhelper"
  bootout_system_label "com.adguard.mac.adguard.helper"
  kill_pattern 'Adguard|adguard-nm|com\.adguard\.mac\.adguard\.helper|com\.adguard\.mac\.adguard\.network-extension'
}

stop_figma() {
  log "Stopping Figma."
  quit_app "com.figma.Desktop"
  kill_pattern 'Figma'
}

stop_betterdisplay() {
  log "Stopping BetterDisplay."
  quit_app "pro.betterdisplay.BetterDisplay"
  kill_pattern 'BetterDisplay'
}

print_manual_followup() {
  cat <<'EOF'
Manual follow-up that remains outside the script:
- AdGuard Network Extension can stay active until you disable it in:
  System Settings > General > Login Items & Extensions > Network Extensions
- Spotlight daemons may remain resident at 0% CPU even with indexing disabled. This is expected.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spotlight)
      INCLUDE_SPOTLIGHT=1
      ;;
    --spotlight-on)
      SPOTLIGHT_ON=1
      ;;
    --extras)
      INCLUDE_EXTRAS=1
      ;;
    --persist)
      PERSIST=1
      ;;
    --no-persist)
      PERSIST=0
      ;;
    --status)
      STATUS_ONLY=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ $STATUS_ONLY -eq 1 ]]; then
  show_status
  exit 0
fi

if [[ $SPOTLIGHT_ON -eq 1 ]]; then
  enable_spotlight
  enable_label "com.logi.cp-dev-mgr"
  enable_label "com.logitech.LogiRightSight.Agent"
  enable_label "com.adguard.mac.adguard.loginhelper"
  enable_system_label "com.logi.optionsplus.updater"
  enable_system_label "com.logi.ghub.updater"
  enable_system_label "com.adguard.mac.adguard.helper"
  exit 0
fi

log "User domain: ${GUI_DOMAIN}"
log "Default targets: AdGuard, LogiOptionsPlus, Figma"
if [[ $INCLUDE_EXTRAS -eq 1 ]]; then
  log "Extras enabled: BetterDisplay"
fi
if [[ $INCLUDE_SPOTLIGHT -eq 1 ]]; then
  log "Spotlight indexing changes enabled."
fi
if [[ $PERSIST -eq 1 ]]; then
  log "Persistent launchd disable enabled for matching third-party launchd jobs."
else
  log "Session-only mode enabled."
fi

stop_logitech
stop_adguard
stop_figma

if [[ $INCLUDE_EXTRAS -eq 1 ]]; then
  stop_betterdisplay
fi

if [[ $INCLUDE_SPOTLIGHT -eq 1 ]]; then
  disable_spotlight
fi

print_manual_followup
log "Done."
