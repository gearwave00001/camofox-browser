#!/bin/sh
# VNC watcher: detects Camoufox's dynamically-assigned Xvfb display and attaches
# x11vnc + noVNC to it. Handles browser restarts (re-attaches on display change).
#
# Called by the VNC plugin via child_process.spawn. Not meant to run standalone.
#
# Env vars (set by the plugin):
#   VNC_PASSWORD    If set, x11vnc requires this password
#   VIEW_ONLY       "1" for view-only mode
#   VNC_PORT        VNC port (default: 5900)
#   NOVNC_PORT      noVNC websocket port (default: 6080)

# NOTE: do NOT use set -e — the watcher must survive x11vnc failures and
# continue looping. A crashed x11vnc should trigger a retry, not kill us.

VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1920x1080x24}"

log() { printf '[vnc-watcher] %s\n' "$*" >&2; }

CURRENT_DISPLAY=""
X11VNC_PID=""

# Prepare password file if requested
PASSFILE=""
if [ -n "${VNC_PASSWORD:-}" ]; then
  mkdir -p /tmp/.vnc
  x11vnc -storepasswd "$VNC_PASSWORD" /tmp/.vnc/passwd >/dev/null 2>&1
  PASSFILE="/tmp/.vnc/passwd"
  log "x11vnc: password protected"
else
  log "x11vnc: NO password (bind $NOVNC_PORT to $VNC_BIND on host)"
fi

# Start noVNC (websockify) -- proxies to x11vnc regardless of whether it's up yet
NOVNC_DIR="/usr/share/novnc"
if [ ! -d "$NOVNC_DIR" ]; then
  log "ERROR: $NOVNC_DIR not found; noVNC cannot start"
  exit 1
fi
VNC_BIND="${VNC_BIND:-127.0.0.1}"
log "Starting noVNC (websockify) on $VNC_BIND:$NOVNC_PORT -> 127.0.0.1:$VNC_PORT"
websockify --web "$NOVNC_DIR" "$VNC_BIND:$NOVNC_PORT" "127.0.0.1:$VNC_PORT" >/var/log/novnc.log 2>&1 &

# detect_display — tries multiple methods to find the Xvfb display number.
#
# Camoufox's VirtualDisplay class launches Xvfb with -displayfd 3 (dynamic
# display assignment), so the command line looks like:
#   Xvfb -displayfd 3 -screen 0 1920x1080x24 ...
# There is NO display number in argv, so the original awk-only approach
# (/\/Xvfb :[0-9]+/) never matched. We fall back to filesystem detection.
#
# NOTE: avoid 'local' — #!/bin/sh is dash on Ubuntu, not bash.
detect_display() {
  # Method 1: Xvfb with hardcoded :N in argv (original method)
  _found=$(ps -eo args= 2>/dev/null | awk -v res="$VNC_RESOLUTION" '
    /\/Xvfb / && index($0, res) {
      for (i=1;i<=NF;i++) if ($i ~ /^:[0-9]+$/) { print $i; exit }
    }
  ' | head -1)
  if [ -n "$_found" ]; then
    echo "$_found"
    return
  fi

  # Method 2: /tmp/.X*-lock files (works with -displayfd mode)
  for _lock in /tmp/.X*-lock; do
    if [ -f "$_lock" ]; then
      _num=$(basename "$_lock" | sed 's/^\..*X//')
      echo ":$_num"
      return
    fi
  done

  # Method 3: /tmp/.X11-unix/X* sockets
  for _sock in /tmp/.X11-unix/X*; do
    if [ -S "$_sock" ] || [ -e "$_sock" ]; then
      _num=$(basename "$_sock" | sed 's/^X//')
      echo ":$_num"
      return
    fi
  done
}

log "VNC watcher started -- will attach x11vnc when Camoufox's Xvfb appears"

while true; do
  # HEARTBEAT: check if x11vnc is still alive. If it died (e.g. XIO error
  # after the X display was torn down), clear state so we re-attach next loop.
  if [ -n "$X11VNC_PID" ]; then
    if ! kill -0 "$X11VNC_PID" 2>/dev/null; then
      log "x11vnc (pid=$X11VNC_PID) died, clearing for re-attach"
      X11VNC_PID=""
      CURRENT_DISPLAY=""
    fi
  fi

  FOUND=$(detect_display)

  if [ -n "$FOUND" ] && [ "$FOUND" != "$CURRENT_DISPLAY" ]; then
    # New or changed display -- (re)attach x11vnc
    if [ -n "$X11VNC_PID" ] && kill -0 "$X11VNC_PID" 2>/dev/null; then
      log "Camoufox display changed ($CURRENT_DISPLAY -> $FOUND), restarting x11vnc"
      kill "$X11VNC_PID" 2>/dev/null || true
      sleep 0.5
    fi

    CURRENT_DISPLAY="$FOUND"
    log "Attaching x11vnc to DISPLAY=$CURRENT_DISPLAY"

    # Wait for Xvfb to fully initialize. The socket may exist but the X server
    # might not accept connections yet — x11vnc would crash with "caught XIO
    # error" and exit silently (masked by -bg). Poll xdpyinfo first.
    for _wait in 1 2 3 4 5; do
      if xdpyinfo -display "$CURRENT_DISPLAY" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    X11VNC_ARGS="-display $CURRENT_DISPLAY -forever -shared -rfbport $VNC_PORT -quiet -bg -o /var/log/x11vnc.log"
    [ "${VIEW_ONLY:-0}" = "1" ] && X11VNC_ARGS="$X11VNC_ARGS -viewonly"
    if [ -n "$PASSFILE" ]; then
      X11VNC_ARGS="$X11VNC_ARGS -rfbauth $PASSFILE"
    else
      X11VNC_ARGS="$X11VNC_ARGS -nopw"
    fi

    # shellcheck disable=SC2086
    x11vnc $X11VNC_ARGS || {
      log "x11vnc failed to start, retrying in 2 seconds..."
      sleep 2
      # shellcheck disable=SC2086
      x11vnc $X11VNC_ARGS || true
    }
    sleep 1
    X11VNC_PID=$(pgrep -f "x11vnc.*-display $CURRENT_DISPLAY" | head -1)

    if [ -z "$X11VNC_PID" ]; then
      log "x11vnc not found after start, clearing display for retry"
      CURRENT_DISPLAY=""
    else
      log "x11vnc running (pid=$X11VNC_PID) on DISPLAY=$CURRENT_DISPLAY"
    fi
  fi

  sleep 2
done
