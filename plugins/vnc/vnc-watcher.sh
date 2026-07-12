#!/bin/sh
# VNC watcher: detects Camoufox's Xvfb display and attaches x11vnc + noVNC.
# Handles browser restarts, x11vnc crashes, and display changes.
#
# Env vars (set by the VNC plugin):
#   VNC_PASSWORD    If set, x11vnc requires this password
#   VIEW_ONLY       "1" for view-only mode
#   VNC_PORT        VNC port (default: 5900)
#   NOVNC_PORT      noVNC websocket port (default: 6080)
#   VNC_RESOLUTION  Resolution string (default: 1920x1080x24)
#   VNC_BIND        Bind address for websockify (default: 127.0.0.1)

VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1920x1080x24}"

log() { printf '[vnc-watcher] %s\n' "$*" >&2; }

CURRENT_DISPLAY=""
X11VNC_PID=""

# --- Display detection with 3 fallbacks ---
detect_display() {
# Fallback 1: scan Xvfb argv for display number
  _display=$(ps -eo args= 2>/dev/null | grep '[X]vfb' | grep -oP ':\K[0-9]+' | head -1)
  if [ -n "$_display" ]; then
    echo ":${_display}"
    return 0
  fi

# Fallback 2: check /tmp/.X*-lock files
  for _lock in /tmp/.X*-lock; do
    if [ -f "$_lock" ]; then
      _num=$(basename "$_lock" | sed 's/^\.X//')
      echo ":${_num}"
      return 0
    fi
  done

# Fallback 3: check /tmp/.X11-unix/ sockets
  for _sock in /tmp/.X11-unix/X*; do
    if [ -e "$_sock" ]; then
      _num=$(basename "$_sock" | sed 's/^X//')
      echo ":${_num}"
      return 0
    fi
  done

  return 1
}

# --- Prepare password file ---
PASSFILE=""
if [ -n "${VNC_PASSWORD:-}" ]; then
  mkdir -p /tmp/.vnc
  x11vnc -storepasswd "$VNC_PASSWORD" /tmp/.vnc/passwd >/dev/null 2>&1
  PASSFILE="/tmp/.vnc/passwd"
  log "x11vnc: password protected"
else
  log "x11vnc: NO password (bind $NOVNC_PORT to 127.0.0.1 on host + SSH tunnel)"
fi

# --- Start noVNC (websockify) ---
NOVNC_DIR="/usr/share/novnc"
if [ ! -d "$NOVNC_DIR" ]; then
  log "ERROR: $NOVNC_DIR not found; noVNC cannot start"
  exit 1
fi
VNC_BIND="${VNC_BIND:-127.0.0.1}"
log "Starting noVNC (websockify) on $VNC_BIND:$NOVNC_PORT -> 127.0.0.1:$VNC_PORT"
websockify --web "$NOVNC_DIR" "$VNC_BIND:$NOVNC_PORT" "127.0.0.1:$VNC_PORT" >/var/log/novnc.log 2>&1 &

log "VNC watcher started -- will attach x11vnc when Camoufox's Xvfb appears"

while true; do
# Heartbeat: clear stale x11vnc PID so watcher re-attaches after crash
  if [ -n "$X11VNC_PID" ] && ! kill -0 "$X11VNC_PID" 2>/dev/null; then
    log "x11vnc (pid=$X11VNC_PID) died, clearing for re-attach"
    X11VNC_PID=""
    CURRENT_DISPLAY=""
  fi

# Detect current display (3 fallbacks)
  FOUND=$(detect_display)

  if [ -z "$FOUND" ]; then
    sleep 2
    continue
  fi

# Display changed or not yet attached
  if [ "$FOUND" != "$CURRENT_DISPLAY" ]; then
    log "Display $FOUND detected, attaching x11vnc..."

    # Poll xdpyinfo - wait up to 5s for X to accept connections
    for _wait in 1 2 3 4 5; do
      if xdpyinfo -display "$FOUND" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    # Kill any existing x11vnc
    killall x11vnc 2>/dev/null || true
    sleep 0.5

    # Build x11vnc args (NO -bg flag so we see failures)
    X11VNC_ARGS="-display $FOUND -forever -shared -rfbport $VNC_PORT -noxdamage -quiet"
    [ "${VIEW_ONLY:-0}" = "1" ] && X11VNC_ARGS="$X11VNC_ARGS -viewonly"
    if [ -n "$PASSFILE" ]; then
      X11VNC_ARGS="$X11VNC_ARGS -rfbauth $PASSFILE"
    else
      X11VNC_ARGS="$X11VNC_ARGS -nopw"
    fi

    # Start x11vnc in background, capture PID
    # shellcheck disable=SC2086
    x11vnc $X11VNC_ARGS &
    _newpid=$!

    # Wait briefly and verify it actually started
    sleep 1
    if kill -0 "$_newpid" 2>/dev/null; then
      X11VNC_PID="$_newpid"
      CURRENT_DISPLAY="$FOUND"
      log "x11vnc started (pid=$X11VNC_PID) on DISPLAY=$FOUND"
    else
      log "x11vnc failed to start on DISPLAY=$FOUND, clearing for retry"
      CURRENT_DISPLAY=""
    fi
  fi

  sleep 3
done
