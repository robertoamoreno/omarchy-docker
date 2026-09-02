export const meta = {
  name: 'omarchy-iso-to-docker',
  description: 'De-risk and author an Omarchy 4.0.1 ISO -> GUI/VNC Docker image build',
  phases: [
    { title: 'Probe', detail: 'empirically test the two assumptions the whole design rests on' },
    { title: 'Author', detail: 'write build script, runtime overlay, orchestration, package selection' },
    { title: 'Review', detail: 'adversarial integration + disk-budget review' },
  ],
}

// Repo root. Override with Workflow({args: {repo: '/path/to/repo'}}).
const REPO = (typeof args === 'object' && args && args.repo) || process.env.PWD || '.'
const CTX = `
You are working in ${REPO} on a macOS arm64 host with Docker Desktop.
FIRST ACTION: read ${REPO}/docs/RESEARCH.md in full. It is verified ground truth
about the Omarchy 4.0.1 ISO, gathered by direct inspection. Do not re-derive it,
do not contradict it without hard evidence, and do not re-run the inspection.

Hard constraints you must respect:
- Everything Omarchy is linux/amd64. The host is arm64. Always pass --platform linux/amd64.
- Docker VM has ~16.4 GB free; host has ~21 GB free. Disk is THE binding constraint.
- The 6.2 GB ISO must NEVER be copied. Bind-mount ${REPO} read-only and loop-mount in place.
- The offline mirror must NEVER be extracted to the host or into a build context.
`

phase('Probe')

const PROBE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['works', 'summary', 'evidence', 'recommendation'],
  properties: {
    works: { type: 'boolean', description: 'did the thing under test actually work' },
    summary: { type: 'string' },
    evidence: { type: 'string', description: 'concrete command output proving the verdict' },
    recommendation: { type: 'string', description: 'what the real build must do as a result' },
    gotchas: { type: 'array', items: { type: 'string' } },
  },
}

const probes = await parallel([
  () => agent(`${CTX}

PROBE 1 — the highest risk in this project. Settle it empirically.

QUESTION: Does wayvnc 0.10.1 produce a real (non-grey) framebuffer from Hyprland
0.56.2 running headless with the aquamarine backend, inside a container?

Section 7 of RESEARCH.md documents a regression where headless outputs gave a grey
screen. We believe 0.56.2 has the fix. PROVE OR DISPROVE IT. Do not build the full
Omarchy image for this — build the smallest possible test image.

Method:
- Base a small linux/amd64 Arch image. Pin BOTH repos to the archive snapshot so
  versions match the ISO exactly:
    Server = https://archive.archlinux.org/repos/2026/08/25/$repo/os/$arch
  (core + extra). Install: hyprland wayvnc mesa vulkan-swrast seatd xorg-xwayland
  foot dbus. Keep it lean.
- Run Hyprland headless. Try AQ_NO_KMS_REQUIREMENT=1, WLR_BACKEND=headless,
  WLR_LIBINPUT_NO_DEVICES=1, LIBGL_ALWAYS_SOFTWARE=1, a valid XDG_RUNTIME_DIR
  (mode 0700), and a minimal hyprland.conf with an explicit headless monitor.
  Run as a NON-root user - Hyprland refuses to run as root.
- Confirm the compositor is alive: 'hyprctl monitors' must list an output.
- Start wayvnc on 0.0.0.0:5900 bound to that output.
- CRITICALLY: actually capture a frame and prove it is not uniform grey. Use a VNC
  client you install in the same container or a sibling container (e.g. python with
  a tiny RFB handshake, or vncsnapshot/tigervnc's vncviewer in raw mode) and compute
  the pixel variance / count of distinct colours. Launch a visible app (foot terminal,
  or set a coloured background) first so there is something to see.
- A screenshot that is one flat colour = FAILED, report works:false.

If wayvnc fails, walk the fallback ladder in section 7 and report which rung works.
Report the exact env vars, config, and command lines that worked.
Clean up all images/containers you create (docker rmi / docker system prune -f for
your own artifacts) before returning - disk is scarce.`,
    { label: 'probe:wayvnc-headless', phase: 'Probe', schema: PROBE_SCHEMA }),

  () => agent(`${CTX}

PROBE 2 — settle whether the offline mirror can actually build a rootfs.

QUESTION: Can pacman resolve and install the Omarchy desktop package set into a
fresh rootfs using ONLY the ISO's [offline] repo, and what is the resulting size?

Method:
- Run a --privileged --platform linux/amd64 container with ${REPO} bind-mounted
  read-only at /iso. Loop-mount the ISO at /mnt/iso, then loop-mount
  /mnt/iso/arch/x86_64/airootfs.sfs at /mnt/root (squashfs-tools). Do NOT unsquashfs
  the whole thing - mount it.
- Write a pacman.conf whose only repo is:
    [offline]
    SigLevel = Never
    Server = file:///mnt/root/var/cache/omarchy/mirror/offline/
- Read /mnt/root/usr/share/omarchy-iso/omarchy-base.packages (151 entries) and the
  'omarchy' metapackage deps (RESEARCH.md section 3).
- Decide the CONTAINER package set: base + the desktop, MINUS everything meaningless
  in a container. Section 8 of RESEARCH.md lists the strip categories. Be decisive
  and justify exclusions.
- Use 'pacman --root ... -Sp' (print URIs) and/or -Sw dry runs to resolve the full
  transitive closure WITHOUT installing. Report:
    * whether every dependency resolves offline (list ANY that do not)
    * the total download size and installed size of the closure
    * which packages from omarchy-base.packages you dropped and why
    * whether the 'omarchy' metapackage's limine/snapper/sddm deps force unwanted
      packages, and whether --assume-installed is needed
- If a full dry run is cheap enough, do a real install into a tmpfs/dir and report
  actual du -sh, then delete it. Only if it fits the disk budget.

Return a concrete, ordered package list the build script can use verbatim.
Clean up everything you create.`,
    { label: 'probe:offline-pacstrap', phase: 'Probe', schema: PROBE_SCHEMA }),
])

const [vnc, pac] = probes
log(`Probe results — wayvnc headless: ${vnc ? (vnc.works ? 'WORKS' : 'FAILED') : 'no result'}; offline pacstrap: ${pac ? (pac.works ? 'WORKS' : 'FAILED') : 'no result'}`)

const findings = `
=== PROBE FINDINGS (empirical, from this run — authoritative) ===

PROBE 1: Hyprland 0.56.2 headless + wayvnc
  works: ${vnc ? vnc.works : 'UNKNOWN — probe failed to return'}
  ${vnc ? vnc.summary : ''}
  evidence: ${vnc ? vnc.evidence : ''}
  what the build must do: ${vnc ? vnc.recommendation : 'assume wayvnc is unproven; make the VNC layer swappable'}
  gotchas: ${vnc && vnc.gotchas ? vnc.gotchas.join(' | ') : 'none reported'}

PROBE 2: offline mirror pacstrap
  works: ${pac ? pac.works : 'UNKNOWN — probe failed to return'}
  ${pac ? pac.summary : ''}
  evidence: ${pac ? pac.evidence : ''}
  what the build must do: ${pac ? pac.recommendation : 'verify dependency closure before committing to a full build'}
  gotchas: ${pac && pac.gotchas ? pac.gotchas.join(' | ') : 'none reported'}
`

phase('Author')

const INTERFACE = `
=== FROZEN INTERFACE — every file must agree on these. Do not invent variants. ===
  image name          omarchy:4.0.1
  platform            linux/amd64
  container user      omarchy, uid 1000, gid 1000, passwordless sudo
  home                /home/omarchy
  XDG_RUNTIME_DIR     /run/user/1000   (mode 0700, owned by omarchy)
  VNC port            5900   (wayvnc, bound 0.0.0.0)
  noVNC/web port      6080
  headless output     HEADLESS-1, 1920x1080@60
  entrypoint          /usr/local/bin/omarchy-container-init
  runtime tunables    OMARCHY_RESOLUTION (default 1920x1080), OMARCHY_VNC_PORT,
                      OMARCHY_NOVNC_PORT, OMARCHY_VNC_PASSWORD (empty = no auth),
                      OMARCHY_ENABLE_NOVNC (default 1)
  build script        build/build-image.sh   (bash, set -euo pipefail)
  overlay tree        rootfs-overlay/  — copied verbatim into the rootfs at /
  ISO path            ./omarchy-4.0.1.iso, bind-mounted read-only, NEVER copied
  archive snapshot    https://archive.archlinux.org/repos/2026/08/25/$repo/os/$arch
`

const authored = await parallel([
  () => agent(`${CTX}
${findings}
${INTERFACE}

TASK: Write ${REPO}/build/build-image.sh — the whole image build, disk-safe.

It must:
1. Preflight: assert docker is running, assert the ISO exists and its size/sha
   matches, assert linux/amd64 emulation works, and assert enough free space in the
   Docker VM (fail loudly with the numbers if not).
2. Run ONE --privileged --platform linux/amd64 builder container with the repo
   bind-mounted read-only. Inside it: loop-mount the ISO, loop-mount airootfs.sfs,
   point pacman at the [offline] file:// repo AND the pinned archive snapshot for
   the VNC packages, and install into /rootfs.
3. Strip hard (RESEARCH.md section 8): no kernel, no firmware, no dkms, no nvidia,
   no docs/man/info/locale, no pacman cache, no .pacnew. Report size before/after.
4. Copy rootfs-overlay/ over the rootfs, create the omarchy user, set up
   XDG_RUNTIME_DIR, and make the entrypoint executable.
5. Stream the result into the image WITHOUT landing a tarball on disk:
   tar -C /rootfs -c . | docker import - with the right CMD/ENV/EXPOSE metadata.
   Do it so peak disk = rootfs + image, nothing more.
6. Clean up the builder container even on failure (trap).
7. Be re-runnable and idempotent, with a --keep-builder debug flag and clear
   step-by-step progress output.

Write the file. Make it executable. Report what you wrote and any assumption you
had to make. Do not run the full build - authoring only.`,
    { label: 'author:build-script', phase: 'Author' }),

  () => agent(`${CTX}
${findings}
${INTERFACE}

TASK: Write the runtime layer under ${REPO}/rootfs-overlay/.

Deliverables:
1. usr/local/bin/omarchy-container-init — PID 1 supervisor, bash, no systemd.
   Order: create/chown XDG_RUNTIME_DIR -> start dbus session -> export the
   aquamarine/Hyprland headless env -> launch Hyprland as user omarchy -> wait for
   the compositor socket and for 'hyprctl monitors' to report an output -> start
   wayvnc on the headless output -> optionally start noVNC/websockify.
   It must forward SIGTERM/SIGINT, reap zombies, and if any supervised process dies
   the container must exit non-zero with a useful log line. No silent hangs, no
   'sleep 5 and hope'. Poll for readiness with a timeout and a clear error.
2. etc/omarchy-container/hyprland.conf — minimal Hyprland config for headless:
   explicit HEADLESS-1 monitor at the requested resolution, software-rendering
   friendly (no blur/shadows/animations), a terminal on a keybind, and an autostart
   so a fresh connection shows something rather than a blank desktop.
   NOTE the prior-art caveat: STATIC workspace assignment prevents Hyprland startup
   under this setup - assign dynamically.
3. etc/omarchy-container/wayvnc.conf — wayvnc config (address, port, auth,
   explicit xkb_layout=us / xkb_rules=evdev, which improves VNC key handling).
4. Whatever env file the design needs (e.g. uwsm env-hyprland equivalent). Note
   uwsm needs a systemd user session that we do NOT have - launch Hyprland directly
   and say so in a comment.

Honour PROBE 1's findings above about what actually worked. If PROBE 1 reported
failure, implement its working fallback instead and leave the wayvnc path behind a
switch. Author files only - do not run a build.`,
    { label: 'author:runtime-overlay', phase: 'Author' }),

  () => agent(`${CTX}
${findings}
${INTERFACE}

TASK: Write the operator-facing layer.

1. ${REPO}/docker-compose.yml — service 'omarchy', platform linux/amd64, ports
   5900 and 6080, sensible shm_size (Chromium needs it), a named volume for
   /home/omarchy so user state survives, tmpfs for /run and /tmp, and the
   capabilities/security-opt actually required (justify each in a comment; do NOT
   reflexively use privileged - the RUNTIME container should not need it even though
   the BUILDER does).
2. ${REPO}/Makefile — targets: build, run, stop, shell, logs, vnc (open a VNC client
   at the right URL on macOS), web (open noVNC in a browser), clean, and
   'inspect-iso' (re-run the read-only ISO inspection). Each target one line of help.
3. ${REPO}/README.md — what this is, the key insight that the ISO is an installer
   plus an offline mirror (not a desktop), quickstart, how to connect over VNC from
   macOS (Finder 'Go > Connect to Server' vnc://localhost:5900, and noVNC in a
   browser), the resolution/password env knobs, a candid PERFORMANCE section
   (x86_64 under Rosetta + llvmpipe software GL - the compositor is fine, Chromium
   is slow), a TROUBLESHOOTING section led by the grey-screen symptom, and a DISK
   section with the real numbers. Be accurate and concise; no marketing tone.

Author files only - do not run a build.`,
    { label: 'author:orchestration-docs', phase: 'Author' }),

  () => agent(`${CTX}
${findings}
${INTERFACE}

TASK: Produce ${REPO}/build/packages.conf — the definitive, commented package
selection, as shell-sourceable arrays.

Base it on PROBE 2's resolved list if the probe succeeded; otherwise derive it
yourself by mounting the ISO read-only and reading
/usr/share/omarchy-iso/omarchy-base.packages.

Define:
  OMARCHY_PKGS_BASE      minimal Arch base that makes sense in a container
  OMARCHY_PKGS_DESKTOP   Hyprland/Omarchy desktop from [offline]
  OMARCHY_PKGS_VNC       from the pinned archive snapshot (wayvnc, neatvnc, aml,
                         vulkan-swrast, ...)
  OMARCHY_PKGS_EXCLUDE   explicitly rejected, EACH with a one-line reason
  OMARCHY_ASSUME_INSTALLED  any --assume-installed needed to stop the 'omarchy'
                         metapackage dragging in limine/snapper/bootloader junk

Rules: every exclusion needs a reason. Keep anything a user would actually notice
missing from a desktop (terminal, file manager, fonts, editor, browser). Drop
anything that touches kernel, firmware, bootloader, disk, or physical hardware.
Flag any package you are unsure about rather than silently dropping it.
Also state the expected installed size and how it fits the 16.4 GB budget.

Author the file only - do not run a build.`,
    { label: 'author:package-selection', phase: 'Author' }),
])

phase('Review')

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['blocking', 'findings'],
  properties: {
    blocking: { type: 'boolean', description: 'true if the build would fail as written' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['severity', 'file', 'problem', 'fix'],
        properties: {
          severity: { type: 'string', enum: ['blocker', 'major', 'minor'] },
          file: { type: 'string' },
          problem: { type: 'string' },
          fix: { type: 'string' },
        },
      },
    },
    verdict: { type: 'string' },
  },
}

const reviews = await parallel([
  () => agent(`${CTX}
${findings}
${INTERFACE}

TASK: Adversarial integration review. Four agents wrote these files independently
and have NOT seen each other's work:
  build/build-image.sh, build/packages.conf,
  rootfs-overlay/** , docker-compose.yml, Makefile, README.md

Read all of them. Hunt specifically for the failure mode of independent authoring:
interfaces that do not line up. Check EVERY one of these concretely:
- Does build-image.sh actually source build/packages.conf, with the variable names
  packages.conf defines? Exact spelling.
- Do the paths the entrypoint reads (/etc/omarchy-container/*) match the paths the
  overlay actually installs, and does build-image.sh copy the overlay to the right
  place with the right mode/ownership?
- Are user/uid/gid/home/XDG_RUNTIME_DIR identical everywhere?
- Do ports agree across compose, Makefile, README, wayvnc.conf and the entrypoint?
- Do the env var names in README/compose match what the entrypoint actually reads?
- Does the entrypoint reference any binary that packages.conf never installs?
  (this is the most likely real bug - check every command invoked)
- Does anything assume systemd, systemctl, uwsm, or a login session that does not exist?
- Would Hyprland be launched as root anywhere? It refuses to run as root.
- Does the runtime container need a capability that compose does not grant
  (/dev/dri, SYS_ADMIN, seccomp for the compositor)?

Report only defects you can point at in the actual file text. For each: severity,
file, the concrete problem, and the concrete fix. Do not restate the design back
to me and do not report style opinions.`,
    { label: 'review:integration', phase: 'Review', schema: REVIEW_SCHEMA }),

  () => agent(`${CTX}
${findings}
${INTERFACE}

TASK: Disk-budget and failure-mode review. This build runs on a machine with
16.4 GB free in the Docker VM and ~21 GB free on the host. A build that fills the
disk is the single most likely way this project fails, and it fails destructively
(a full Docker.raw wedges Docker Desktop).

Read build/build-image.sh and build/packages.conf and answer concretely:
- Trace peak disk usage step by step. Give real numbers. Does the ISO ever get
  copied? Does the mirror ever get extracted? Does a tarball ever land on disk?
  Does 'docker import' from a pipe actually avoid a temp file, or does the daemon
  spool it? Verify rather than assume.
- Does the script clean up the builder container on EVERY exit path, including
  SIGINT mid-build?
- Is the estimated installed size credible against the 16.4 GB budget, with margin?
- What happens if the disk fills at the worst moment, and does the script detect
  and fail cleanly rather than corrupting state?
- Is the loop-mount teardown ordered correctly (squashfs before iso9660)? A leaked
  loop device in the Docker VM persists.
- Does the preflight actually measure free space in the Docker VM (not the host)?

Report defects with severity, file, problem, and fix. Numbers, not adjectives.`,
    { label: 'review:disk-budget', phase: 'Review', schema: REVIEW_SCHEMA }),
])

const all = reviews.filter(Boolean).flatMap(r => r.findings || [])
const blockers = all.filter(f => f.severity === 'blocker')
log(`Review complete: ${all.length} findings, ${blockers.length} blockers`)

return {
  probes: { wayvnc: vnc, pacstrap: pac },
  authored: authored.filter(Boolean).length,
  findings: all,
  blockers,
  verdicts: reviews.filter(Boolean).map(r => r.verdict),
}
