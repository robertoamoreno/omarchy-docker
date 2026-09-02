#!/usr/bin/env bash
#
# EXPERIMENTAL. Verified against omarchy-4.0.1.iso (2026-08-25) on Apple Silicon
# macOS + Colima only. Runs a --privileged builder container and loop-mounts the
# ISO. Read docs/RESEARCH.md before trusting any of this on another host.
#
# build-image.sh — build omarchy:4.0.1 (linux/amd64) from the Omarchy 4.0.1 ISO.
#
# =============================================================================
# WHAT THIS DOES
# =============================================================================
# The ISO does NOT contain an Omarchy desktop; airootfs.sfs is a stock archiso
# live installer whose 5.9 GB is dominated by a bundled offline pacman mirror
# (/var/cache/omarchy/mirror/offline, 1249 packages). See docs/RESEARCH.md §2.
#
# So we do what the ISO's own installer does: use [offline] as a pacman repo and
# pacman-install the Omarchy package set into a fresh rootfs, then stream that
# rootfs straight into a Docker image.
#
#   host                                  builder container (--privileged, amd64)
#   ----                                  ---------------------------------------
#   preflight                             mount -o loop,ro  ISO        -> /mnt/iso
#   docker run -d builder    ----------->  mount -o loop,ro  sfs       -> /mnt/root
#   docker cp inner.sh                    pacman --root /rootfs (3 transactions)
#   docker exec bash inner.sh             strip / user / overlay
#   docker exec tar -C /rootfs -c .  --|
#                                       |-> docker import - omarchy:4.0.1
#
# The 6.2 GB ISO is NEVER copied. The offline mirror is NEVER extracted. The
# tarball NEVER lands on disk (it is streamed over the docker API in one pipe).
#
# =============================================================================
# DISK BUDGET — read this before you run it
# =============================================================================
#   rootfs after strip .............. ~6.5 GiB   (inside the builder's rw layer)
#   layer blob docker writes ........ ~2.7 GiB   (gzip -1 of the 6.23 GiB tar)
#   unpacked image snapshot ......... ~6.5 GiB
#   ------------------------------------------
#   peak, during import ............. ~15.7 GiB
#
# SAFETY: this script never prunes docker volumes. `docker system prune
# --volumes` on this machine would destroy unrelated projects' databases
# (placecommandcenter_cc-postgres-data, card-scraper_timescale_data,
# agent-wiki_opensearchdata, ...). --prune here means build cache + dangling
# images only. To get more room, grow the VM disk or pass --slim, which drops
# the measured heavy tier (libreoffice/kdenlive/obsidian/obs-studio/
# moonlight-qt/localsend/dotnet-runtime, ~1.87 GiB) and lands near 4.6 GiB
# rootfs / ~11 GiB peak.
#
# Do NOT try to build the rootfs on the macOS bind mount to borrow the host's
# free space: Docker Desktop reports it `type fakeowner` and synthesizes uid/gid,
# so every pacman-installed file would come out with the wrong ownership.
#
# =============================================================================
# CORRECTION TO docs/RESEARCH.md §5 (from the empirical probe, 2026-08-30)
# =============================================================================
# §5 is wrong on two counts:
#   1. aquamarine 0.14.0 DOES have a nested Wayland backend (src/backend/
#      Wayland.cpp, AQ_BACKEND_WAYLAND, requested by Hyprland in FALLBACK mode).
#      It is useless without a GPU only because Wayland.cpp:146 hard-requires the
#      parent compositor to advertise zwp_linux_dmabuf_v1 plus a resolvable main
#      device.
#   2. prepareFallbackOutput() is real but irrelevant — the process dies in
#      CBackend::start() long before any output logic runs.
#
# NEW HARD CONSTRAINT: Hyprland 0.56.2 requires a GBM-capable DRM node
# (/dev/dri/renderD* or a dumb-buffer-capable card, visible to udev). "Headless"
# is NOT a GPU-free mode. aquamarine-0.14.0 Backend.cpp:162-178 only builds the
# GBM allocator from an implementation with drmFD() >= 0, and Headless.cpp:132
# returns -1 unconditionally, so headless alone ALWAYS dies with
# "Cannot open backend: no allocator available". Hyprland never requests
# AQ_BACKEND_NULL (the only type that bypasses the check) — there is no env var
# or flag that works around it.
#
# THIS IMAGE THEREFORE CANNOT RUN ON DOCKER DESKTOP FOR MAC. The linuxkit VM
# kernel (6.10.14-linuxkit) has CONFIG_DRM_VGEM / VKMS / SIMPLEDRM / UDMABUF all
# unset, /sys/class/drm holds only `version`, and no virtio-gpu device is
# attached — there is nothing to modprobe and nothing to pass through.
#
# The IMAGE BUILD is portable and correct; only the RUNTIME host must change.
# Run the built image on any x86_64 Linux host with:
#     modprobe vkms                      # or a real GPU
#     docker run --device /dev/dri --group-add video ... omarchy:4.0.1
# (and AQ_NO_KMS_REQUIREMENT=1 so aquamarine accepts a render-only node).
# Building on this Mac is still worth doing — the image is the deliverable.
#
# =============================================================================
# USAGE
# =============================================================================
#   ./build/build-image.sh                 # full build
#   ./build/build-image.sh --dry-run       # preflight + plan only, no build
#   ./build/build-image.sh --slim          # drop the heavy app tier (~1.87 GiB)
#   ./build/build-image.sh --keep-builder  # leave the builder container for debug
#   ./build/build-image.sh --help
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Frozen interface constants — every file in this repo must agree on these.
# ---------------------------------------------------------------------------
IMAGE_NAME_DEFAULT="omarchy:4.0.1"
PLATFORM="linux/amd64"
CONTAINER_USER="omarchy"
CONTAINER_UID=1000
CONTAINER_GID=1000
CONTAINER_HOME="/home/omarchy"
XDG_RUNTIME_DIR_PATH="/run/user/1000"
VNC_PORT=5900
NOVNC_PORT=6080
HEADLESS_OUTPUT="HEADLESS-1"
DEFAULT_RESOLUTION="1920x1080"
ENTRYPOINT_PATH="/usr/local/bin/omarchy-container-init"

# ISO identity (verified 2026-08-30 by direct inspection).
ISO_BASENAME="omarchy-4.0.1.iso"
ISO_SIZE_BYTES=6227752960
ISO_SHA256="69cbb4e10d98ad831c3c9f245b5757a9d1fedfd0c9592780e977d6f950dea8c3"

# Arch Linux Archive snapshot pinned to the ISO's own build date (arch/version =
# 2026.08.25). Single-quoted: $repo/$arch are pacman variables, not shell ones.
# These are only FALLBACKS — build/packages.conf is the source of truth and
# overrides them via OMARCHY_ALA_SNAPSHOT / OMARCHY_ALA_SERVER.
ALA_DATE="2026/08/25"
# shellcheck disable=SC2016
ALA_SERVER='https://archive.archlinux.org/repos/2026/08/25/$repo/os/$arch'
MIRROR_PATH="/mnt/root/var/cache/omarchy/mirror/offline"

# Vendored browser client. noVNC and python-websockify are absent from BOTH the
# offline mirror and the pinned ALA extra snapshot (RESEARCH.md §6), so they are
# fetched from their GitHub release tags. These two tags are known-good; bump
# with --novnc-version / --websockify-version if you want newer.
NOVNC_VERSION="1.5.0"
WEBSOCKIFY_VERSION="0.12.0"

# ---------------------------------------------------------------------------
# Defaults (overridable by flags)
# ---------------------------------------------------------------------------
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="$IMAGE_NAME_DEFAULT"
BUILDER_NAME="omarchy-builder"
BASE_IMAGE="archlinux:latest"
MIN_FREE_GIB=17           # peak is ~15.7 GiB; 17 leaves a real margin
MIN_FREE_EXPLICIT=0       # set by --min-free-gib so an explicit flag still wins
KEEP_BUILDER=0
KEEP_OLD_IMAGE=0
SKIP_SHA=0
SKIP_OVERLAY_CHECK=0
KEEP_CAPS=0
NOVNC_FLAG=""            # tri-state; resolved from packages.conf after sourcing
SLIM_FLAG=""             # tri-state; resolved from OMARCHY_SLIM after sourcing
DOCKER_FLAG=""           # tri-state; resolved from OMARCHY_ENABLE_DOCKER
DRY_RUN=0
DO_PRUNE=0
EMIT_INNER=""

BUILD_START_EPOCH="$(date +%s)"
STEP_NO=0
TMP_DIR=""
BUILDER_STARTED=0

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'; C_OFF=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_OFF=""
fi

_elapsed() {
  local s=$(( $(date +%s) - BUILD_START_EPOCH ))
  printf '%02d:%02d' $(( s / 60 )) $(( s % 60 ))
}
step() {
  STEP_NO=$(( STEP_NO + 1 ))
  printf '\n%s==> [%s] step %d: %s%s\n' "$C_BOLD$C_CYN" "$(_elapsed)" "$STEP_NO" "$*" "$C_OFF"
}
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %sok%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '    %swarn%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  {
  printf '\n%serror:%s %s\n' "$C_RED$C_BOLD" "$C_OFF" "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
build-image.sh — build ${IMAGE_NAME_DEFAULT} (${PLATFORM}) from ./${ISO_BASENAME}

  --dry-run                 run preflight and print the plan, then stop
  --emit-inner FILE         write the generated in-container build script to FILE
                            and stop (for review / offline debugging)
  --slim / --no-slim        drop (or keep) OMARCHY_PKGS_SLIM_DROP from
                            packages.conf: the heavy app tier, ~1.87 GiB.
                            Default follows OMARCHY_SLIM in packages.conf.
  --with-docker /           also install (or skip) OMARCHY_PKGS_DOCKER: docker,
    --no-docker             buildx, compose, lazydocker; +320 MiB. Default
                            follows OMARCHY_ENABLE_DOCKER in packages.conf.
  --novnc / --no-novnc      vendor (or skip) noVNC + websockify. Default follows
                            OMARCHY_NOVNC_VENDOR in packages.conf.
  --prune                   reclaim build cache + dangling images before building.
                            NEVER touches volumes (see SAFETY note in the header).
  --keep-builder            do not remove the builder container when done
  --keep-old-image          do not delete an existing ${IMAGE_NAME_DEFAULT} before
                            import (needs ~6.5 GiB more free space)
  --novnc-version V         noVNC release tag to vendor        (default ${NOVNC_VERSION})
  --websockify-version V    websockify release tag to vendor   (default ${WEBSOCKIFY_VERSION})
  --skip-sha                skip the sha256 check of the ISO (saves ~40s)
  --skip-overlay-check      do not fail when rootfs-overlay/ has no entrypoint
  --keep-caps               do not strip file capabilities outside Docker's
                            default bounding set (see notes in this script)
  --tag NAME:TAG            image tag to produce           (default ${IMAGE_NAME_DEFAULT})
  --builder-name NAME       builder container name         (default ${BUILDER_NAME})
  --base-image IMAGE        builder base image             (default ${BASE_IMAGE})
  --min-free-gib N          required free space in the Docker VM (default ${MIN_FREE_GIB})
  -h, --help                this text
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)             DRY_RUN=1 ;;
    --emit-inner)          EMIT_INNER="${2:?--emit-inner needs a path}"; shift ;;
    --slim)                SLIM_FLAG=1 ;;
    --no-slim)             SLIM_FLAG=0 ;;
    --with-docker)         DOCKER_FLAG=1 ;;
    --no-docker)           DOCKER_FLAG=0 ;;
    --prune)               DO_PRUNE=1 ;;
    --keep-builder)        KEEP_BUILDER=1 ;;
    --keep-old-image)      KEEP_OLD_IMAGE=1 ;;
    --novnc)               NOVNC_FLAG=1 ;;
    --no-novnc)            NOVNC_FLAG=0 ;;
    --novnc-version)       NOVNC_VERSION="${2:?--novnc-version needs a value}"; shift ;;
    --websockify-version)  WEBSOCKIFY_VERSION="${2:?--websockify-version needs a value}"; shift ;;
    --skip-sha)            SKIP_SHA=1 ;;
    --skip-overlay-check)  SKIP_OVERLAY_CHECK=1 ;;
    --keep-caps)           KEEP_CAPS=1 ;;
    --tag)                 IMAGE_NAME="${2:?--tag needs a value}"; shift ;;
    --builder-name)        BUILDER_NAME="${2:?--builder-name needs a value}"; shift ;;
    --base-image)          BASE_IMAGE="${2:?--base-image needs a value}"; shift ;;
    --min-free-gib)        MIN_FREE_GIB="${2:?--min-free-gib needs a value}"; MIN_FREE_EXPLICIT=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *)                     usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

ISO_PATH="$REPO_DIR/$ISO_BASENAME"
OVERLAY_DIR="$REPO_DIR/rootfs-overlay"
PACKAGES_CONF="$REPO_DIR/build/packages.conf"

# ---------------------------------------------------------------------------
# Cleanup trap — the builder must die even on failure, Ctrl-C included.
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  set +e
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
  if [ "$BUILDER_STARTED" = 1 ]; then
    if [ "$KEEP_BUILDER" = 1 ]; then
      printf '\n    %skept builder container '\''%s'\''%s\n' "$C_YEL" "$BUILDER_NAME" "$C_OFF" >&2
      printf '        docker exec -it %s bash        # poke around\n' "$BUILDER_NAME" >&2
      printf '        docker exec %s bash /work/inner.sh   # re-run the inner build\n' "$BUILDER_NAME" >&2
      printf '        docker rm -f %s                # when you are done\n' "$BUILDER_NAME" >&2
    else
      printf '\n    removing builder container '\''%s'\'' ...\n' "$BUILDER_NAME" >&2
      # Unwind mounts inside the container first so the VM's loop devices get
      # released cleanly (mount -o loop sets LO_FLAGS_AUTOCLEAR, but a lazy
      # unmount first is cheap insurance).
      docker exec "$BUILDER_NAME" sh -c '
        umount -R /rootfs/var/cache/pacman/pkg 2>/dev/null
        umount -R /rootfs/dev /rootfs/proc /rootfs/sys 2>/dev/null
        umount -l /mnt/root 2>/dev/null
        umount -l /mnt/iso  2>/dev/null
        true' >/dev/null 2>&1
      docker rm -f "$BUILDER_NAME" >/dev/null 2>&1
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    printf '\n%sbuild FAILED after %s (exit %d)%s\n' "$C_RED$C_BOLD" "$(_elapsed)" "$rc" "$C_OFF" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

file_size() {
  # portable stat, following symlinks: macOS BSD stat vs GNU stat
  stat -Lf %z "$1" 2>/dev/null || stat -Lc %s "$1" 2>/dev/null
}

# Emit `NAME=( a b c )` with every element shell-quoted, for the inner preamble.
emit_array() {
  local name="$1"; shift
  printf '%s=(' "$name"
  if [ $# -gt 0 ]; then printf ' %q' "$@"; fi
  printf ' )\n'
}

# Print the elements of $2..$n that are NOT in the newline-list $1.
filter_out() {
  local drop="$1"; shift
  local x
  for x in "$@"; do
    case $'\n'"$drop"$'\n' in
      *$'\n'"$x"$'\n'*) : ;;
      *) printf '%s\n' "$x" ;;
    esac
  done
}

# =============================================================================
# STEP 1 — preflight
# =============================================================================
step "preflight"

# --emit-inner is a pure authoring/debug operation: it only needs the ISO
# constants and packages.conf, so it skips every docker-dependent check.
if [ -z "$EMIT_INNER" ]; then
  have docker || die "docker not found on PATH"
  docker info >/dev/null 2>&1 || die "docker daemon is not responding. Start Docker Desktop and retry."
  DOCKER_VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
  ok "docker daemon up (server ${DOCKER_VER})"
else
  DOCKER_VER="n/a"
  info "--emit-inner: skipping all docker checks"
fi

# --- ISO identity ---------------------------------------------------------
[ -f "$ISO_PATH" ] || die "ISO not found at $ISO_PATH"
ACTUAL_SIZE="$(file_size "$ISO_PATH")"
[ -n "$ACTUAL_SIZE" ] || die "could not stat $ISO_PATH"
if [ "$ACTUAL_SIZE" != "$ISO_SIZE_BYTES" ]; then
  die "ISO size mismatch.
       expected: $ISO_SIZE_BYTES bytes
       actual:   $ACTUAL_SIZE bytes
       path:     $ISO_PATH
     This is not the Omarchy 4.0.1 ISO this build was verified against."
fi
ok "ISO size $ACTUAL_SIZE bytes"

if [ "$SKIP_SHA" = 1 ]; then
  warn "sha256 check skipped (--skip-sha)"
else
  info "hashing 5.8 GiB, ~40s ... (skip with --skip-sha)"
  if have shasum;        then ACTUAL_SHA="$(shasum -a 256 "$ISO_PATH" | awk '{print $1}')"
  elif have sha256sum;   then ACTUAL_SHA="$(sha256sum "$ISO_PATH" | awk '{print $1}')"
  else ACTUAL_SHA=""; warn "neither shasum nor sha256sum found; cannot verify"
  fi
  if [ -n "$ACTUAL_SHA" ]; then
    [ "$ACTUAL_SHA" = "$ISO_SHA256" ] || die "ISO sha256 mismatch.
       expected: $ISO_SHA256
       actual:   $ACTUAL_SHA
       path:     $ISO_PATH"
    ok "ISO sha256 ${ISO_SHA256:0:16}..."
  fi
fi

# --- package selection ----------------------------------------------------
# Declare empty first so `set -u` is safe even if packages.conf omits one.
OMARCHY_PKGS_BASE=()
OMARCHY_PKGS_DESKTOP=()
OMARCHY_PKGS_VNC=()
OMARCHY_PKGS_FALLBACK=()
OMARCHY_PKGS_EXCLUDE=()
OMARCHY_ASSUME_INSTALLED=()
OMARCHY_PKGS_VNC_PRESEED=()
OMARCHY_PKGS_VNC_URL=()
OMARCHY_PKGS_DOCKER=()
OMARCHY_PKGS_SLIM_DROP=()

[ -f "$PACKAGES_CONF" ] || die "package selection not found: $PACKAGES_CONF
     build-image.sh is deliberately not a second source of truth for the package
     list. Create build/packages.conf defining the shell arrays
     OMARCHY_PKGS_BASE, OMARCHY_PKGS_DESKTOP, OMARCHY_PKGS_VNC,
     OMARCHY_PKGS_EXCLUDE and OMARCHY_ASSUME_INSTALLED."
# shellcheck source=/dev/null
. "$PACKAGES_CONF"

[ ${#OMARCHY_PKGS_BASE[@]}    -gt 0 ] || die "$PACKAGES_CONF defines no OMARCHY_PKGS_BASE"
[ ${#OMARCHY_PKGS_DESKTOP[@]} -gt 0 ] || die "$PACKAGES_CONF defines no OMARCHY_PKGS_DESKTOP"
[ ${#OMARCHY_PKGS_VNC[@]}     -gt 0 ] || die "$PACKAGES_CONF defines no OMARCHY_PKGS_VNC"
[ ${#OMARCHY_PKGS_FALLBACK[@]} -gt 0 ] || die "$PACKAGES_CONF defines no OMARCHY_PKGS_FALLBACK
     (the entrypoint's compositor auto-detection falls back to sway on hosts
      where Hyprland cannot render -- see docs/RESEARCH.md section 12)"
ok "packages.conf: base=${#OMARCHY_PKGS_BASE[@]} desktop=${#OMARCHY_PKGS_DESKTOP[@]} vnc=${#OMARCHY_PKGS_VNC[@]} fallback=${#OMARCHY_PKGS_FALLBACK[@]} assume=${#OMARCHY_ASSUME_INSTALLED[@]}"

# packages.conf is the source of truth for the repos too — take its values over
# this script's fallbacks, so there is exactly one place to bump the snapshot.
if [ -n "${OMARCHY_ALA_SERVER:-}" ];        then ALA_SERVER="$OMARCHY_ALA_SERVER"; fi
if [ -n "${OMARCHY_ALA_SNAPSHOT:-}" ];      then ALA_DATE="$OMARCHY_ALA_SNAPSHOT"; fi
if [ -n "${OMARCHY_OFFLINE_REPO_PATH:-}" ]; then MIRROR_PATH="$OMARCHY_OFFLINE_REPO_PATH"; fi
info "repos: [offline] file://$MIRROR_PATH/ + ALA $ALA_DATE"

# Resolve the tri-state flags: CLI wins, then packages.conf, then the default.
if [ -n "$SLIM_FLAG" ];   then SLIM="$SLIM_FLAG";     else SLIM="${OMARCHY_SLIM:-0}"; fi

# --slim lowers the peak from ~15.7 GiB to ~11.3 GiB (4.68 GiB rootfs x 2.41 for
# blob + snapshot), so it must lower the gate too. Without this the die message
# that RECOMMENDS --slim was unsatisfiable: --slim left the gate at 17 GiB, so
# the build refused with the identical error it had just told you --slim fixes.
if [ "$SLIM" = 1 ] && [ "$MIN_FREE_EXPLICIT" = 0 ]; then
  MIN_FREE_GIB=13
fi
if [ -n "$DOCKER_FLAG" ]; then WITH_DOCKER="$DOCKER_FLAG"; else WITH_DOCKER="${OMARCHY_ENABLE_DOCKER:-0}"; fi
if [ -n "$NOVNC_FLAG" ];  then WANT_NOVNC="$NOVNC_FLAG";    else WANT_NOVNC="${OMARCHY_NOVNC_VENDOR:-1}"; fi

# THE DOCUMENTED TRAP: --assume-installed alone is not enough for plymouth and
# sddm, because both are ALSO explicit lines in omarchy-base.packages. If they
# survive in the explicit list they get installed anyway as top-level targets
# and you save nothing (sddm alone drags in the full xorg-server). Strip any
# assume-installed name out of the explicit lists here, loudly.
if [ ${#OMARCHY_ASSUME_INSTALLED[@]} -gt 0 ]; then
  ASSUME_NL="$(printf '%s\n' "${OMARCHY_ASSUME_INSTALLED[@]}")"
  for _list in OMARCHY_PKGS_BASE OMARCHY_PKGS_DESKTOP OMARCHY_PKGS_VNC OMARCHY_PKGS_FALLBACK; do
    eval "_cur=( \${$_list[@]+\"\${$_list[@]}\"} )"
    _kept=()
    for _p in ${_cur[@]+"${_cur[@]}"}; do
      case $'\n'"$ASSUME_NL"$'\n' in
        *$'\n'"$_p"$'\n'*)
          warn "$_p is in OMARCHY_ASSUME_INSTALLED but also explicit in $_list — dropping it from the explicit list (this is the documented plymouth/sddm trap)" ;;
        *) _kept[${#_kept[@]}]="$_p" ;;
      esac
    done
    eval "$_list=( \${_kept[@]+\"\${_kept[@]}\"} )"
  done
fi

# Cross-check the EXCLUDE list: a name in both DESKTOP and EXCLUDE is a bug in
# packages.conf. Warn, do not silently drop — the operator should fix the file.
if [ ${#OMARCHY_PKGS_EXCLUDE[@]} -gt 0 ]; then
  EXCLUDE_NL="$(printf '%s\n' "${OMARCHY_PKGS_EXCLUDE[@]}")"
  for _p in ${OMARCHY_PKGS_DESKTOP[@]+"${OMARCHY_PKGS_DESKTOP[@]}"}; do
    case $'\n'"$EXCLUDE_NL"$'\n' in
      *$'\n'"$_p"$'\n'*) warn "$_p appears in BOTH OMARCHY_PKGS_DESKTOP and OMARCHY_PKGS_EXCLUDE — packages.conf contradicts itself; installing it" ;;
    esac
  done
fi

# Optional docker-in-docker tier. Appended, not filtered.
if [ "$WITH_DOCKER" = 1 ]; then
  if [ ${#OMARCHY_PKGS_DOCKER[@]} -eq 0 ]; then
    warn "docker tier requested but $PACKAGES_CONF defines no OMARCHY_PKGS_DOCKER"
  else
    for _p in "${OMARCHY_PKGS_DOCKER[@]}"; do
      OMARCHY_PKGS_DESKTOP[${#OMARCHY_PKGS_DESKTOP[@]}]="$_p"
    done
    ok "docker tier: added ${#OMARCHY_PKGS_DOCKER[@]} packages (${OMARCHY_PKGS_DOCKER[*]}, +320 MiB)"
  fi
fi

# Slim tier: measured removal closures, from packages.conf. Keeps chromium.
if [ "$SLIM" = 1 ]; then
  if [ ${#OMARCHY_PKGS_SLIM_DROP[@]} -gt 0 ]; then
    SLIM_DROP="$(printf '%s\n' "${OMARCHY_PKGS_SLIM_DROP[@]}")"
  else
    warn "$PACKAGES_CONF defines no OMARCHY_PKGS_SLIM_DROP; using this script's fallback list"
    SLIM_DROP="libreoffice-fresh
obsidian
kdenlive
obs-studio
moonlight-qt
localsend
dotnet-runtime"
  fi
  _before=${#OMARCHY_PKGS_DESKTOP[@]}
  _kept=()
  while IFS= read -r _p; do
    [ -n "$_p" ] && _kept[${#_kept[@]}]="$_p"
  done <<EOF
$(filter_out "$SLIM_DROP" ${OMARCHY_PKGS_DESKTOP[@]+"${OMARCHY_PKGS_DESKTOP[@]}"})
EOF
  OMARCHY_PKGS_DESKTOP=( ${_kept[@]+"${_kept[@]}"} )
  ok "--slim: dropped $(( _before - ${#OMARCHY_PKGS_DESKTOP[@]} )) heavy apps (~1.87 GiB of installed size)"
fi

# The ALA poison pill (verified, stable across refetches):
# aml-1.0.0-1-x86_64.pkg.tar.zst in the 2026-08-25 snapshot does NOT match the
# SHA256 recorded in that snapshot's extra.db — the pool file was rebuilt in
# place. pacman aborts the ENTIRE transaction with "invalid or corrupted
# package". aml is a wayvnc dependency, so every build hits it. Workaround:
# download the file and `pacman -U` it first (pacman -U does not check the db
# checksum). Harmless if the pool file ever gets fixed.
#
# Two ways to declare it, both honoured:
#   OMARCHY_PKGS_VNC_URL     explicit URLs  (what packages.conf uses)
#   OMARCHY_PKGS_VNC_PRESEED package names  (URL derived from the sync db)
# If neither is set, fall back to preseeding `aml` by name.
if [ ${#OMARCHY_PKGS_VNC_URL[@]} -eq 0 ] && [ ${#OMARCHY_PKGS_VNC_PRESEED[@]} -eq 0 ]; then
  OMARCHY_PKGS_VNC_PRESEED=( aml )
  warn "packages.conf declares no ALA preseed; defaulting to 'aml' (the known poisoned package)"
fi
ok "ALA preseed: ${#OMARCHY_PKGS_VNC_URL[@]} explicit URL(s), ${#OMARCHY_PKGS_VNC_PRESEED[@]} by name"

# --- overlay --------------------------------------------------------------
if [ -d "$OVERLAY_DIR" ]; then
  if [ -f "$OVERLAY_DIR${ENTRYPOINT_PATH}" ]; then
    ok "overlay tree present, entrypoint found (${ENTRYPOINT_PATH})"
  elif [ "$SKIP_OVERLAY_CHECK" = 1 ]; then
    warn "overlay has no ${ENTRYPOINT_PATH} — continuing because --skip-overlay-check"
  else
    die "rootfs-overlay/ exists but has no ${ENTRYPOINT_PATH#/}.
     The frozen interface makes ${ENTRYPOINT_PATH} the container entrypoint; an
     image without it is dead on arrival. Write it, or pass --skip-overlay-check
     to build a package-only image deliberately."
  fi
else
  [ "$SKIP_OVERLAY_CHECK" = 1 ] || die "no rootfs-overlay/ at $OVERLAY_DIR (pass --skip-overlay-check to build without it)"
  warn "no overlay tree — building a package-only image"
fi

if [ -n "$EMIT_INNER" ]; then
  VM_FREE_GIB=0; OLD_IMAGE_ID=""; OLD_IMAGE_GIB=0
else

# --- builder base image ---------------------------------------------------
if docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  ok "builder base image $BASE_IMAGE present"
else
  info "pulling $BASE_IMAGE ($PLATFORM) ..."
  docker pull --platform "$PLATFORM" "$BASE_IMAGE" >/dev/null \
    || die "could not pull $BASE_IMAGE for $PLATFORM"
  ok "pulled $BASE_IMAGE"
fi

# --- amd64 emulation + free space, in one throwaway container -------------
PROBE_OUT="$(docker run --rm --platform "$PLATFORM" "$BASE_IMAGE" \
              sh -c 'uname -m; df -kP / | tail -1' 2>/dev/null)" \
  || die "could not start a $PLATFORM container. Is Rosetta / binfmt emulation enabled?"

PROBE_ARCH="$(printf '%s\n' "$PROBE_OUT" | sed -n 1p)"
PROBE_DF="$(printf '%s\n' "$PROBE_OUT" | sed -n 2p)"
[ "$PROBE_ARCH" = "x86_64" ] || die "linux/amd64 emulation is not working: uname -m reported '$PROBE_ARCH', expected x86_64.
     Enable Rosetta for x86/amd64 emulation in Docker Desktop > Settings > General."
ok "linux/amd64 emulation works (uname -m = x86_64)"

VM_TOTAL_KB="$(printf '%s\n' "$PROBE_DF" | awk '{print $2}')"
VM_USED_KB="$(printf '%s\n' "$PROBE_DF"  | awk '{print $3}')"
VM_FREE_KB="$(printf '%s\n' "$PROBE_DF"  | awk '{print $4}')"
VM_FREE_GIB=$(( VM_FREE_KB / 1048576 ))
VM_TOTAL_GIB=$(( VM_TOTAL_KB / 1048576 ))
VM_USED_GIB=$(( VM_USED_KB / 1048576 ))
info "Docker VM filesystem: ${VM_TOTAL_GIB} GiB total, ${VM_USED_GIB} GiB used, ${C_BOLD}${VM_FREE_GIB} GiB free${C_OFF}"

# The Docker VM is only HALF the budget, and not the dangerous half. The VM's
# disk is a sparse file on the macOS host (Docker Desktop: Docker.raw; Colima:
# the Lima diffdisk), so every previously-unallocated block the build writes
# also consumes host disk. If macOS fills first, the guest gets EIO on a
# filesystem it still believes has room -- that is how a VM disk gets wedged.
# Measure both, and refuse on either.
HOST_FREE_KB="$(df -kP "$REPO_DIR" | tail -1 | awk '{print $4}')"
HOST_FREE_GIB=$(( HOST_FREE_KB / 1048576 ))
HOST_MIN_GIB=$(( MIN_FREE_GIB + 5 ))   # +5 so macOS itself keeps breathing room
info "macOS host filesystem: ${C_BOLD}${HOST_FREE_GIB} GiB free${C_OFF} (need ${HOST_MIN_GIB} GiB: ${MIN_FREE_GIB} for the image + 5 for the OS)"
for _vmdisk in \
    "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" \
    "$HOME/.colima/_lima/_disks/colima/datadisk" \
    "$HOME/.colima/_lima/colima/diffdisk" \
    "$HOME/.colima/_lima/colima/disk" \
    "$HOME/.lima/colima/diffdisk"; do
  [ -f "$_vmdisk" ] || continue
  info "  VM disk $(basename "$_vmdisk") currently allocated: $(du -m "$_vmdisk" 2>/dev/null | awk '{printf "%.1f GiB", $1/1024}')"
done
if [ "$HOST_FREE_GIB" -lt "$HOST_MIN_GIB" ]; then
  die "not enough free space on the macOS host.

       required: ${HOST_MIN_GIB} GiB   free: ${HOST_FREE_GIB} GiB   short by: $(( HOST_MIN_GIB - HOST_FREE_GIB )) GiB

     The VM disk is a sparse file on this filesystem, so the build consumes host
     space as it writes. Running out here can wedge the VM disk, not just fail
     the build. Free space on macOS, or use --slim (~4.6 GiB rootfs, ~11 GiB
     peak), or pass --min-free-gib N if you know better than this check.

     Note: this script never prunes docker volumes to make room -- doing so on
     this machine would delete unrelated projects' databases."
fi

# An existing image with the same tag is 6.5 GiB of dead weight the moment we
# re-import over it. Reclaim it (before import, not now — a failed build should
# not cost you the previous good image).
OLD_IMAGE_ID=""
OLD_IMAGE_GIB=0
if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  OLD_IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$IMAGE_NAME")"
  OLD_IMAGE_GIB=$(( $(docker image inspect -f '{{.Size}}' "$IMAGE_NAME") / 1073741824 ))
  if [ "$KEEP_OLD_IMAGE" = 1 ]; then
    warn "$IMAGE_NAME already exists (~${OLD_IMAGE_GIB} GiB) and --keep-old-image was given; it will be left dangling after import"
  else
    info "$IMAGE_NAME already exists (~${OLD_IMAGE_GIB} GiB); it will be deleted immediately before the new import"
  fi
fi

if [ "$DO_PRUNE" = 1 ]; then
  step "pruning docker build cache + dangling images (--prune)"
  # SAFETY: deliberately NOT 'docker system prune -a --volumes'. That would
  # delete every unused named volume on this machine -- which here includes
  # placecommandcenter_cc-postgres-data, card-scraper_timescale_data,
  # agent-wiki_opensearchdata and other unrelated projects' databases.
  # Build cache and dangling images are the only safe things to reclaim
  # automatically. Volumes are never pruned by this script, with or without -f.
  docker builder prune -af || true
  docker image prune -f || true
  PROBE_DF="$(docker run --rm --platform "$PLATFORM" "$BASE_IMAGE" sh -c 'df -kP / | tail -1')"
  VM_FREE_KB="$(printf '%s\n' "$PROBE_DF" | awk '{print $4}')"
  VM_FREE_GIB=$(( VM_FREE_KB / 1048576 ))
  ok "after prune: ${VM_FREE_GIB} GiB free"
fi

if [ "$VM_FREE_GIB" -lt "$MIN_FREE_GIB" ]; then
  RECLAIM="$(docker system df 2>/dev/null | sed 's/^/         /')"
  die "not enough free space in the Docker VM.

       required: ${MIN_FREE_GIB} GiB   (peak during import is ~15.7 GiB:
                                  6.5 rootfs + 2.7 layer blob + 6.5 snapshot)
       free:     ${VM_FREE_GIB} GiB
       short by: $(( MIN_FREE_GIB - VM_FREE_GIB )) GiB

     Reclaimable right now:
$RECLAIM

     Fix it with one of:
       ./build/build-image.sh --slim          # ~4.6 GiB rootfs, ~11 GiB peak
       ./build/build-image.sh --prune         # build cache + dangling images only
       colima stop && colima start --disk 80  # grow the VM disk (sparse; costs
                                              # nothing until actually used)
       --min-free-gib N                       # if you know better than this check

     Do NOT run 'docker system prune -a --volumes' to free space here. On this
     machine that deletes unrelated projects' database volumes (postgres,
     timescale, opensearch). Reclaim the VM disk instead.
     Do NOT move the build onto the macOS bind mount: it is 'type fakeowner' and
     would give every installed file the wrong uid/gid."
fi
ok "free space ${VM_FREE_GIB} GiB >= ${MIN_FREE_GIB} GiB required"

# `docker import --platform` is what stamps the image as amd64; without it the
# image records the daemon's arch (arm64 here) and `docker run` refuses it.
docker image import --help 2>/dev/null | grep -q -- '--platform' \
  || die "this docker ($DOCKER_VER) has no 'docker image import --platform'.
     Without it the imported image would be tagged with the daemon architecture
     (arm64) and would not run. Upgrade Docker (>= 23.0)."
ok "docker image import supports --platform"

fi  # end of the docker-dependent preflight block

# =============================================================================
# STEP 2 — plan
# =============================================================================
step "plan"
cat <<EOF
    image ................ $IMAGE_NAME  ($PLATFORM)
    source ISO ........... $ISO_PATH  (bind-mounted ro, never copied)
    offline repo ......... file://$MIRROR_PATH/
    archive snapshot ..... $ALA_SERVER
    builder .............. $BUILDER_NAME  (--privileged, base $BASE_IMAGE)
    transactions ......... 1) base    ${#OMARCHY_PKGS_BASE[@]} names   [offline]
                           2) desktop ${#OMARCHY_PKGS_DESKTOP[@]} names   [offline]
                           3) vnc     ${#OMARCHY_PKGS_VNC[@]} + ${#OMARCHY_PKGS_FALLBACK[@]} fallback  [offline + ALA]
    assume-installed ..... ${OMARCHY_ASSUME_INSTALLED[*]:-none}
    ALA preseed (-U) ..... ${OMARCHY_PKGS_VNC_URL[*]:-}${OMARCHY_PKGS_VNC_PRESEED[*]:-}
    noVNC ................ $( [ "$WANT_NOVNC" = 1 ] && echo "noVNC v$NOVNC_VERSION + websockify v$WEBSOCKIFY_VERSION" || echo "skipped" )
    slim tier ............ $( [ "$SLIM" = 1 ] && echo "dropped" || echo "kept" )
    docker tier .......... $( [ "$WITH_DOCKER" = 1 ] && echo "included" || echo "excluded" )
    user ................. $CONTAINER_USER ($CONTAINER_UID:$CONTAINER_GID), home $CONTAINER_HOME, NOPASSWD sudo
    XDG_RUNTIME_DIR ...... $XDG_RUNTIME_DIR_PATH (0700, $CONTAINER_UID:$CONTAINER_GID)
    entrypoint ........... $ENTRYPOINT_PATH  (as CMD, so 'docker run IMAGE bash' still works)
    ports ................ $VNC_PORT (vnc), $NOVNC_PORT (web)
    expected rootfs ...... $( [ "$SLIM" = 1 ] && echo "~4.6 GiB" || echo "~6.5 GiB" ) after strip
EOF

if [ "$DRY_RUN" = 1 ]; then
  printf '\n%sdry run: stopping before the build.%s\n' "$C_BOLD" "$C_OFF"
  exit 0
fi

# =============================================================================
# STEP 3 — generate the inner build script
# =============================================================================
step "generating inner build script"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-build.XXXXXX")"
INNER="$TMP_DIR/inner.sh"

{
  # --- generated preamble: every value the inner script needs, shell-quoted ---
  printf '#!/usr/bin/env bash\n'
  printf '# GENERATED by build/build-image.sh — do not edit in place.\n'
  printf 'set -euo pipefail\n'
  printf 'ROOTFS=%q\n'            "/rootfs"
  printf 'WORK=%q\n'              "/work"
  printf 'ISO=%q\n'               "/repo/$ISO_BASENAME"
  printf 'OVERLAY_SRC=%q\n'       "/repo/rootfs-overlay"
  printf 'MIRROR=%q\n'            "$MIRROR_PATH"
  printf 'ALA_SERVER=%q\n'        "$ALA_SERVER"
  printf 'ALA_DATE=%q\n'          "$ALA_DATE"
  printf 'C_USER=%q\n'            "$CONTAINER_USER"
  printf 'C_UID=%q\n'             "$CONTAINER_UID"
  printf 'C_GID=%q\n'             "$CONTAINER_GID"
  printf 'C_HOME=%q\n'            "$CONTAINER_HOME"
  printf 'RUNTIME_DIR=%q\n'       "$XDG_RUNTIME_DIR_PATH"
  printf 'ENTRYPOINT=%q\n'        "$ENTRYPOINT_PATH"
  printf 'WANT_NOVNC=%q\n'        "$WANT_NOVNC"
  printf 'NOVNC_VERSION=%q\n'     "$NOVNC_VERSION"
  printf 'WEBSOCKIFY_VERSION=%q\n' "$WEBSOCKIFY_VERSION"
  printf 'KEEP_CAPS=%q\n'         "$KEEP_CAPS"
  printf 'SKIP_OVERLAY_CHECK=%q\n' "$SKIP_OVERLAY_CHECK"
  printf 'IMAGE_NAME=%q\n'        "$IMAGE_NAME"
  printf 'ISO_SHA256=%q\n'        "$ISO_SHA256"
  printf 'SLIM=%q\n'              "$SLIM"
  printf 'BUILD_DATE=%q\n'        "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  emit_array PKGS_BASE    ${OMARCHY_PKGS_BASE[@]+"${OMARCHY_PKGS_BASE[@]}"}
  emit_array PKGS_DESKTOP ${OMARCHY_PKGS_DESKTOP[@]+"${OMARCHY_PKGS_DESKTOP[@]}"}
  emit_array PKGS_VNC     ${OMARCHY_PKGS_VNC[@]+"${OMARCHY_PKGS_VNC[@]}"}
  emit_array PKGS_FALLBACK ${OMARCHY_PKGS_FALLBACK[@]+"${OMARCHY_PKGS_FALLBACK[@]}"}
  emit_array ASSUME       ${OMARCHY_ASSUME_INSTALLED[@]+"${OMARCHY_ASSUME_INSTALLED[@]}"}
  emit_array PRESEED      ${OMARCHY_PKGS_VNC_PRESEED[@]+"${OMARCHY_PKGS_VNC_PRESEED[@]}"}
  emit_array PRESEED_URL  ${OMARCHY_PKGS_VNC_URL[@]+"${OMARCHY_PKGS_VNC_URL[@]}"}

  # --- body: quoted heredoc, nothing below is expanded by the host shell ---
  cat <<'INNER_BODY'

istep() { printf '\n  --- %s\n' "$*"; }
iinfo() { printf '      %s\n' "$*"; }
iwarn() { printf '      WARN %s\n' "$*" >&2; }
idie()  { printf '\n  ERROR: %s\n' "$*" >&2; exit 1; }

# Ordered list of mounts we create (newest first), so cleanup unwinds in
# reverse. Unwinding on EXIT makes `bash /work/inner.sh` re-runnable inside a
# --keep-builder container, and releases the VM's loop devices promptly.
MOUNTED=""
mark_mount() { MOUNTED="$1"$'\n'"$MOUNTED"; }
unwind_mounts() {
  local m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if mountpoint -q "$m" 2>/dev/null; then umount -R "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true; fi
  done <<< "$MOUNTED"
  return 0
}
trap unwind_mounts EXIT

# --------------------------------------------------------------------------
istep "checking the builder's own tooling"
# --------------------------------------------------------------------------
missing=""
for c in pacman curl tar mount mountpoint losetup chroot getcap setcap od install useradd groupadd getent; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
[ -z "$missing" ] || idie "the builder image is missing:$missing
       (archlinux:latest has all of them; if you passed --base-image, pick one
        with pacman, util-linux, coreutils, shadow, libcap and curl)"
iinfo "pacman $(pacman --version 2>/dev/null | grep -o 'v[0-9.]*' | head -1), tar $(tar --version | head -1 | awk '{print $NF}')"

# --------------------------------------------------------------------------
istep "loop-mounting the ISO (read-only, in place — never copied)"
# --------------------------------------------------------------------------
[ -f "$ISO" ] || idie "ISO not visible inside the builder at $ISO"
mkdir -p /mnt/iso /mnt/root "$WORK/cache" "$ROOTFS"

if ! mountpoint -q /mnt/iso; then
  mount -o loop,ro -t iso9660 "$ISO" /mnt/iso \
    || idie "could not loop-mount the ISO. Is the container --privileged?"
fi
mark_mount /mnt/iso
SFS=/mnt/iso/arch/x86_64/airootfs.sfs
[ -f "$SFS" ] || idie "airootfs.sfs not found at $SFS — wrong ISO layout"
iinfo "iso mounted, airootfs.sfs = $(stat -c %s "$SFS") bytes"

istep "loop-mounting airootfs.sfs (squashfs/zstd, read-only)"
if ! mountpoint -q /mnt/root; then
  mount -o loop,ro -t squashfs "$SFS" /mnt/root \
    || idie "could not mount airootfs.sfs. Kernel needs CONFIG_SQUASHFS_ZSTD."
fi
mark_mount /mnt/root
[ -f "$MIRROR/offline.db" ] || idie "offline repo db missing at $MIRROR/offline.db"
iinfo "offline mirror: $(ls "$MIRROR"/*.pkg.tar.zst 2>/dev/null | wc -l) packages, db present"

# --------------------------------------------------------------------------
istep "writing pacman configs"
# --------------------------------------------------------------------------
# TWO configs on purpose. Phases 1-2 must resolve from [offline] ONLY, so no
# package can silently come off the network. Phase 3 adds the pinned ALA
# snapshot for the VNC layer (absent from [offline]), with [offline] listed
# first so equal versions still resolve locally.
#
# DisableSandbox is mandatory: pacman's alpm sandbox is broken here two ways —
# "error restricting syscalls via seccomp: 22!" in an amd64 container under
# Rosetta, and "Landlock is not supported by the kernel" inside the chroot.
cat > "$WORK/pacman-offline.conf" <<EOF
[options]
HoldPkg           = pacman glibc
Architecture      = x86_64
SigLevel          = Never
LocalFileSigLevel = Never
DisableSandbox
ParallelDownloads = 5

[offline]
SigLevel = Never
Server = file://$MIRROR/
EOF

cat > "$WORK/pacman-vnc.conf" <<EOF
[options]
HoldPkg           = pacman glibc
Architecture      = x86_64
SigLevel          = Never
LocalFileSigLevel = Never
DisableSandbox
ParallelDownloads = 5

[offline]
SigLevel = Never
Server = file://$MIRROR/

[core]
SigLevel = Never
Server = $ALA_SERVER

[extra]
SigLevel = Never
Server = $ALA_SERVER
EOF
iinfo "offline-only config + offline+ALA config written"

# --------------------------------------------------------------------------
istep "preparing /rootfs and bind-mounting the mirror as the package cache"
# --------------------------------------------------------------------------
# pacman COPIES packages out of a file:// repo into the cachedir — it does not
# read them in place. Naively installing would duplicate the whole 2 GiB
# closure onto disk. The ISO's own installer solves this by bind-mounting the
# mirror over the target's cache dir (_mount_offline_package_cache,
# phases_impl.py:640). The source is a read-only squashfs, so the bind is
# inherently read-only; the only symptom is a cosmetic "directory permissions
# differ" warning.
mkdir -p "$ROOTFS/var/cache/pacman/pkg" "$ROOTFS/var/lib/pacman" \
         "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys"
if ! mountpoint -q "$ROOTFS/var/cache/pacman/pkg"; then
  mount --bind "$MIRROR" "$ROOTFS/var/cache/pacman/pkg"
fi
mark_mount "$ROOTFS/var/cache/pacman/pkg"

# Scriptlets and hooks run chrooted; give them the pseudo-filesystems.
for fs in dev proc sys; do
  if ! mountpoint -q "$ROOTFS/$fs"; then
    case "$fs" in
      dev) mount --rbind /dev "$ROOTFS/dev" ;;
      *)   mount --bind "/$fs" "$ROOTFS/$fs" ;;
    esac
    mark_mount "$ROOTFS/$fs"
  fi
done

PAC_COMMON=(
  --root "$ROOTFS"
  --dbpath "$ROOTFS/var/lib/pacman"
  --cachedir "$ROOTFS/var/cache/pacman/pkg"   # ro bind: read hits, no writes
  --cachedir "$WORK/cache"                    # writable: where downloads land
  --noconfirm --needed --disable-sandbox
)

# Transaction 3 pulls from the network, and pacman writes downloads into the
# FIRST cachedir -- which above is the mirror bind mount, mounted READ-ONLY.
# It does not fall through to the next one; it fails the whole transaction:
#   error: could not open file .../sway-1:1.12-4-x86_64.pkg.tar.zst.part:
#          Read-only file system
# Transactions 1-2 never hit this because every package they need is already
# present in that cachedir, so nothing is ever written. Same dirs, writable
# one FIRST: downloads land in $WORK/cache, and [offline] packages pulled in as
# dependencies are still found in the mirror without being copied.
PAC_NET=(
  --root "$ROOTFS"
  --dbpath "$ROOTFS/var/lib/pacman"
  --cachedir "$WORK/cache"                    # writable: downloads land here
  --cachedir "$ROOTFS/var/cache/pacman/pkg"   # ro bind: read hits only
  --noconfirm --needed --disable-sandbox
)
ASSUME_FLAGS=()
for a in ${ASSUME[@]+"${ASSUME[@]}"}; do
  ASSUME_FLAGS[${#ASSUME_FLAGS[@]}]="--assume-installed"
  ASSUME_FLAGS[${#ASSUME_FLAGS[@]}]="$a"
done
iinfo "assume-installed: ${ASSUME[*]:-none}"

# --------------------------------------------------------------------------
istep "transaction 1/3 — base (${#PKGS_BASE[@]} names, [offline] only)"
# --------------------------------------------------------------------------
# Split from the desktop phase on purpose: it lands /usr/bin/vercmp (from the
# pacman package) before dconf's and fontconfig's .INSTALL scriptlets need it.
# In a single transaction you get two "vercmp: command not found" warnings.
# It also matches the ISO installer's own ordering (lua51/luarocks before
# omarchy-nvim).
pacman --config "$WORK/pacman-offline.conf" "${PAC_COMMON[@]}" \
       ${ASSUME_FLAGS[@]+"${ASSUME_FLAGS[@]}"} -Sy "${PKGS_BASE[@]}"
iinfo "installed: $(ls "$ROOTFS/var/lib/pacman/local" | wc -l) entries in the local db"
[ -x "$ROOTFS/usr/bin/vercmp" ] || iwarn "/usr/bin/vercmp absent after phase 1 — scriptlet warnings likely"

# --------------------------------------------------------------------------
istep "transaction 2/3 — desktop (${#PKGS_DESKTOP[@]} names, [offline] only)"
# --------------------------------------------------------------------------
pacman --config "$WORK/pacman-offline.conf" "${PAC_COMMON[@]}" \
       ${ASSUME_FLAGS[@]+"${ASSUME_FLAGS[@]}"} -S "${PKGS_DESKTOP[@]}"
iinfo "installed: $(ls "$ROOTFS/var/lib/pacman/local" | wc -l) entries in the local db"

# --------------------------------------------------------------------------
istep "transaction 3/3 — VNC + fallback compositor (${#PKGS_VNC[@]}+${#PKGS_FALLBACK[@]} names, pinned ALA snapshot)"
# --------------------------------------------------------------------------
# wayvnc/neatvnc/aml/vulkan-swrast are absent from [offline] (RESEARCH.md §6).
# The ALA snapshot is pinned to the ISO's own build date so there is zero
# version skew with the offline mirror.
iinfo "checking reachability of the archive snapshot ..."
curl -fsS -o /dev/null --max-time 30 \
  "https://archive.archlinux.org/repos/$ALA_DATE/extra/os/x86_64/extra.db" \
  || idie "cannot reach archive.archlinux.org/repos/$ALA_DATE — the VNC layer
       needs network. Check DNS/proxy inside Docker, or pass --no-novnc and
       drop OMARCHY_PKGS_VNC if you truly want an image with no VNC server."

pacman --config "$WORK/pacman-vnc.conf" "${PAC_NET[@]}" -Sy

# --- the ALA poison pill ---------------------------------------------------
# aml-1.0.0-1-x86_64.pkg.tar.zst does NOT match the SHA256 in that snapshot's
# extra.db (db says d3a87fac8acf0b55..., the served file is 7665bb28a2ce0a11...,
# stable across refetches: the pool file was rebuilt in place). pacman aborts
# the WHOLE transaction with "invalid or corrupted package". `pacman -U` does
# not consult the db checksum, so fetch-then--U sidesteps it.
preseed_url() {   # $1 = full package URL
  local url="$1" f
  f="$WORK/cache/$(basename "$url")"
  iinfo "preseed: fetching $(basename "$url") (pacman -U bypasses the db checksum)"
  curl -fsSL --retry 3 --retry-delay 2 -o "$f" "$url" \
    || idie "could not download $url for the ALA preseed"
  pacman --config "$WORK/pacman-vnc.conf" "${PAC_NET[@]}" -U "$f" \
    || idie "pacman -U failed on the preseed file $f"
}

# a) explicit URLs from packages.conf (OMARCHY_PKGS_VNC_URL)
for url in ${PRESEED_URL[@]+"${PRESEED_URL[@]}"}; do
  preseed_url "$url"
done

# b) by package name — URL derived from the sync db we just refreshed
for p in ${PRESEED[@]+"${PRESEED[@]}"}; do
  url="$(pacman --config "$WORK/pacman-vnc.conf" "${PAC_NET[@]}" \
           -Sp --print-format '%n %l' "$p" 2>/dev/null \
         | awk -v n="$p" '$1==n{print $2}' | tail -1 || true)"
  if [ -z "$url" ]; then
    iinfo "preseed $p: already satisfied or not in any repo — skipping"
    continue
  fi
  case "$url" in
    file://*) iinfo "preseed $p: served from the local repo — skipping"; continue ;;
  esac
  preseed_url "$url"
done

pacman --config "$WORK/pacman-vnc.conf" "${PAC_NET[@]}" -S "${PKGS_VNC[@]}" "${PKGS_FALLBACK[@]}"
iinfo "installed: $(ls "$ROOTFS/var/lib/pacman/local" | wc -l) entries in the local db"

# --------------------------------------------------------------------------
istep "unmounting the mirror bind (nothing below may see it)"
# --------------------------------------------------------------------------
# du lies while this is mounted (it counts the 4.5 GiB mirror) and tar would
# happily pack the whole thing into the image.
umount -R "$ROOTFS/var/cache/pacman/pkg"
if mountpoint -q "$ROOTFS/var/cache/pacman/pkg"; then
  idie "mirror bind still mounted at $ROOTFS/var/cache/pacman/pkg — refusing to continue (tar would pack 4.5 GiB of mirror into the image)"
fi
MOUNTED="$(printf '%s\n' "$MOUNTED" | grep -v "^${ROOTFS}/var/cache/pacman/pkg\$" || true)"
iinfo "unmounted"

SIZE_BEFORE_MIB="$(du -sxm "$ROOTFS" 2>/dev/null | awk '{print $1}')"
iinfo "rootfs as installed: ${SIZE_BEFORE_MIB} MiB"

# --------------------------------------------------------------------------
istep "vendoring noVNC + websockify"
# --------------------------------------------------------------------------
# Neither novnc nor python-websockify exists in [offline] OR in the pinned ALA
# extra snapshot (RESEARCH.md §6), so browser access has to be vendored from
# the upstream release tags.
if [ "$WANT_NOVNC" = 1 ]; then
  nv="$ROOTFS/usr/share/novnc"
  ws="$ROOTFS/usr/share/websockify"
  rm -rf "$nv" "$ws"
  mkdir -p "$nv" "$ws"
  curl -fsSL --retry 3 "https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VERSION}.tar.gz" \
    | tar -xz -C "$nv" --strip-components=1 \
    || idie "could not fetch noVNC v${NOVNC_VERSION} from github.com/novnc/noVNC"
  curl -fsSL --retry 3 "https://github.com/novnc/websockify/archive/refs/tags/v${WEBSOCKIFY_VERSION}.tar.gz" \
    | tar -xz -C "$ws" --strip-components=1 \
    || idie "could not fetch websockify v${WEBSOCKIFY_VERSION} from github.com/novnc/websockify"
  [ -f "$nv/vnc.html" ] || idie "noVNC tarball has no vnc.html — wrong tag?"
  [ -f "$ws/run" ]      || idie "websockify tarball has no ./run — wrong tag?"

  # Three access paths, because nothing downstream has agreed on one:
  #   /usr/share/novnc/vnc.html            the web client itself
  #   /usr/share/websockify/run            the proxy, where packages.conf says
  #   /usr/share/novnc/utils/websockify    where novnc_proxy looks for it
  #   /usr/local/bin/websockify            on PATH, for the entrypoint
  ln -sf vnc.html "$nv/index.html"
  rm -rf "$nv/utils/websockify"
  ln -sfn /usr/share/websockify "$nv/utils/websockify"
  chmod 0755 "$ws/run" 2>/dev/null || true
  chmod 0755 "$nv/utils/novnc_proxy" 2>/dev/null || true
  mkdir -p "$ROOTFS/usr/share/webapps"
  ln -sfn /usr/share/novnc "$ROOTFS/usr/share/webapps/novnc"
  # Written BEFORE the overlay copy on purpose, so an overlay-supplied
  # /usr/local/bin/websockify wins over this shim.
  mkdir -p "$ROOTFS/usr/local/bin"
  cat > "$ROOTFS/usr/local/bin/websockify" <<'EOS'
#!/bin/sh
# Vendored shim. Neither `novnc` nor `python-websockify` is packaged in the
# ISO's offline mirror or in the pinned Arch Linux Archive snapshot, so the
# upstream release tarballs are unpacked into /usr/share instead.
# ./run is a SHELL wrapper, not a python entry point -- handing it to python3
# fails with `SyntaxError: invalid syntax` on its `cd "$(dirname "$0")"` line
# and the browser client silently never comes up (the bridge is non-critical,
# so the container stays healthy serving VNC on 5900 only). The importable
# package is /usr/share/websockify/websockify/ with a __main__.py.
exec /usr/bin/env PYTHONPATH=/usr/share/websockify /usr/bin/python3 -m websockify "$@"
EOS
  chmod 0755 "$ROOTFS/usr/local/bin/websockify"
  [ -x "$ROOTFS/usr/bin/python3" ] || iwarn "/usr/bin/python3 missing — the websockify shim will not run"
  # Prove the shim runs. This is cheap and catches the ./run-vs-package mistake
  # at build time instead of leaving a dead browser client to be found by hand.
  if chroot "$ROOTFS" /usr/local/bin/websockify --help >/dev/null 2>&1; then
    iinfo "websockify shim executes"
  else
    idie "the websockify shim does not run. Output:
$(chroot "$ROOTFS" /usr/local/bin/websockify --help 2>&1 | head -8)"
  fi
  iinfo "noVNC v${NOVNC_VERSION} -> /usr/share/novnc; websockify v${WEBSOCKIFY_VERSION} -> /usr/share/websockify; shim -> /usr/local/bin/websockify"
else
  iinfo "skipped (noVNC vendoring disabled)"
fi

# --------------------------------------------------------------------------
istep "system configuration"
# --------------------------------------------------------------------------
printf 'omarchy\n' > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1	localhost
::1		localhost
127.0.1.1	omarchy
EOF

# Locale: we prune /usr/share/locale to en*, so generate en_US.UTF-8 and pin it.
if [ -f "$ROOTFS/etc/locale.gen" ]; then
  sed -i 's/^#\(en_US\.UTF-8 UTF-8\)/\1/' "$ROOTFS/etc/locale.gen"
fi
grep -q '^en_US.UTF-8 UTF-8' "$ROOTFS/etc/locale.gen" 2>/dev/null \
  || printf 'en_US.UTF-8 UTF-8\n' >> "$ROOTFS/etc/locale.gen"
printf 'LANG=en_US.UTF-8\n' > "$ROOTFS/etc/locale.conf"
chroot "$ROOTFS" /usr/bin/locale-gen >/dev/null 2>&1 \
  || iwarn "locale-gen failed; LANG=en_US.UTF-8 may warn at runtime"

# dbus needs a machine-id and there is no systemd first-boot to make one.
if [ ! -s "$ROOTFS/etc/machine-id" ]; then
  head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$ROOTFS/etc/machine-id"
  printf '\n' >> "$ROOTFS/etc/machine-id"
fi
mkdir -p "$ROOTFS/var/lib/dbus"
ln -sfn /etc/machine-id "$ROOTFS/var/lib/dbus/machine-id"

# MANDATORY, or the shipped image is broken: without DisableSandbox every
# in-container `pacman -Sy` / `yay` dies with "Landlock is not supported by the
# kernel" -> "switching to sandbox user 'alpm' failed".
if ! grep -q '^DisableSandbox' "$ROOTFS/etc/pacman.conf"; then
  awk 'BEGIN{d=0} {print} /^\[options\]/ && !d {print "DisableSandbox"; d=1}' \
    "$ROOTFS/etc/pacman.conf" > "$ROOTFS/etc/pacman.conf.new"
  mv "$ROOTFS/etc/pacman.conf.new" "$ROOTFS/etc/pacman.conf"
fi
grep -q '^DisableSandbox' "$ROOTFS/etc/pacman.conf" \
  || idie "failed to add DisableSandbox to the image's /etc/pacman.conf"

# Point the image's [core]/[extra] at the same pinned snapshot, so anything the
# user installs later matches the offline mirror's versions exactly. The ALA URL
# already uses $repo/$arch, so it drops straight into mirrorlist.
cat > "$ROOTFS/etc/pacman.d/mirrorlist" <<EOF
# Pinned to the Arch Linux Archive snapshot matching the Omarchy 4.0.1 ISO
# (arch/version = ${ALA_DATE//\//.}). Zero version skew with the packages that
# were installed from the ISO's offline mirror at build time.
Server = $ALA_SERVER

# For a live, rolling mirror instead (WILL skew versions against the ISO set):
#Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
EOF
iinfo "hostname, locale, machine-id, DisableSandbox, pinned mirrorlist"

# --------------------------------------------------------------------------
istep "creating user $C_USER ($C_UID:$C_GID)"
# --------------------------------------------------------------------------
[ -x "$ROOTFS/usr/bin/useradd" ] || idie "shadow is not installed in the rootfs (no useradd)"
chroot "$ROOTFS" /usr/bin/groupadd -f -g "$C_GID" "$C_USER"
# seatd's group. Needed on any host: without it libseat fails with
# "failed to open a seat" and the DRM backend never reaches GPU scanning.
chroot "$ROOTFS" /usr/bin/groupadd -f seat

# Only add groups that actually exist, or useradd aborts.
EXTRA_GROUPS=""
for g in wheel video input render audio seat; do
  if chroot "$ROOTFS" /usr/bin/getent group "$g" >/dev/null 2>&1; then
    EXTRA_GROUPS="${EXTRA_GROUPS:+$EXTRA_GROUPS,}$g"
  else
    iwarn "group '$g' does not exist in the rootfs — not adding $C_USER to it"
  fi
done

if chroot "$ROOTFS" /usr/bin/getent passwd "$C_USER" >/dev/null 2>&1; then
  iinfo "$C_USER already exists (rebuild in a reused rootfs?) — leaving it"
else
  chroot "$ROOTFS" /usr/bin/useradd \
    -m -d "$C_HOME" -u "$C_UID" -g "$C_GID" \
    ${EXTRA_GROUPS:+-G "$EXTRA_GROUPS"} -s /bin/bash "$C_USER"
fi
# Locked password + NOPASSWD sudo. Hyprland refuses to run as root, so the
# entrypoint starts as root (seatd, /run/user perms) and drops to this user.
[ -x "$ROOTFS/usr/bin/sudo" ] || idie "sudo is not installed (expected via base-devel)"
mkdir -p "$ROOTFS/etc/sudoers.d"
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$C_USER" > "$ROOTFS/etc/sudoers.d/99-$C_USER"
chmod 0440 "$ROOTFS/etc/sudoers.d/99-$C_USER"

# XDG_RUNTIME_DIR. Baked into the image so the entrypoint has one less thing to
# get wrong; it must still recreate it if /run is tmpfs-mounted at runtime.
install -d -m 0700 -o "$C_UID" -g "$C_GID" "$ROOTFS$RUNTIME_DIR"
iinfo "groups: $EXTRA_GROUPS; $RUNTIME_DIR is 0700 $C_UID:$C_GID; NOPASSWD sudo"

# --------------------------------------------------------------------------
istep "copying rootfs-overlay/ over the rootfs"
# --------------------------------------------------------------------------
if [ -d "$OVERLAY_SRC" ]; then
  # The bind mount is 'type fakeowner' — Docker Desktop synthesizes uid/gid, so
  # never trust the ownership that comes across; re-assert it explicitly below.
  cp -a "$OVERLAY_SRC/." "$ROOTFS/" \
    || cp -R --preserve=mode,timestamps "$OVERLAY_SRC/." "$ROOTFS/" \
    || idie "could not copy the overlay tree from $OVERLAY_SRC"
  find "$ROOTFS" -xdev -name '.DS_Store' -type f -delete 2>/dev/null || true

  ( cd "$OVERLAY_SRC" && find . -mindepth 1 ! -name '.DS_Store' -print0 ) \
  | while IFS= read -r -d '' rel; do
      tgt="$ROOTFS/${rel#./}"
      [ -e "$tgt" ] || continue
      case "$rel" in
        ./home/*) chown -h "$C_UID:$C_GID" "$tgt" ;;
        *)        chown -h 0:0 "$tgt" ;;
      esac
    done

  # Everything the overlay drops in /usr/local/bin is a command.
  if [ -d "$ROOTFS/usr/local/bin" ]; then
    find "$ROOTFS/usr/local/bin" -maxdepth 1 -type f -exec chmod 0755 {} +
  fi
  n="$( ( cd "$OVERLAY_SRC" && find . -type f ! -name '.DS_Store' | wc -l ) )"
  iinfo "copied $n files, ownership normalized (root:root, except $C_HOME)"
else
  iwarn "no overlay tree at $OVERLAY_SRC"
fi

if [ -f "$ROOTFS$ENTRYPOINT" ]; then
  chmod 0755 "$ROOTFS$ENTRYPOINT"
  chown 0:0 "$ROOTFS$ENTRYPOINT"
  iinfo "entrypoint $ENTRYPOINT is 0755 root:root"
elif [ "$SKIP_OVERLAY_CHECK" = 1 ]; then
  iwarn "$ENTRYPOINT missing (--skip-overlay-check): the image will not start on its own"
else
  idie "$ENTRYPOINT missing from the rootfs after the overlay copy"
fi

# Home may now contain overlay-provided dotfiles owned by root.
chown -R "$C_UID:$C_GID" "$ROOTFS$C_HOME"

# --------------------------------------------------------------------------
istep "compiling omarchy-egl-probe (decides Hyprland vs fallback at runtime)"
# The entrypoint must not choose Hyprland just because /dev/dri exists -- on a
# vkms-only host it does exist, and Hyprland then runs but paints nothing (black
# VNC screen, live Wayland socket). This probe replicates aquamarine's real test:
# does any EGL device report EGL_DRM_DEVICE_FILE_EXT. See RESEARCH.md section 12.
if [ -f "$ROOTFS/usr/local/src/omarchy-egl-probe.c" ]; then
  if chroot "$ROOTFS" /usr/bin/gcc -O2 -o /usr/local/bin/omarchy-egl-probe \
       /usr/local/src/omarchy-egl-probe.c -lEGL 2>"$WORK/eglprobe.log"; then
    chroot "$ROOTFS" /usr/bin/chmod 0755 /usr/local/bin/omarchy-egl-probe
    iinfo "omarchy-egl-probe compiled"
  else
    iwarn "omarchy-egl-probe failed to compile; the entrypoint will fall back to"
    iwarn "the weaker DRM-node test and may pick Hyprland on a host that cannot"
    iwarn "render it. Compiler output:"
    sed 's/^/         /' "$WORK/eglprobe.log" >&2 || true
  fi
else
  iwarn "rootfs-overlay/usr/local/src/omarchy-egl-probe.c missing — skipping"
fi

istep "stripping (RESEARCH.md §8)"
# --------------------------------------------------------------------------
# Hard assertion first: nothing in the closure may be kernel- or
# hardware-shaped. If any of this exists something dragged in a kernel and the
# disk budget is already blown.
for forbidden in usr/lib/modules usr/lib/firmware lib/modules lib/firmware boot/vmlinuz-linux; do
  if [ -e "$ROOTFS/$forbidden" ]; then
    iwarn "UNEXPECTED: /$forbidden exists ($(du -sxm "$ROOTFS/$forbidden" | awk '{print $1}') MiB) — a kernel/firmware package got pulled in. Removing, but fix packages.conf."
    rm -rf "${ROOTFS:?}/$forbidden"
  fi
done
for bad in $(chroot "$ROOTFS" /usr/bin/pacman -Qq 2>/dev/null | grep -E '^(linux|linux-firmware|linux-headers|linux-t2|nvidia|.*-dkms|broadcom-wl|sof-firmware)$' || true); do
  iwarn "UNEXPECTED package installed: $bad — remove it from packages.conf"
done

# That was the last thing needing a chroot. Drop the pseudo-filesystems NOW, so
# that everything below (getcap -r, the mount assertion, and the host's tar)
# sees a clean tree. getcap -r has no -xdev and would otherwise walk /proc.
umount -R "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" 2>/dev/null || true
for fs in dev proc sys; do
  if mountpoint -q "$ROOTFS/$fs"; then
    umount -l "$ROOTFS/$fs" 2>/dev/null || idie "cannot unmount $ROOTFS/$fs"
  fi
done
MOUNTED="$(printf '%s\n' "$MOUNTED" | grep -vE "^${ROOTFS}/(dev|proc|sys)\$" || true)"
iinfo "pseudo-filesystems unmounted"

# Documentation. Measured: -463 MiB.
rm -rf "${ROOTFS:?}"/usr/share/man \
       "${ROOTFS:?}"/usr/share/doc \
       "${ROOTFS:?}"/usr/share/info \
       "${ROOTFS:?}"/usr/share/gtk-doc \
       "${ROOTFS:?}"/usr/share/help \
       "${ROOTFS:?}"/usr/share/licenses

# Message catalogs, keeping en*. Measured: -376 MiB.
# /usr/share/i18n is deliberately KEPT — locale-gen needs it.
if [ -d "$ROOTFS/usr/share/locale" ]; then
  find "$ROOTFS/usr/share/locale" -mindepth 1 -maxdepth 1 -type d \
       ! -name 'en' ! -name 'en_*' -exec rm -rf {} + 2>/dev/null || true
fi

# Package cache and sync dbs. The mirror bind is already unmounted (asserted
# above), so this only touches real files.
rm -rf "${ROOTFS:?}"/var/cache/pacman/pkg/* 2>/dev/null || true
rm -rf "${ROOTFS:?}"/var/lib/pacman/sync/*  2>/dev/null || true

# .pacnew / .pacsave, logs, scratch.
find "$ROOTFS" -xdev \( -name '*.pacnew' -o -name '*.pacsave' -o -name '*.pacorig' \) -delete 2>/dev/null || true
rm -rf "${ROOTFS:?}"/var/log/* "${ROOTFS:?}"/var/tmp/* "${ROOTFS:?}"/tmp/* 2>/dev/null || true
mkdir -p "$ROOTFS/var/log" "$ROOTFS/var/tmp" "$ROOTFS/tmp"
chmod 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp"

# NOT stripped on purpose:
#   /usr/include (339 MiB) — base-devel and yay are in the set; removing headers
#                            breaks every AUR build.
#   /usr/share/i18n         — locale-gen needs it.
#   /usr/share/fonts        — this is a desktop.

SIZE_AFTER_MIB="$(du -sxm "$ROOTFS" 2>/dev/null | awk '{print $1}')"
iinfo "size: ${SIZE_BEFORE_MIB} MiB -> ${SIZE_AFTER_MIB} MiB (saved $(( SIZE_BEFORE_MIB - SIZE_AFTER_MIB )) MiB)"

# --------------------------------------------------------------------------
istep "scrubbing file capabilities outside Docker's default bounding set"
# --------------------------------------------------------------------------
# Arch's /usr/bin/sway carries cap_sys_nice=ep, which is outside Docker's
# default bounding set, so exec fails with a bare "Operation not permitted".
# Any binary in this image can have the same problem. Docker's default set:
#   chown dac_override fowner fsetid kill setgid setuid setpcap
#   net_bind_service net_raw sys_chroot mknod audit_write setfcap
if [ "$KEEP_CAPS" = 1 ]; then
  iinfo "skipped (--keep-caps)"
elif command -v getcap >/dev/null 2>&1; then
  ALLOWED="chown dac_override fowner fsetid kill setgid setuid setpcap net_bind_service net_raw sys_chroot mknod audit_write setfcap"
  found=0; stripped=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    f="${line%% *}"
    found=$(( found + 1 ))
    bad=""
    for cap in $(printf '%s\n' "$line" | grep -o 'cap_[a-z_]*' | sed 's/^cap_//' | sort -u); do
      case " $ALLOWED " in
        *" $cap "*) : ;;
        *) bad="${bad:+$bad,}$cap" ;;
      esac
    done
    if [ -n "$bad" ]; then
      iwarn "stripping caps from ${f#$ROOTFS}: $bad (outside Docker's default bounding set -> would fail to exec)"
      if setcap -r "$f" 2>/dev/null; then stripped=$(( stripped + 1 ))
      else iwarn "setcap -r failed on ${f#$ROOTFS} — that binary will not exec in a default container"; fi
    else
      iinfo "keeping caps on ${f#$ROOTFS} (all within the default set)"
    fi
  done <<< "$(getcap -r "$ROOTFS" 2>/dev/null || true)"
  iinfo "$found files with capabilities, $stripped scrubbed"
else
  iwarn "getcap not available in the builder — capabilities not audited"
fi

# --------------------------------------------------------------------------
istep "build manifest"
# --------------------------------------------------------------------------
mkdir -p "$ROOTFS/usr/share/omarchy-container"
{
  echo "image:           $IMAGE_NAME"
  echo "built:           $BUILD_DATE"
  echo "source ISO:      omarchy-4.0.1.iso sha256=$ISO_SHA256"
  echo "archive pin:     $ALA_SERVER"
  echo "slim tier:       $( [ "$SLIM" = 1 ] && echo yes || echo no )"
  echo "packages:        $(ls "$ROOTFS/var/lib/pacman/local" | wc -l) entries in the local db"
  echo "rootfs size:     ${SIZE_AFTER_MIB} MiB (was ${SIZE_BEFORE_MIB} MiB before strip)"
  echo
  echo "KNOWN, EXPECTED: 'pacman -Dk' reports 6 missing dependencies, forever."
  echo "  omarchy          -> limine limine-mkinitcpio-hook limine-snapper-sync snapper sddm"
  echo "  omarchy-settings -> plymouth"
  echo "These were --assume-installed at build time on purpose: they are"
  echo "bootloader / snapshot / display-manager packages that a container cannot"
  echo "use, and sddm alone drags in the full xorg-server. -Syu and yay still"
  echo "work; only -Dk complains. Installing them for real costs ~190 MiB."
  echo
  echo "RUNTIME REQUIREMENT: Hyprland 0.56.2 / aquamarine 0.14.0 needs a"
  echo "GBM-capable DRM node. aquamarine's headless backend returns drmFD() =="
  echo "-1 unconditionally (Headless.cpp:132) and Backend.cpp:162-178 only"
  echo "builds the GBM allocator from an implementation with drmFD() >= 0, so"
  echo "headless alone always dies with 'Cannot open backend: no allocator"
  echo "available'. Run with:  --device /dev/dri --group-add video"
  echo "on an x86_64 Linux host (modprobe vkms if there is no real GPU)."
  echo "It will NOT start under Docker Desktop for Mac: the linuxkit kernel has"
  echo "no DRM driver at all (VGEM/VKMS/SIMPLEDRM/UDMABUF all unset)."
} > "$ROOTFS/usr/share/omarchy-container/build-manifest.txt"
cat "$ROOTFS/usr/share/omarchy-container/build-manifest.txt" | sed 's/^/      /'

# --------------------------------------------------------------------------
istep "final assertions"
# --------------------------------------------------------------------------
fail=0
assert_file() {
  if [ -e "$ROOTFS$1" ]; then printf '      ok   %s\n' "$1"
  else printf '      MISSING %s  (%s)\n' "$1" "$2" >&2; fail=1; fi
}
assert_file /usr/bin/Hyprland   "the binary is capital-H; there is no lowercase hyprland"
assert_file /usr/bin/wayvnc     "the VNC server; absent from [offline], comes from the ALA pin"
assert_file /usr/bin/uwsm       "session manager"
assert_file /usr/bin/quickshell "the Omarchy shell"
assert_file /usr/bin/foot       "terminal"
assert_file /usr/local/bin/omarchy-egl-probe "runtime compositor capability probe"
assert_file /usr/bin/sway       "wlroots fallback compositor, for hosts with no DRM-backed EGL device"
assert_file /usr/bin/seatd      "libseat backend; needed or the DRM backend never scans GPUs"
assert_file /usr/bin/Xwayland   "X11 apps under Wayland"
assert_file /usr/bin/hyprctl    "used by the entrypoint to poll for a live output"
assert_file /usr/bin/bash       "entrypoint interpreter"
assert_file /usr/bin/sudo       "passwordless sudo for $C_USER"
assert_file /usr/bin/python3    "interpreter for the websockify shim and Omarchy scripts"
if [ "$WANT_NOVNC" = 1 ]; then
  assert_file /usr/share/novnc/vnc.html      "vendored noVNC web client"
  assert_file /usr/share/websockify/websockify/__main__.py  "vendored websockify python package (NOT ./run, which is a shell wrapper)"
  assert_file /usr/local/bin/websockify      "websockify shim on PATH"
fi
if [ "$SKIP_OVERLAY_CHECK" != 1 ]; then
  assert_file "$ENTRYPOINT" "container entrypoint"
fi

if ! grep -q "^${C_USER}:x:${C_UID}:${C_GID}:" "$ROOTFS/etc/passwd"; then
  printf '      BAD  /etc/passwd has no %s:x:%s:%s entry\n' "$C_USER" "$C_UID" "$C_GID" >&2; fail=1
else
  printf '      ok   /etc/passwd %s:%s:%s\n' "$C_USER" "$C_UID" "$C_GID"
fi
rd_mode="$(stat -c '%a %u %g' "$ROOTFS$RUNTIME_DIR" 2>/dev/null || echo missing)"
if [ "$rd_mode" = "700 $C_UID $C_GID" ]; then
  printf '      ok   %s mode 0700 %s:%s\n' "$RUNTIME_DIR" "$C_UID" "$C_GID"
else
  printf '      BAD  %s is "%s", expected "700 %s %s"\n' "$RUNTIME_DIR" "$rd_mode" "$C_UID" "$C_GID" >&2; fail=1
fi
for forbidden in usr/lib/modules usr/lib/firmware; do
  if [ -e "$ROOTFS/$forbidden" ]; then printf '      BAD  /%s still present\n' "$forbidden" >&2; fail=1
  else printf '      ok   no /%s\n' "$forbidden"; fi
done
if mount | grep -q " on $ROOTFS/"; then
  printf '      BAD  something is still mounted under %s:\n' "$ROOTFS" >&2
  mount | grep " on $ROOTFS/" | sed 's/^/           /' >&2
  fail=1
else
  printf '      ok   nothing mounted under %s\n' "$ROOTFS"
fi
[ "$fail" = 0 ] || idie "final assertions failed — not importing a broken image"

printf '\n  INNER BUILD OK  rootfs=%s MiB\n' "$SIZE_AFTER_MIB"
INNER_BODY
} > "$INNER"

bash -n "$INNER" || die "generated inner script does not parse (this is a bug in build-image.sh)"
ok "inner script generated ($(wc -l < "$INNER" | tr -d ' ') lines), syntax checked"

if [ -n "$EMIT_INNER" ]; then
  cp "$INNER" "$EMIT_INNER"
  printf '\n%swrote %s — stopping (--emit-inner).%s\n' "$C_BOLD" "$EMIT_INNER" "$C_OFF"
  exit 0
fi

# =============================================================================
# STEP 4 — start the builder
# =============================================================================
step "starting the builder container"

if docker ps -a --format '{{.Names}}' | grep -qx "$BUILDER_NAME"; then
  info "removing stale builder '$BUILDER_NAME' (this script always builds in a fresh container)"
  docker rm -f "$BUILDER_NAME" >/dev/null
fi

# --privileged is required for loop-mounting the ISO and the squashfs. It also
# turns off seccomp/apparmor, which is what makes pacman's scriptlets work under
# Rosetta (though --disable-sandbox is still mandatory).
docker run -d \
  --name "$BUILDER_NAME" \
  --platform "$PLATFORM" \
  --privileged \
  -v "$REPO_DIR:/repo:ro" \
  "$BASE_IMAGE" sleep infinity >/dev/null
BUILDER_STARTED=1
ok "builder '$BUILDER_NAME' running ($PLATFORM, --privileged, /repo read-only)"

docker exec "$BUILDER_NAME" mkdir -p /work >/dev/null
docker cp "$INNER" "$BUILDER_NAME:/work/inner.sh" >/dev/null
docker exec "$BUILDER_NAME" chmod 0755 /work/inner.sh >/dev/null
ok "inner script copied to $BUILDER_NAME:/work/inner.sh"

# =============================================================================
# STEP 5 — run the inner build
# =============================================================================
step "running the inner build (install + strip + overlay) — this is the long one"
info "expect roughly 15-40 min: ~900 packages installed under Rosetta emulation"
docker exec "$BUILDER_NAME" bash /work/inner.sh \
  || die "the inner build failed. Re-run with --keep-builder and then:
       docker exec -it $BUILDER_NAME bash
       bash /work/inner.sh"
ok "inner build complete"

# =============================================================================
# STEP 6 — stream rootfs -> image (no tarball ever lands on disk)
# =============================================================================
step "importing the rootfs into $IMAGE_NAME"

if [ -n "$OLD_IMAGE_ID" ] && [ "$KEEP_OLD_IMAGE" = 0 ]; then
  info "deleting the previous $IMAGE_NAME (~${OLD_IMAGE_GIB} GiB) to make room"
  docker rmi -f "$IMAGE_NAME" >/dev/null 2>&1 || warn "could not remove the old $IMAGE_NAME; continuing"
fi

info "streaming tar -> docker import. Nothing is written to the host filesystem;"
info "the archive exists only as bytes in this pipe. Expect several minutes."

# --one-file-system is belt and braces: the mirror bind, /proc, /sys and /dev
# all live on different devices, so even a failed unmount cannot leak into the
# image. --xattrs keeps the file capabilities we deliberately left in place.
set +e
docker exec "$BUILDER_NAME" \
  tar --numeric-owner --one-file-system \
      --xattrs --xattrs-include='security.capability' \
      --warning=no-file-ignored --warning=no-file-changed \
      -C /rootfs -cf - . \
| docker image import \
    --platform "$PLATFORM" \
    --message "omarchy 4.0.1 from omarchy-4.0.1.iso offline mirror + ALA ${ALA_DATE}" \
    -c "CMD [\"$ENTRYPOINT_PATH\"]" \
    -c "USER root" \
    -c "WORKDIR $CONTAINER_HOME" \
    -c "ENV LANG=en_US.UTF-8" \
    -c "ENV XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR_PATH" \
    -c "ENV OMARCHY_RESOLUTION=$DEFAULT_RESOLUTION" \
    -c "ENV OMARCHY_VNC_PORT=$VNC_PORT" \
    -c "ENV OMARCHY_NOVNC_PORT=$NOVNC_PORT" \
    -c "ENV OMARCHY_VNC_PASSWORD=" \
    -c "ENV OMARCHY_ENABLE_NOVNC=1" \
    -c "ENV OMARCHY_OUTPUT=$HEADLESS_OUTPUT" \
    -c "EXPOSE $VNC_PORT $NOVNC_PORT" \
    -c "STOPSIGNAL SIGTERM" \
    -c "LABEL org.opencontainers.image.title=Omarchy org.opencontainers.image.version=4.0.1 org.opencontainers.image.description=\"Omarchy 4.0.1 desktop over VNC, built from the ISO offline mirror\" omarchy.iso.sha256=$ISO_SHA256 omarchy.archive.snapshot=$ALA_DATE omarchy.slim=$SLIM" \
    - "$IMAGE_NAME" >/dev/null
IMPORT_RC=${PIPESTATUS[0]}:${PIPESTATUS[1]}
set -e
case "$IMPORT_RC" in
  0:0) ;;
  *)   die "tar|import pipeline failed (tar:import = $IMPORT_RC).
       If import failed on space, the builder is still holding ~6.5 GiB.
       Free space, then re-run; or use --slim." ;;
esac
ok "imported"

# =============================================================================
# STEP 7 — verify the image
# =============================================================================
step "verifying $IMAGE_NAME"

IMG_BYTES="$(docker image inspect -f '{{.Size}}' "$IMAGE_NAME")"
IMG_ARCH="$(docker image inspect -f '{{.Architecture}}/{{.Os}}' "$IMAGE_NAME")"
info "size $(( IMG_BYTES / 1048576 )) MiB, platform ${IMG_ARCH#*/}/${IMG_ARCH%/*}"
[ "$IMG_ARCH" = "amd64/linux" ] || warn "image records architecture '$IMG_ARCH', expected amd64/linux"

# Cheap smoke tests. None of these need a GPU.
smoke() {
  local label="$1"; shift
  local out
  # The image sets CMD (not ENTRYPOINT), so trailing args replace it directly.
  if out="$(docker run --rm --platform "$PLATFORM" "$IMAGE_NAME" "$@" 2>&1)"; then
    printf '    %sok%s %-24s %s\n' "$C_GRN" "$C_OFF" "$label" "$(printf '%s' "$out" | head -1)"
  else
    printf '    %swarn%s %-24s %s\n' "$C_YEL" "$C_OFF" "$label" "$(printf '%s' "$out" | head -1)" >&2
  fi
}
smoke "user"        id omarchy
smoke "wayvnc"      wayvnc --version
smoke "hyprctl"     hyprctl --version
smoke "pacman"      pacman --version
smoke "entrypoint"  test -x "$ENTRYPOINT_PATH"

# Hyprland is EXPECTED to fail here with "XDG_RUNTIME_DIR is not set!" — that
# error means the dynamic loader resolved every library and the binary ran.
HYPR_OUT="$(docker run --rm --platform "$PLATFORM" -e XDG_RUNTIME_DIR= "$IMAGE_NAME" /usr/bin/Hyprland --version 2>&1 | head -3 || true)"
if printf '%s' "$HYPR_OUT" | grep -q 'XDG_RUNTIME_DIR is not set\|Hyprland'; then
  ok "Hyprland links and executes"
else
  warn "Hyprland smoke test looks wrong: $(printf '%s' "$HYPR_OUT" | head -1)"
fi

# =============================================================================
# Done
# =============================================================================
printf '\n%s==> built %s in %s%s\n' "$C_BOLD$C_GRN" "$IMAGE_NAME" "$(_elapsed)" "$C_OFF"
cat <<EOF

  $(docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}  {{.CreatedSince}}' "$IMAGE_NAME" | head -1)

  ${C_BOLD}Run it — anywhere:${C_OFF}
      docker run --rm -it --platform $PLATFORM --shm-size 2g \\
        -p $VNC_PORT:$VNC_PORT -p $NOVNC_PORT:$NOVNC_PORT \\
        $IMAGE_NAME
      # then: vnc://localhost:$VNC_PORT   or   http://localhost:$NOVNC_PORT/vnc.html
      # or simply: make run

  The entrypoint picks the compositor from what the host can actually render.
  It runs omarchy-egl-probe, which replicates aquamarine's own test: does any
  EGL device report EGL_DRM_DEVICE_FILE_EXT.

    yes -> ${C_BOLD}Hyprland${C_OFF}, i.e. real Omarchy. Needs an x86_64 Linux host with a
           GPU; add --device /dev/dri --group-add video (and seatd is started
           for you). AQ_NO_KMS_REQUIREMENT=1 helps on a render-only node.
    no  -> ${C_BOLD}sway${C_OFF} (wlroots + pixman), over the same wayvnc. You still get
           Omarchy's apps, fonts and theming; only the compositor differs.

  ${C_BOLD}On any Mac the answer is 'no'${C_OFF} and you get sway — including under Colima
  with 'modprobe vkms'. vkms exposes no render node, so mesa enumerates only a
  software EGL device and aquamarine's renderer match cannot succeed; Hyprland
  would start and paint nothing. Docker Desktop has no /dev/dri at all. This is
  measured, not assumed: docs/RESEARCH.md sections 10-12.

  Check which one you got:  make compositor
  Verify it really renders: ./build/verify-image.sh
  Build details:            /usr/share/omarchy-container/build-manifest.txt

EOF
