#!/usr/bin/env bash
# Verify the built image actually produces a desktop over VNC.
#
# This does NOT trust "the container is running" or "wayvnc is listening" as
# evidence. Both are true in the exact failure this project spent its time on:
# Hyprland with no usable EGL device serves a live Wayland socket and paints
# nothing, so VNC connects fine and shows a flat black screen. The only honest
# check is to capture a frame and count distinct colours.
#
# Exit 0 only if a real, non-uniform framebuffer came back over RFB.
set -euo pipefail

IMAGE="${OMARCHY_IMAGE:-omarchy:4.0.1}"
NAME="${VERIFY_CONTAINER:-omarchy-verify}"
PORT="${VERIFY_PORT:-5999}"
WEB_PORT="${VERIFY_WEB_PORT:-6099}"
TIMEOUT="${VERIFY_TIMEOUT:-180}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT="${VERIFY_OUT:-${HERE}/../verify-screenshot.ppm}"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap 'cleanup' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

docker image inspect "$IMAGE" >/dev/null 2>&1 || { red "image $IMAGE not found — run build/build-image.sh first"; exit 1; }
cleanup

say "starting $IMAGE as $NAME (VNC on host port $PORT)"
# Check for DRM inside the DOCKER VM, not on this machine. On macOS /dev/dri
# never exists on the host, but the Colima/Lima guest may well have one after
# `modprobe vkms` -- and that is the kernel the container actually runs on.
DEV_ARGS=()
if docker run --rm --platform linux/amd64 alpine sh -c '[ -e /dev/dri ]' 2>/dev/null; then
  DEV_ARGS=(--device /dev/dri)
  say "/dev/dri exists in the docker VM - passing it through so the image can choose Hyprland if it can render"
else
  say "no /dev/dri in the docker VM - expecting the sway fallback"
fi
docker run -d --name "$NAME" --platform linux/amd64 \
  "${DEV_ARGS[@]}" \
  --shm-size 2g \
  -p "127.0.0.1:${PORT}:5900" \
  -p "127.0.0.1:${WEB_PORT}:6080" \
  -e OMARCHY_RESOLUTION=1280x800 \
  "$IMAGE" >/dev/null

say "waiting up to ${TIMEOUT}s for the desktop to come up"
deadline=$(( SECONDS + TIMEOUT ))
ready=0
while [ "$SECONDS" -lt "$deadline" ]; do
  state="$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo gone)"
  if [ "$state" != "running" ]; then
    red "container is '$state' — it did not stay up. Last 60 log lines:"
    docker logs --tail 60 "$NAME" 2>&1 || true
    exit 1
  fi
  # A bare TCP connect is NOT sufficient: docker's userland proxy binds the
  # published host port the moment the container starts, so connect() succeeds
  # long before wayvnc exists. Require the RFB protocol-version banner, which
  # only the real server sends -- that is proof wayvnc is actually serving.
  if python3 -c "
import socket,sys
try:
    s=socket.create_connection(('127.0.0.1',${PORT}),timeout=2); s.settimeout(3)
    sys.exit(0 if s.recv(12).startswith(b'RFB ') else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
    ready=1; break
  fi
  sleep 3
done
[ "$ready" = 1 ] || { red "wayvnc never listened on 5900 inside the container"; docker logs --tail 60 "$NAME"; exit 1; }
grn "wayvnc is serving RFB"

say "which compositor was selected, and why"
docker exec "$NAME" omarchy-egl-probe -v 2>&1 | sed 's/^/    /' || true
# -x matches the exact process name. Do NOT use -f here: Arch symlinks
# /usr/sbin -> /usr/bin so the path in argv is /usr/sbin/sway (a "/usr/bin/sway"
# pattern misses), and a -f pattern also matches the shell running the check
# itself. Under Rosetta argv[0] is the translator but comm is still the binary.
docker exec "$NAME" sh -c 'pgrep -ax Hyprland || pgrep -ax sway || echo "(no compositor process!)"' 2>&1 | sed 's/^/    /'

# Give the compositor a moment to actually paint its first frames.
sleep 5

say "capturing a frame over RFB and measuring it"
if python3 "${HERE}/rfbgrab.py" 127.0.0.1 "$PORT" "$OUT"; then
  echo
  # The browser client is a separate failure domain from VNC, and it is
  # NON-critical at runtime -- a broken bridge leaves the container "healthy"
  # while http://host:6080/vnc.html is dead. That is exactly how the vendored
  # websockify shim shipped broken once, so check it explicitly here.
  say "checking the noVNC browser client on ${WEB_PORT}"
  novnc_rc=0
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${WEB_PORT}/vnc.html" || echo 000)"
    [ "$code" = "200" ] && break
    sleep 3
  done
  if [ "$code" = "200" ]; then
    grn "    noVNC serving vnc.html (HTTP 200)"
  else
    novnc_rc=1
    red "    noVNC NOT serving: http://127.0.0.1:${WEB_PORT}/vnc.html -> HTTP ${code}"
    echo "    websockify log:"
    docker exec "$NAME" sh -c 'tail -15 /run/user/1000/omarchy-container/log/novnc.log 2>/dev/null' | sed 's/^/      /' || true
  fi

  if [ "$novnc_rc" != 0 ]; then
    red "FAIL — VNC works but the browser client does not"
    exit 1
  fi
  grn "PASS — the image produces a real desktop over VNC and noVNC"
  echo "      screenshot: $OUT"
  exit 0
else
  rc=$?
  echo
  red "FAIL — no usable framebuffer (rfbgrab exit $rc)"
  echo "Recent container logs:"
  docker logs --tail 60 "$NAME" 2>&1 | sed 's/^/    /'
  exit 1
fi
