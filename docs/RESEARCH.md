# Omarchy 4.0.1 ISO -> Docker: research findings

Established by direct inspection of `omarchy-4.0.1.iso` on 2026-08-30. Treat as
ground truth; do not re-derive.

## 1. ISO layout

    EFI/BOOT/{BOOTIA32.EFI,BOOTx64.EFI}
    arch/boot/x86_64/{vmlinuz-linux-t2, initramfs-linux-t2.img}
    arch/pkglist.x86_64.txt      # 483 pkgs = LIVE ENV ONLY (no Hyprland!)
    arch/x86_64/airootfs.sfs     # 5,914,877,952 bytes, squashfs 4.0, zstd lvl 19
    arch/version                 # 2026.08.25

`file` reports: ISO 9660, DOS/MBR boot sector, label `OMARCHY_202608`.
`hdiutil attach` on macOS FAILS (hybrid MBR). Loop-mount inside Linux works:

    mount -o loop,ro -t iso9660 omarchy-4.0.1.iso /mnt/iso

## 2. The critical insight

**The ISO does not contain an Omarchy desktop.** `airootfs.sfs` is a stock
archiso live installer environment. Its 5.9 GB is dominated by a bundled
**offline pacman mirror**:

    /var/cache/omarchy/mirror/offline/            # 1249 packages (.pkg.tar.zst)
    /var/cache/omarchy/mirror/offline/offline.db
    /var/cache/omarchy/mirror/offline/offline.db.tar.gz
    /var/cache/omarchy/mirror/offline/offline.files{,.tar.gz}

Live-env `/etc/pacman.conf` ends with:

    [offline]
    SigLevel = Never
    Server = file:///var/cache/omarchy/mirror/offline/

The installer is a Python/archinstall orchestrator at `/usr/share/omarchy-iso`
(entry point `/usr/local/bin/omarchy-iso-install` -> `python -m orchestrator.main`).

=> Correct approach is NOT `docker import airootfs.sfs` (that yields an
installer live-CD, not a desktop). It is: use `[offline]` as a pacman repo and
install the Omarchy package set into a fresh rootfs.

## 3. Package sets (from /usr/share/omarchy-iso/)

- `omarchy-base.packages`  — 151 entries, the desktop
- `omarchy-other.packages` — 76 entries, hardware/kernel/driver support
- `package-targets`        — OMARCHY_RUNTIME_PACKAGE=omarchy, etc.

`omarchy` metapackage %DEPENDS%:
    omarchy-keyring omarchy-settings=4.0.1 limine limine-mkinitcpio-hook
    limine-snapper-sync snapper hyprland quickshell uwsm sddm
    xdg-desktop-portal-hyprland wireplumber pipewire gnome-keyring gum jq git
    perl fakeroot pacman-contrib ttf-jetbrains-mono-nerd-basic

## 4. Versions pinned in the offline mirror

    hyprland      0.56.2-1        aquamarine  0.14.0-2     hyprutils 0.14.1-1
    mesa          1:26.2.1-1      systemd     261.2-1      glibc     2.44+...
    quickshell    0.3.1-1         uwsm        0.26.7-1     sddm      0.21.0-7
    xorg-xwayland 24.1.13-1       seatd       0.9.3-1      libinput  1.31.3-1
    chromium      151.0.7922.173  foot        1.27.0-2     pipewire  1:1.6.8-1
    pacman        7.1.0.r9-2

## 5. Compositor constraints (decisive)

> **CORRECTED 2026-08-30 by empirical probe — see section 10. Two claims below
> were wrong. Aquamarine 0.14.0 DOES have a nested Wayland backend. And headless
> is NOT a GPU-free mode: Hyprland cannot start at all without a DRM node.
> Read section 10 before acting on anything in this section.**

Hyprland 0.56 uses **aquamarine**, not wlroots. Aquamarine has **DRM and
headless backends only — there is NO X11 or nested-Wayland backend.**
Therefore: Hyprland CANNOT be nested inside Xvfb/Xephyr. Headless + a Wayland
screen-capture VNC server is the only viable path in a container.

Relevant env vars:
- `AQ_NO_KMS_REQUIREMENT=1`  — drop the KMS requirement (headless GPUs)
- `AQ_DRM_DEVICES`           — colon-separated explicit DRM device list
- `WLR_BACKEND=headless`, `WLR_LIBINPUT_NO_DEVICES=1` — legacy, still honoured
- `LIBGL_ALWAYS_SOFTWARE=1`  — llvmpipe, required (no GPU in container)
- Under uwsm, HYPR*/AQ_* go in `~/.config/uwsm/env-hyprland`
- `prepareFallbackOutput()` auto-creates a headless output when no monitors exist

## 6. VNC layer — NOT in the offline mirror

Absent from `[offline]`: wayvnc, neatvnc, aml, tigervnc, x11vnc, novnc,
websockify, vulkan-swrast. Present: mesa, seatd, xorg-server, xorg-xwayland.

Solution: pin a **second repo to the Arch Linux Archive snapshot of the exact
same date as the ISO**, so there is zero version skew:

    Server = https://archive.archlinux.org/repos/2026/08/25/$repo/os/$arch

Verified present in that snapshot (HTTP 200, packages served from the dated dir):

    wayvnc 0.10.1-1     neatvnc 1.0.1-2      aml 1.0.0-1
    vulkan-swrast 1:26.2.1-1   <-- exactly matches mirror's mesa 26.2.1
    tigervnc 1.16.2-5   x11vnc 1:0.9.17-1    xorg-server-xvfb 21.1.24-1
    waypipe 0.11.0-1    freerdp 2:3.30.0-2   libdisplay-info 0.3.0-1

NOT in that extra snapshot: `novnc`, `python-websockify`. Browser access must
either come from core/AUR or be vendored (noVNC release tarball from GitHub).

## 7. KNOWN RISK: wayvnc grey screen on headless outputs

Hyprland ~0.54.2 regressed `ext_image_copy_capture_session_v1`: the capture
session advertised no buffer formats, so wayvnc showed a grey screen on
HEADLESS outputs (physical outputs still worked). Fix landed in Hyprland git
after 0.54.2. The mirror ships **0.56.2**, which should contain the fix — but
this MUST be verified empirically by connecting a VNC client and checking that
a non-uniform framebuffer is produced.

Refs: hyprwm/Hyprland#8806, hyprwm/Hyprland discussions #7634 / #13845,
any1/wayvnc#326. Prior art: github.com/thariman/wayvnc-omarchy (dual-display
WayVNC for Omarchy; caveat noted there: *static* workspace assignment prevents
Hyprland startup — assign workspaces dynamically).

Fallback ladder if wayvnc fails on 0.56.2:
  1. `hyprctl output create headless` at runtime, bind wayvnc to that output
  2. wayvnc against XWayland output instead
  3. XWayland + x11vnc (loses native Wayland clients)
  4. waypipe (not a VNC server; different UX)

## 8. Host environment constraints

    Host:        macOS darwin 25.6.0, arm64 (Apple Silicon)
    Docker:      28.4.0, Docker Desktop, server aarch64, 8 CPU, 5.787 GiB RAM
    Emulation:   linux/amd64 works (`docker run --platform linux/amd64 alpine uname -m` -> x86_64)
    Docker.raw:  40 GB sparse, ~20.8 GB used, **16.4 GB available**
    Host free:   ~21 GB on /System/Volumes/Data

Disk is the binding constraint. The build MUST NOT copy the mirror or the ISO.
Strategy: loop-mount the ISO read-only from a bind mount, pacman-install into a
directory, strip hard, then stream `tar | docker import`. Peak usage is then
rootfs + imported image only.

Mandatory strip list (container has no kernel/hardware):
  linux* linux-firmware* nvidia* *-dkms limine* snapper plymouth bluez* cups*
  sof-firmware thermald power-profiles-daemon asusctl broadcom-wl
  qemu-user-static-binfmt  + /usr/share/{man,doc,info,locale} + pacman cache

## 9. Performance expectation

x86_64 under Rosetta + llvmpipe software GL. Hyprland compositing will run, but
Chromium/kdenlive/OBS will be slow. This is a functional dev/demo desktop, not
a performance target.


## 10. BLOCKER found by probe (2026-08-30) — Hyprland needs a real DRM node

Empirically established in a 1.66 GB linux/amd64 Arch image pinned to the
2026-08-25 ALA snapshot, running the exact ISO versions (hyprland 0.56.2-1,
aquamarine 0.14.0-2, wayvnc 0.10.1-1).

### The failure

Hyprland aborts before any output logic runs:

    aquamarine: Cannot open backend: no allocator available
    Hyprland:   CBackend::create() failed!

Root cause, read from aquamarine 0.14.0 source:

- `src/backend/Backend.cpp:162-178` — `primaryAllocator` is created ONLY by
  walking implementations for the first with `drmFD() >= 0`, then
  `CGBMAllocator::create(fd)`. No fd and implementations[0] != AQ_BACKEND_NULL
  => logs the error and returns false.
- `src/backend/Headless.cpp:132-138` — `CHeadlessBackend::drmFD()` and
  `drmRenderNodeFD()` both return **-1 unconditionally**.
- Hyprland 0.56.2 `src/Compositor.cpp:309-321` requests exactly
  [HEADLESS mandatory, DRM if-available, WAYLAND fallback]. It never requests
  `AQ_BACKEND_NULL`, the only type that bypasses the allocator check.

=> The headless backend can NEVER supply an allocator. There is no env var,
config option or CLI flag that works around this.

### Why this host cannot satisfy it

Docker Desktop 28.4.0, VM kernel 6.10.14-linuxkit (aarch64):

    /dev/dri                    absent
    /sys/class/drm              contains only `version`
    CONFIG_DRM_VGEM             not set
    CONFIG_DRM_VKMS             not set
    CONFIG_DRM_SIMPLEDRM        not set
    CONFIG_UDMABUF              not set
    virtio_gpu                  built in, but no virtio-gpu device attached

Nothing to modprobe, nothing to pass through. `mknod`ing fake /dev/dri nodes
does not help — aquamarine enumerates GPUs via udev/sysfs (`Session.cpp
scanGPUs`), not by globbing /dev/dri.

Closed escape hatches (both tested):
- `seatd -g seat` fixes the libseat half ("Seat opened with backend 'seatd'")
  but then `drm: No gpus in scanGPUs` — still dies on the allocator.
- Nesting inside a running compositor reaches "Connected to a wayland
  compositor: sway" then fails `Missing protocols` — `Wayland.cpp:146`
  hard-requires `zwp_linux_dmabuf_v1` plus a resolvable main device, which a
  pixman-rendered parent cannot advertise.

Do NOT try to build/insmod vkms.ko for the linuxkit kernel: CONFIG_MODVERSIONS=y
needs the exact linuxkit source tree, CONFIG_MODULE_UNLOAD is off (a bad module
is unrecoverable without a VM restart), and it evaporates on every Docker
Desktop update.

### What IS proven working

The entire stack downstream of the compositor is fine. Substituting **sway 1.12**
(wlroots, `WLR_BACKENDS=headless WLR_RENDERER=pixman` — pixman needs no DRM node)
and pointing the SAME wayvnc 0.10.1 at its HEADLESS-1 output produced a live
1280x800 framebuffer over VNC: **346 distinct colours**, foot's ANSI colour
blocks, a ticking clock, the focus border. So wayvnc + neatvnc +
ext-image-copy-capture + llvmpipe + amd64-under-Rosetta + port publishing all
work here. Only Hyprland cannot start.

Corollary: the original grey-screen question (section 7) is still **unanswered**.
It can only be answered on a host with a DRM node.

### Paths forward

  A. Run where a DRM node exists (recommended). Any x86_64 Linux host — cloud VM,
     Linux desktop, GitHub Actions ubuntu-latest — `modprobe vkms`, then
     `docker run --device /dev/dri --group-add video`, seatd for libseat, and
     `AQ_NO_KMS_REQUIREMENT=1` so aquamarine accepts a render-only node. The
     image BUILD is host-independent and already validated; only the RUNTIME
     host must change. Also drops the Rosetta penalty in section 9.

  B. Swap the Docker runtime on this Mac. Colima/Lima boot an Ubuntu guest whose
     kernel ships vkms/vgem in linux-modules-extra. Neither is installed today.
     Unverified — worth a short spike.

  C. Stay on Docker Desktop, drop Hyprland. Ship a wlroots compositor with the
     pixman renderer (sway/labwc/cage) — proven working end to end here. That is
     a Wayland desktop over VNC, but it is NOT Omarchy: the whole `omarchy`
     metapackage (hyprland, quickshell, uwsm, xdg-desktop-portal-hyprland)
     becomes moot.

## 11. Build-side facts confirmed by probe (2026-08-30)

The rootfs build itself is fully validated — 867 packages installed from
`[offline]` alone, exit 0, all 29 hooks ran.

    FULL canonical closure   925 pkgs   2.16 GiB dl   7.35 GiB installed
    CONTAINER set            867 pkgs   2.03 GiB dl   6.77 GiB installed
    after stripping                                   6.5  GiB
    tar | gzip -1 layer blob                          2.69 GiB

Every dependency resolves offline. Not one package is missing from `[offline]`.

Traps that WILL bite (all verified):
- `pacman` COPIES packages out of a `file://` repo into the cachedir. Naive
  install duplicates 2 GiB. Bind-mount the mirror read-only over the target's
  `/var/cache/pacman/pkg` — this is the ISO installer's own trick
  (`_mount_offline_package_cache`, phases_impl.py:640). Unmount before tarring.
- `--disable-sandbox` is mandatory at build time (alpm sandbox dies with
  `error restricting syscalls via seccomp: 22!` under Rosetta, and
  `Landlock is not supported by the kernel!` in a chroot), and `DisableSandbox`
  must be written into the SHIPPED image's `/etc/pacman.conf` or in-container
  `pacman`/`yay` is dead on arrival.
- `--assume-installed plymouth/sddm` alone saves nothing — both are ALSO explicit
  lines in omarchy-base.packages (103, 116). Remove from the explicit list too.
- `avahi` cannot be dropped; it survives as a hard lib dep of libcups and
  tinysparql. Harmless as a library — just never enable the daemon.
- ALA POISON PILL: `aml-1.0.0-1-x86_64.pkg.tar.zst` in the 2026-08-25 snapshot
  does not match the SHA256 in that snapshot's `extra.db` (pool file rebuilt in
  place). pacman aborts the whole transaction. `aml` is a wayvnc dep, so the real
  build hits this. Workaround: curl it and `pacman -U` it before `pacman -S
  wayvnc` (`-U` skips the db checksum). wayvnc, neatvnc, hyprland, vulkan-swrast
  are all checksum-clean in the same snapshot.
- The binary is `/usr/bin/Hyprland` (capital H). No lowercase `hyprland` exists.
- Arch's `/usr/bin/sway` carries `cap_sys_nice=ep`, outside Docker's default
  bounding set — exec fails with a bare "Operation not permitted". `setcap -r`
  fixes it. Check `getcap` on every binary the image ships.
- `wlroots` uses `WLR_BACKENDS` (plural), not `WLR_BACKEND`.
- Hyprland needs `debug { enable_stdout_logs = true }` or early aborts are silent.
- Docker Desktop's macOS bind mount is `type fakeowner` — you cannot relocate the
  rootfs build onto the host's larger free space, every file lands with wrong
  uid/gid. Prune the Docker VM instead.

## 12. PATH B SPIKE RESULT (2026-08-30) — Colima + vkms

**Verdict: Hyprland STARTS but CANNOT RENDER. Real Omarchy still needs a GPU host.**

Setup that got furthest (all reproducible):

    brew install colima            # colima 0.10.3 + lima 2.2.0
    colima start --vm-type vz --vz-rosetta --cpu 6 --memory 6 --disk 40 \
                 --mount-type virtiofs --mount <repo>:w
    colima ssh -- sudo apt-get install -y linux-modules-extra-$(uname -r)
    colima ssh -- sudo modprobe vkms
    docker run --device /dev/dri ...
    # in-container, as a NON-root user:
    SEATD_VTBOUND=0 seatd -g seat &

Colima's guest is **Ubuntu 24.04, kernel 6.8.0-117-generic**, which unlike
linuxkit has `CONFIG_DRM_VKMS=m` and `CONFIG_DRM_VGEM=m`. `modprobe vkms` yields
`/dev/dri/card0` with connector `Virtual-1` + `Writeback-1`. `vgem` additionally
yields `card1` + `renderD128`.

### Progress made vs Docker Desktop

`SEATD_VTBOUND=0` is essential — without it seatd creates a *VT-bound* seat and
every device open fails with `libseat: Couldn't open device at /dev/dri/card0`,
which then manifests misleadingly as `DRM_PRIME_CAP_IMPORT unsupported`.

With it, aquamarine gets much further on vkms:

    drm: Atomic supported, using atomic for modesetting
    drm: found 1 CRTCs ... Plane 31 type 1 ... Plane 34 type 2
    drm: Connector gets name Virtual-1 / connection state: 1

Hyprland **survives `CBackend::create()`** and serves a `wayland-1` socket. On
Docker Desktop it aborted here. That part of the problem is solved.

### The new, harder blocker

    ERR: CDRMRenderer(drm): Can't create renderer, no matching devices found
    ERR: drm: initMgpu: no renderer
    ERR: drm: Failed to update renderer state for Virtual-1 on applyCommit

Both call sites in aquamarine 0.14.0 use the **fd** overload:

    src/backend/drm/DRM.cpp:669  and :1237
      CDRMRenderer::attempt(backend, gpu->renderNodeFd >= 0 ? gpu->renderNodeFd : gpu->fd)

which goes through `CDRMRenderer::attempt(backend, int drmFD)`
(Renderer.cpp:573). That REQUIRES `EGL_EXT_platform_device` and calls
`eglDeviceFromDRMFD()` (Renderer.cpp:236), which enumerates EGL devices and
matches `eglQueryDeviceStringEXT(d, EGL_DRM_DEVICE_FILE_EXT)` against the DRM
device. The GBM overload at Renderer.cpp:615 exists but **is never used by the
DRM backend**, so there is no env var or config to reach it.

Measured what mesa 26.2.1 actually enumerates in this container:

    mesa enumerates 1 EGL device(s)
      device[0]: DRM_DEVICE_FILE=(none)  RENDER_NODE=(none)
                 exts: EGL_MESA_device_software EGL_EXT_device_drm_render_node

One software device, no DRM file. `eglDeviceFromDRMFD()` can therefore **never**
match, so `attempt(drmFD)` always returns nullptr. This is structural, not a
tuning problem.

Note this is NOT a GBM limitation. GBM+EGL on vkms works fine — verified with a
40-line C program:

    opened /dev/dri/card0 -> gbm_create_device -> backend 'drm'
    OK: EGL 1.5 vendor='Mesa Project'   => GBM+EGL WORKS on /dev/dri/card0

(`MESA_LOADER_DRIVER_OVERRIDE=kms_swrast` BREAKS it — eglInitialize 0x3001.
Leave the driver on default.)

### wlroots does not have this limitation

sway 1.12 on the same vkms device, same container, renders for real:

    [wlr] Initializing DRM backend for /dev/dri/card0 (vkms)
    [wlr] Found 1 DRM CRTCs / Found 2 DRM planes
    [wlr] DRM device '/dev/dri/card0' has no render node, falling back to primary node
    [wlr] Created GL FBO for buffer 1024x768
    [wlr] connector Virtual-1: Requesting modeset / 'Virtual-1' connected

wlroots uses the GBM platform and explicitly tolerates a missing render node;
aquamarine does not. Required env: **`WLR_RENDERER_ALLOW_SOFTWARE=1`** (without
it wlroots refuses with "Software rendering detected"), and note it is
`WLR_BACKENDS` (plural). Arch's `/usr/bin/sway` needs `setcap -r` first.

### What would actually unblock Hyprland

An EGL device with a DRM node — i.e. a real GPU render node, or virtio-gpu with
virgl. Apple's Virtualization.framework exposes virtio-gpu as KMS-only (no
virgl, no render node), and Lima/QEMU 3D accel is unsupported on macOS. So **no
VM on this Mac can provide one.** Path A (an x86_64 Linux host with a GPU) is
the only route to Hyprland proper.

### Consequence for the image design

The rootfs build (section 11) is unaffected and remains valid. Only the runtime
compositor choice is host-dependent, so the entrypoint should DETECT the
capability and pick:
  - EGL device with a DRM node present  -> Hyprland (real Omarchy)
  - otherwise                           -> sway/labwc fallback (Omarchy's apps,
                                           fonts and theming, different WM)
