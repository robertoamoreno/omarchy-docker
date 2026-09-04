# Omarchy in a container

> ## ⚠️ EXPERIMENTAL — read this before using it
>
> This is a spike, not a product. It was built and verified in a single session
> against **one** ISO (`omarchy-4.0.1`, 2026-08-25) on **one** host (Apple
> Silicon macOS + Colima). Treat every claim here as "true on that setup,
> unverified elsewhere."
>
> Specifically:
> - **The Hyprland path has never been executed.** Not once. Omarchy's own
>   compositor needs a GPU with a DRM render node (or a VM with virgl), and no
>   such host was available while this was written — every test took the **sway**
>   fallback. The code is there and the detection is verified; the Hyprland
>   branch itself is untested. If you have capable hardware, please run
>   `make verify-hyprland` and open an issue with what breaks.
> - **Not hardened.** VNC has **no authentication by default**, runs as a
>   passwordless-sudo user, and is only safe because compose binds to
>   `127.0.0.1`. Do not expose it without reading *Configuration* first.
> - **Not a supported way to run Omarchy.** There is no systemd, so no `uwsm`,
>   no `sddm`, no logind session, no system D-Bus. Parts of Omarchy that assume
>   those are inert. The upstream project has not blessed this.
> - **Pinned and brittle.** Package versions are pinned to an Arch Linux Archive
>   snapshot matching the ISO date. A different ISO needs the date changed and
>   the package list re-checked.
> - **Audio does not work.** VNC carries no audio channel; see *What is not in
>   the image*.
>
> It does work, and `build/verify-image.sh` proves it renders rather than
> asserting it. But it is a starting point to build on, not something to depend
> on.


Turns the `omarchy-4.0.1.iso` installer image into a headless Omarchy desktop
running in Docker, reachable over VNC and in a browser.

> **You supply the ISO.** It is ~5.8 GB, it is not in this repo, and it is
> excluded by `.gitignore` -- download it from [omarchy.org](https://omarchy.org)
> and drop it in the repo root. Nothing here redistributes Omarchy; this is a
> build harness that reads an ISO you already have. See [NOTICE](NOTICE).
>
> **Any release works, not just the one this was written against.** The build
> discovers `omarchy-*.iso` in the repo root, takes the image tag from the
> filename (`omarchy-5.2.0.iso` -> `omarchy:5.2.0`), and derives the Arch Linux
> Archive snapshot from the ISO's own `arch/version` so package versions always
> match its bundled offline mirror. Several ISOs present? It refuses to guess --
> pass `--iso`. Only `4.0.1` has actually been built and verified, so treat a
> newer release as untested rather than unsupported.

- Image: `omarchy:<version-from-ISO>`, `linux/amd64`, ~6.5 GiB unpacked (~4.6 GiB with `--slim`)
- Session: launched directly by the entrypoint -- there is no systemd, so no
  `uwsm` and no `sddm`. The compositor is chosen at startup by what the host can
  actually render (see **Which compositor you get** below): Hyprland 0.56.2 on a
  host with a GPU, sway otherwise. Either way the output is captured by
  wayvnc 0.10.1 on port 5900, plus noVNC on 6080.
  Omarchy's own quickshell shell IS started, so its bar and the `omarchy`
  CLI's IPC (`omarchy plugin list`, `omarchy menu`) work. Widgets needing
  hardware a container lacks stay inert -- see **What is not in the image**.
- Built entirely from the ISO's own offline mirror; only the VNC stack comes
  from the network, pinned to the Arch Linux Archive snapshot of the same date
  as the ISO (2026-08-25), so there is zero version skew

## The key insight

**The ISO does not contain an Omarchy desktop.** `arch/x86_64/airootfs.sfs` is a
stock archiso *live installer* — its 483-package list has no Hyprland in it. The
5.9 GB of squashfs is dominated by a bundled **offline pacman mirror**:

    /var/cache/omarchy/mirror/offline/     1249 packages + offline.db

The installer is a Python/archinstall orchestrator that pacstraps the `omarchy`
metapackage out of that mirror into the target disk.

So `docker import airootfs.sfs` gives you an installer live-CD, not a desktop.
The correct move is to treat `[offline]` as a pacman repo and install the Omarchy
package set into a fresh rootfs. That is what `build/build-image.sh` does:
loop-mount the ISO read-only, loop-mount the squashfs inside it, bind-mount the
mirror over the target's package cache (the ISO installer's own trick, so nothing
is duplicated), run two pacman transactions, strip, then `tar | docker import`.

The 6.2 GB ISO is never copied and the mirror is never extracted.

Run `make inspect-iso` to see all of this for yourself, read-only, in about a
minute.

## Requirements — read this first

**Hyprland needs a real DRM device. Headless is not a GPU-free mode.**

Hyprland 0.56.2 runs on aquamarine 0.14.0, whose headless backend returns
`drmFD() == -1` unconditionally (`src/backend/Headless.cpp:132`), while the GBM
allocator is only ever built from an implementation with `drmFD() >= 0`
(`src/backend/Backend.cpp:162-178`). Hyprland never requests the one backend type
that skips that check. There is no flag, config option or environment variable
that works around it — with no DRM node the compositor aborts at startup:

    ERR  aquamarine: drm: No gpus in scanGPUs.
    CRIT aquamarine: Cannot open backend: no allocator available
    CRIT Critical error thrown: CBackend::create() failed!

There is a **second, stricter** requirement that only shows up once the first is
met, and it is the one that actually bites. Even with a DRM node, aquamarine
builds its renderer via `CDRMRenderer::attempt(backend, drmFD)`, which needs
`EGL_EXT_platform_device` and matches EGL devices on `EGL_DRM_DEVICE_FILE_EXT`
(`src/backend/drm/Renderer.cpp:236,573`). A device without a **render node** --
`vkms` is exactly this -- makes mesa enumerate only a software EGL device, so the
match fails, and Hyprland starts and then paints nothing:

    ERR  aquamarine: CDRMRenderer(drm): Can't create renderer, no matching devices found
    ERR  aquamarine: drm: Failed to update renderer state for Virtual-1 on applyCommit

That is a live Wayland socket and a black VNC screen. The image detects this case
up front with `omarchy-egl-probe` and starts sway instead -- see
[Which compositor you get](#which-compositor-you-get).

| Host | Result |
| --- | --- |
| x86_64 Linux, real GPU | Hyprland. Pass `--device /dev/dri --group-add video` |
| x86_64 Linux, `modprobe vkms` only | starts, cannot render -> **sway fallback** (vkms has no render node) |
| GitHub Actions `ubuntu-latest` | `vkms` is in `linux-modules-extra`, so: sway fallback |
| Colima / Lima on Apple Silicon | sway fallback. Verified 2026-08-30, `docs/RESEARCH.md` §12 |
| Docker Desktop for Mac | sway fallback (no `/dev/dri` at all; linuxkit has no vkms/vgem) |

All of these give you a working desktop over VNC. Only the first gives you
Hyprland, i.e. Omarchy's actual compositor.

Docker Desktop's linuxkit VM (6.10.14-linuxkit) has no `/dev/dri`,
`/sys/class/drm` holds only `version`, and `CONFIG_DRM_VKMS`, `CONFIG_DRM_VGEM`,
`CONFIG_DRM_SIMPLEDRM` and `CONFIG_UDMABUF` are all unset — there is nothing to
modprobe and nothing to pass through. Creating `/dev/dri` nodes by hand does not
help: aquamarine enumerates GPUs through udev/sysfs, not by globbing `/dev/dri`.
Colima/Lima boot an Ubuntu guest that does ship `vkms`, and are the only way to
keep this on a Mac.

Everything downstream of the compositor is fine on the Mac: substituting a
wlroots compositor with the pixman renderer and pointing the same wayvnc 0.10.1
at it produced a live 1280x800 framebuffer over VNC (346 distinct colours,
ticking clock). The VNC layer, port publishing and amd64-under-Rosetta all work.
Only Hyprland is blocked.

**Building the image works anywhere**, including on the Mac — the blocker is
purely at runtime. Build here, `docker save omarchy:4.0.1 | gzip` (~2.7 GB), run
on an x86_64 Linux host.

Also required, wherever you run it:

- Docker Engine with the `linux/amd64` platform available
- ~16 GB free in the Docker VM/host for the build (see [Disk](#disk))
- The ISO at `./omarchy-4.0.1.iso` (6,227,752,960 bytes)

## Quickstart

    make              # list targets
    make inspect-iso  # verify the ISO in place, read-only (optional)
    make build        # slow (867 packages + a 6.2 GiB import); produces omarchy:4.0.1
    make run          # start the container
    make web          # noVNC in a browser
    make vnc          # macOS Screen Sharing
    make logs         # follow the session logs
    make stop         # stop; /home/omarchy survives
    make clean        # remove container, home volume and image

On a Linux host, uncomment the `devices:` / `group_add:` block in
`docker-compose.yml` before `make run`, and set `group_add` to the *numeric* GIDs
that own `/dev/dri/renderD128` on the host (`stat -c %g /dev/dri/renderD128`) —
Arch's group IDs inside the image do not match your host's.

## Connecting

**Browser (noVNC).** <http://127.0.0.1:6080/vnc.html?autoconnect=1&resize=remote>
— `make web` opens exactly that URL.

**macOS Screen Sharing.** Finder → Go → Connect to Server (⌘K) →
`vnc://localhost:5900`, or `make vnc`. Leave `OMARCHY_VNC_PASSWORD` empty:
wayvnc's password authentication uses RSA-AES, which Screen Sharing does not
implement — with a password set, Screen Sharing will fail to negotiate and you
need noVNC (1.4+) or a client that speaks RSA-AES.

**Any other client.** `127.0.0.1:5900`.

Both ports are published on `127.0.0.1` only, because with no password there is
no authentication on 5900. To reach the desktop from another machine, prefer an
SSH tunnel (`ssh -L 5900:127.0.0.1:5900 host`) over setting
`OMARCHY_BIND_ADDR=0.0.0.0`.

## Configuration

Set these in a `.env` file next to `docker-compose.yml`, or in the environment
before `make run`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `OMARCHY_RESOLUTION` | `1920x1080` | Size of the `HEADLESS-1` output (60 Hz) |
| `OMARCHY_VNC_PORT` | `5900` | wayvnc port, in the container and published |
| `OMARCHY_NOVNC_PORT` | `6080` | noVNC/websockify port |
| `OMARCHY_VNC_PASSWORD` | *(empty)* | Empty = no authentication. See the caveat above |
| `OMARCHY_ENABLE_NOVNC` | `1` | Set `0` to skip the noVNC/websockify process |
| `OMARCHY_BIND_ADDR` | `127.0.0.1` | Compose-only: host interface the ports publish on |
| `OMARCHY_COMPOSITOR` | `auto` | `auto` \| `hyprland` \| `sway`. `auto` probes the host; see below |
| `OMARCHY_DEBUG` | `0` | `1` turns on verbose entrypoint + compositor logging |
| `OMARCHY_STARTUP_TIMEOUT` | `60` | Seconds to wait for the compositor socket before failing |
| `OMARCHY_SHELL` | `1` | Start quickshell (Omarchy's bar/menu). `0` for a bare compositor |
| `OMARCHY_MAX_FPS` | `30` | wayvnc frame-rate cap (the `-f` flag, not a config key) |

## Which compositor you get

The entrypoint does **not** decide by looking for `/dev/dri`. A DRM node can be
present and Hyprland still render nothing -- which looks like a working container
with a black VNC screen, the worst thing to hand someone. So the image ships
`omarchy-egl-probe`, which replicates aquamarine's own test:

```
$ docker compose exec omarchy omarchy-egl-probe -v
  EGL device[0]: DRM_DEVICE_FILE=/dev/dri/renderD128
1 EGL device(s); DRM-backed: yes -> Hyprland can build a renderer
```

- **exit 0** -- some EGL device reports `EGL_DRM_DEVICE_FILE_EXT`, so aquamarine
  can build a renderer: the entrypoint starts **Hyprland**, i.e. real Omarchy.
- **exit 1** -- no such device: it starts **sway** instead. wlroots uses the GBM
  platform and tolerates a missing render node, so it renders where Hyprland
  cannot. You get Omarchy's apps, fonts and theming under a different compositor.

Force either with `OMARCHY_COMPOSITOR=hyprland` / `=sway`.

To get real Hyprland you need a host whose mesa exposes a DRM-backed EGL device.
Two ways to have one:

1. **A real GPU** — an x86_64 Linux box with `--device /dev/dri --group-add video`.
2. **A VM with virgl** — `virtio-gpu-gl` backed by virglrenderer gives the guest
   a genuine render node. Plain `virtio-gpu` does not, and neither does `vkms`.

What does NOT work, measured: `vkms` (no render node, so mesa enumerates only a
software EGL device), `vgem` (no mesa driver), and Docker Desktop's linuxkit VM
(no DRM at all). Colima/Lima's `vz` driver offers no virgl option, so on an Apple
Silicon Mac this image falls back to sway. Details in `docs/RESEARCH.md` §12.

> An earlier version of this file claimed "no VM on an Apple Silicon Mac can
> provide one". That was wrong — it generalised from Colima to all VMs.
> [try-omarchy](https://github.com/themartiano/try-omarchy) runs Hyprland on
> Apple Silicon precisely by using QEMU with virgl. See **Prior art**.

Container internals are fixed and everything in this repo agrees on them: user
`omarchy` (uid/gid 1000, passwordless sudo), `$HOME=/home/omarchy`,
`XDG_RUNTIME_DIR=/run/user/1000`, entrypoint
`/usr/local/bin/omarchy-container-init`.

`/home/omarchy` is a named Docker volume (`omarchy-home`), seeded from the image
on first start, so dotfiles, the Chromium profile and the yay build cache survive
rebuilds. `make clean` deletes it.

## Performance

Be realistic about this. It is a functional dev/demo desktop, not a performance
target.

- **No GPU.** With `vkms` (or any host without a usable render node) all GL goes
  through llvmpipe, mesa's software rasteriser. Hyprland's own compositing is
  cheap and stays responsive at 1080p; anything that actually renders — Chromium,
  kdenlive, OBS, `hyprsunset` shaders — is slow. Chromium is the one you will
  notice: page scrolling is visibly software-rendered.
- **On Apple Silicon**, every process is x86_64 under Rosetta on top of that.
  Expect roughly another 2-4x on CPU-bound work. (Moot today — the compositor
  cannot start there at all.)
- **VNC is not free.** wayvnc re-encodes the whole output; at 1920x1080 a busy
  screen costs real CPU on both ends. Dropping `OMARCHY_RESOLUTION` to
  `1280x800` helps more than any other knob.
- **RAM.** Docker Desktop defaults to under 6 GiB for the whole VM. Chromium plus
  a Hyprland session wants more; raise it in Docker Desktop → Resources.

## Troubleshooting

**Grey or uniform screen in the VNC client, session otherwise alive.**
This is the known one. Hyprland ~0.54.2 regressed `ext_image_copy_capture_v1` so
that capture sessions on *headless* outputs advertised no buffer formats and
wayvnc showed a flat grey frame (physical outputs were unaffected). The fix
landed after 0.54.2 and 0.56.2 should contain it, but it has not been confirmed
against this exact pair. Confirm first, then work down the ladder:

1. `make shell`, then `hyprctl monitors` — is `HEADLESS-1` present at the
   expected resolution?
2. Check the wayvnc log for `Capturing output HEADLESS-1`. If it is capturing but
   every pixel is identical, you are hitting the regression, not a config error.
3. Recreate the output at runtime: `hyprctl output create headless`, then restart
   wayvnc bound to the new one with `wayvnc -o HEADLESS-2`.
4. Point wayvnc at the XWayland output instead (loses native Wayland clients).
5. XWayland + x11vnc as a last resort.

**Black screen, VNC connects, and `make logs` shows `Can't create renderer, no
matching devices found`.** You forced `OMARCHY_COMPOSITOR=hyprland` on a host
whose mesa has no DRM-backed EGL device. Run `make compositor` to see the
enumeration. Unset it (or set `=sway`) and the desktop comes back. On `auto` the
entrypoint prevents this case rather than reporting it.

**`Cannot open backend: no allocator available` and the container exits.** No
usable DRM node at all, and Hyprland was forced. `auto` would have chosen sway.

**`libseat: failed to open a seat` / `Failed to open a session`.** The seat
daemon is not up or the user is not in its group. `seatd -g seat` must be running
as root and `omarchy` must be in the `seat` group; the entrypoint does both.
Confirm with `make shell` then `ps -ef | grep seatd` and `id`. Note this is a
*separate* failure from the GPU one — fixing it gets you `Seat opened with
backend 'seatd'` and then the allocator error if there is still no `/dev/dri`.

**`Inconsistency detected by ld.so: rtld.c: 1226: rtld_setup_main_map` appears
once in the terminal.** Cosmetic, and specific to running x86_64 binaries under
Rosetta on Apple Silicon. It is a glibc/Rosetta interaction, not a fault in the
image, and does not occur on an x86_64 Linux host. Nothing is broken by it.

**Permission errors like `Unable to create log dir "/home/omarchy/.cache/..."`.**
Should not happen -- the entrypoint pre-creates the XDG directories owned by
uid 1000 and repairs shallow root-owned paths under `$HOME`. It was caused by
Rosetta creating `$HOME/.cache/rosetta` as root before the privilege drop. If it
reappears, check that `$HOME` is not bind-mounted from the host with a different
owner: `docker compose exec omarchy ls -lad /home/omarchy /home/omarchy/.cache`.

**Chromium exits immediately or every tab crashes.** `/dev/shm` too small.
`shm_size: "2gb"` is set in `docker-compose.yml`; if you lowered it, put it back.

**`hyprland: command not found`.** The binary is `/usr/bin/Hyprland`, capital H.
There is no lowercase alias.

**`pacman -Sy` or `yay` fails with `Landlock is not supported by the kernel` /
`switching to sandbox user 'alpm' failed`.** The image's `/etc/pacman.conf` must
carry `DisableSandbox` under `[options]`. libalpm's sandbox cannot work in this
environment.

**`pacman -Dk` reports 6 missing dependencies** (`limine`,
`limine-mkinitcpio-hook`, `limine-snapper-sync`, `snapper`, `sddm`, `plymouth`).
Expected. Those are bootloader/initramfs/display-manager packages that a
container must not have; they are `--assume-installed` at build time. Upgrades
and yay work normally.

**Rebuild aborts with `invalid or corrupted package`.** The 2026-08-25 Arch
Linux Archive snapshot serves an `aml-1.0.0-1` whose SHA256 does not match its
own `extra.db` (the pool file was rebuilt in place), and pacman fails the whole
transaction. `build/build-image.sh` works around it by fetching that one file and
installing it with `pacman -U` before pulling wayvnc.

**Port already in use.** Set `OMARCHY_VNC_PORT` / `OMARCHY_NOVNC_PORT`; both the
in-container port and the published port follow the variable.

## Disk

Disk is the binding constraint, not CPU or RAM. Measured, not estimated:

| Item | Size |
| --- | --- |
| ISO (bind-mounted read-only, never copied) | 6,227,752,960 B / 5.80 GiB |
| `airootfs.sfs` inside it (loop-mounted in place) | 5.91 GB |
| Offline mirror inside that (never extracted) | 1249 packages |
| Package closure installed into the rootfs | 867 packages, 2.03 GiB of downloads |
| Rootfs as installed | 7486 MiB |
| after stripping man/doc/info/gtk-doc/help/licenses | 7023 MiB (−463) |
| after pruning locales to `en*` | **6647 MiB** (−376) |
| `tar` stream | 6.23 GiB |
| imported layer blob (gzip -1) | 2.69 GiB |

**Peak during `docker import` is roughly 15.7 GiB** — the rootfs, the blob and
the unpacked image snapshot all exist at once. Run `docker system prune` before
`make build`; `make build` prints `docker system df` first so you can see what is
reclaimable. Do not try to move the rootfs onto a macOS bind mount to borrow host
space: Docker Desktop mounts it `fakeowner` and every installed file would land
with the wrong uid/gid.

If you need a smaller image, dropping `libreoffice-fresh`, `obsidian`,
`kdenlive`, `obs-studio`, `moonlight-qt`, `localsend` and `dotnet-runtime`
(keeping Chromium) removes ~1.87 GiB and lands near 4.6 GiB. `/usr/include`
(339 MiB) is deliberately kept — `base-devel` and `yay` are in the set and
removing headers breaks every AUR build.

## What is not in the image

Dropped because a container has no kernel or hardware: `linux*`,
`linux-firmware`, `bluez*`, `cups*` and printing filters, `dosfstools`,
`exfatprogs`, `gnome-disk-utility`, `udiskie`, `brightnessctl`, `ddcutil`,
`bolt`, `asdcontrol`, `wireless-regdb`, `power-profiles-daemon`,
`kernel-modules-hook`, `tzupdate`.

Dropped because they conflict with containerisation: `limine*`, `snapper`
(bootloader/snapshots), `plymouth` (DRM splash), `sddm` (drags in the full
`xorg-server`; the entrypoint starts the session itself instead), `ufw` /
`ufw-docker` (would sever container networking), `qemu-user-static-binfmt`
(writes to the host-global `binfmt_misc`).

Dropped by policy, one flag away in `build/build-image.sh`: `docker`,
`docker-buildx`, `docker-compose`, `lazydocker` (~320 MiB).

Kept on purpose: `xorg-xwayland` (this is how X11 apps run under Wayland),
`alsa-utils` and `pamixer` (Omarchy's own keybindings shell out to them),
`avahi` — which cannot actually be dropped, since it survives as a library
dependency of `libcups` and `tinysparql`. Its daemon is never enabled.

## Repo layout

    omarchy-*.iso            the ISO you supply; discovered automatically,
                             read-only input, never copied or modified
    build/packages.conf      which packages go in, and why each exclusion
    build/verify-image.sh    proves the image renders (captures a frame, counts colours)
    build/rfbgrab.py         minimal RFB client used by verify-image.sh
    build/build-image.sh     builds omarchy:4.0.1 (privileged builder container)
    rootfs-overlay/          copied verbatim into the rootfs at / during the build
                             (entrypoint, pacman.conf, session and wayvnc config)
    docker-compose.yml       the runtime service — unprivileged
    Makefile                 operator entry points
    docs/RESEARCH.md         ISO inspection findings, with corrections

## License

MIT — see [LICENSE](LICENSE).

This repo contains no Omarchy code and redistributes no Omarchy binaries; it
builds from an ISO you supply. Omarchy is MIT licensed, copyright Basecamp /
David Heinemeier Hansson — see [NOTICE](NOTICE) for the full attribution and
the licenses of packages pulled in at build time.

## Verifying the Hyprland path

The sway path is verified end to end: `make verify` starts the image, captures a
real frame over RFB and counts distinct colours (1594 on the reference run).

The **Hyprland path is not verified**. To exercise it you need a host where mesa
enumerates an EGL device with a DRM device file. Check yours:

```
make gpu-check
```

    EGL device[0]: DRM_DEVICE_FILE=/dev/dri/renderD128   <- Hyprland will run
    EGL device[0]: DRM_DEVICE_FILE=(none)                <- sway fallback

Qualifying hosts: a Linux box with a real GPU, or a VM with `virtio-gpu-gl`
backed by virglrenderer. Then:

```
make verify-hyprland      # fails if it falls back to sway
```

Note that Homebrew's QEMU on macOS is built **without** virglrenderer and there
is no `virglrenderer` formula, so this cannot be checked on a stock Mac — that is
exactly why try-omarchy ships its own QEMU build.

## Installing software inside the desktop

`omarchy install ...` works — `omarchy install ai chatgpt` is verified end to
end, installing `openai-codex-desktop` and opening it on the desktop.

Two things had to be true for that, and both are handled at build time:

* **The `[omarchy]` repo is configured.** Omarchy's own packages are published
  at `pkgs.omarchy.org`, not in Arch's `core`/`extra`. Without it you get
  `error: target not found: openai-codex-desktop`. The pacman keyring is
  initialised and populated (`archlinux` + `omarchy`) so those packages verify.
* **`uwsm-app` is shimmed.** Omarchy launches apps through `uwsm-app`, which
  places them in a systemd user scope — 26 of its own scripts do this, including
  every installer that opens what it just installed. With no systemd the real
  binary fails with `Failed to connect to user scope bus`, and since callers
  background it with output discarded, the app silently never appears.
  `/usr/local/bin/uwsm-app` runs the app directly instead, and defers to the
  real binary if a systemd user bus ever exists.

**Run installers from a terminal inside the desktop.** Omarchy's installers open
what they just installed, and a GUI app started without `WAYLAND_DISPLAY` exits
at once *and leaves stale Electron single-instance locks* that block every later
launch with `Failed to create a ProcessSingleton`. The `uwsm-app` shim now
refuses such launches rather than poisoning the app. To install from outside:

```
docker compose exec -e XDG_RUNTIME_DIR=/run/user/1000 -e WAYLAND_DISPLAY=wayland-1 \
  omarchy omarchy install ai chatgpt
```

If you hit the lock before this was fixed:
`rm -f ~/.config/<App>/Singleton*` inside the container.

Caveat: `core`/`extra` are pinned to the ISO's archive snapshot, so Arch
packages install at the versions the image was built against. That is
deliberate — it keeps the installed set consistent — but it means
`pacman -Syu` will not move you forward. Swap the commented live mirror in
`/etc/pacman.d/mirrorlist` if you want a rolling system, and accept the skew.

## Prior art

**[try-omarchy](https://github.com/themartiano/try-omarchy)** solves the adjacent
problem — running Omarchy *on a Mac* — and for that purpose it is better than
this repo in every way that matters. It ships a signed macOS app: an aarch64 Arch
Linux guest running upstream Omarchy, QEMU on Apple's Hypervisor Framework (so
native ARM speed, no emulation), virtio-gpu + **virgl** through ANGLE to Metal,
a native Cocoa window, working audio, clipboard, camera and shared folders.
Because virgl gives the guest a real render node, **Hyprland actually renders**.

If you want to use Omarchy on a Mac, use that, not this.

This repo exists for a different job: Omarchy as a **container** — headless, on a
server, in CI, in the cloud, composed with other services, built from the
official released ISO rather than a source rebuild. It is ~340 KB of scripts
with no app bundle, no code signing and no distribution story.

Two things here were corrected by reading their work: that a VM *can* supply a
render node (via virgl), and that the aarch64 route sidesteps emulation entirely.
