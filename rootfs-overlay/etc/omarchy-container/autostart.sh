#!/usr/bin/env bash
# =============================================================================
# /etc/omarchy-container/autostart.sh — session autostart
# =============================================================================
#
# Run once by the compositor, inside the session, as user omarchy:
#   Hyprland  exec-once = /etc/omarchy-container/autostart.sh
#   sway      exec /etc/omarchy-container/autostart.sh
#
# It exists so that a fresh VNC connection shows a working desktop rather than
# an empty flat-colour rectangle — which is indistinguishable, to the eye, from
# the grey-screen capture failure documented in RESEARCH.md §7.
#
# Extend it without editing it: drop executables into
# /etc/omarchy-container/autostart.d/ (image-wide) or write
# ~/.config/omarchy-container/autostart.sh (per user). Both run before the
# terminal opens.
#
# This script MUST return. The compositor does not wait for it, but a hung
# autostart holds a process the supervisor will reap and report on. Anything
# long-running goes in the background.
# =============================================================================
set -uo pipefail

log() { printf '[autostart] %s\n' "$*" >&2; }

# The compositor exports these; if the script is run by hand they may be absent.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
TERMINAL="${OMARCHY_TERMINAL:-foot}"

# --- image-wide hooks --------------------------------------------------------
if [[ -d /etc/omarchy-container/autostart.d ]]; then
  for hook in /etc/omarchy-container/autostart.d/*; do
    [[ -x "$hook" ]] || continue
    log "running hook ${hook}"
    "$hook" || log "hook ${hook} exited ${?}"
  done
fi

# --- per-user hook -----------------------------------------------------------
user_hook="${HOME:-/home/omarchy}/.config/omarchy-container/autostart.sh"
if [[ -x "$user_hook" ]]; then
  log "running user hook ${user_hook}"
  "$user_hook" || log "user hook exited ${?}"
fi

# --- portals -----------------------------------------------------------------
# Only under Hyprland: xdg-desktop-portal-hyprland is what makes screen sharing,
# file pickers and the screenshot tooling work. It normally arrives via a
# systemd user unit, which does not exist here, so start it by hand. It is a
# child of the compositor, so it dies with the session; the supervisor neither
# knows nor cares about it.
if [[ "${XDG_CURRENT_DESKTOP:-}" == "Hyprland" ]]; then
  if [[ -x /usr/lib/xdg-desktop-portal-hyprland ]]; then
    log "starting xdg-desktop-portal-hyprland"
    /usr/lib/xdg-desktop-portal-hyprland >/dev/null 2>&1 &
    # The generic portal must come up after the backend has claimed its bus name.
    if [[ -x /usr/lib/xdg-desktop-portal ]]; then
      ( sleep 2; exec /usr/lib/xdg-desktop-portal >/dev/null 2>&1 ) &
    fi
  fi
fi

# --- something to look at ----------------------------------------------------
if command -v "$TERMINAL" >/dev/null 2>&1; then
  log "opening ${TERMINAL}"
  # foot takes the command positionally: `foot <cmd>`. Most other terminals
  # (alacritty, xterm, kitty) want `-e <cmd>`. Getting this wrong opens a plain
  # shell instead of the welcome screen, which is a confusing way to fail.
  case "${TERMINAL##*/}" in
    foot) "$TERMINAL" /usr/local/bin/omarchy-container-welcome >/dev/null 2>&1 & ;;
    *)    "$TERMINAL" -e /usr/local/bin/omarchy-container-welcome >/dev/null 2>&1 & ;;
  esac
else
  log "terminal '${TERMINAL}' not found; the desktop will come up empty"
fi

exit 0
