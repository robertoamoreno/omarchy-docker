# Omarchy 4.0.1 -> Docker. Operator entry points.
# `make` with no target prints the help below.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Read the same .env compose reads, so `make vnc` cannot point at a different
# port than the one actually published. Without this, setting OMARCHY_VNC_PORT
# in .env moved compose's published port but left every URL here on 5900.
-include .env
export

IMAGE       ?= $(or $(OMARCHY_IMAGE),omarchy:4.0.1)
SERVICE     ?= omarchy
ISO         ?= omarchy-4.0.1.iso
VNC_PORT    ?= $(or $(OMARCHY_VNC_PORT),5900)
WEB_PORT    ?= $(or $(OMARCHY_NOVNC_PORT),6080)
export OMARCHY_IMAGE := $(IMAGE)
PROJECT_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
ISO_PATH    := $(PROJECT_DIR)/$(ISO)
DC          := docker compose

.PHONY: help build run stop shell logs vnc web clean inspect-iso compositor

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  image=$(IMAGE)  vnc=$(VNC_PORT)  web=$(WEB_PORT)  iso=$(ISO)"
	@echo "  Override runtime knobs in a .env file next to docker-compose.yml."

build: ## Build $(IMAGE) from the ISO's offline mirror (slow; needs ~16 GB free in the Docker VM)
	@test -f "$(ISO_PATH)" || { echo "ERROR: $(ISO_PATH) not found. The ISO is never copied, but it must be here."; exit 1; }
	@echo "Docker VM space before build (import peaks near 15.7 GiB — prune if reclaimable is large):"
	@docker system df
	@echo
	bash "$(PROJECT_DIR)/build/build-image.sh"

run: ## Start the desktop container in the background
	@docker image inspect "$(IMAGE)" >/dev/null 2>&1 || { echo "ERROR: $(IMAGE) not present. Run 'make build' first."; exit 1; }
	@if [[ "$$(uname -s)" == "Darwin" ]]; then \
	  echo "NOTE: on macOS no VM exposes a DRM-backed EGL device, so the entrypoint"; \
	  echo "      will select the sway fallback rather than Hyprland. You get a"; \
	  echo "      working desktop with Omarchy's apps; see README > Which"; \
	  echo "      compositor you get. Check with: make compositor"; echo; \
	fi
	$(DC) up -d
	@# `up -d` returns 0 even for a container that then exits, so verify.
	@sleep 3
	@state=$$(docker inspect -f '{{.State.Status}}' $$($(DC) ps -q $(SERVICE)) 2>/dev/null || echo missing); \
	if [[ "$$state" != "running" ]]; then \
	  echo "ERROR: container is '$$state', not running. Recent logs:"; echo; \
	  $(DC) logs --tail 40 $(SERVICE) || true; exit 1; \
	fi
	@echo
	@echo "  VNC    vnc://127.0.0.1:$(VNC_PORT)        (make vnc)"
	@echo "  Web    http://127.0.0.1:$(WEB_PORT)/vnc.html  (make web)"
	@echo "  Logs   make logs"

stop: ## Stop and remove the container (the omarchy-home volume survives)
	$(DC) down --remove-orphans

shell: ## Open a login shell in the running container as user omarchy
	$(DC) exec -u omarchy -e TERM="$$TERM" $(SERVICE) bash -l

logs: ## Follow container logs (compositor + wayvnc + noVNC)
	$(DC) logs -f --tail=200

vnc: ## Open the macOS Screen Sharing client against the container
	@if command -v open >/dev/null 2>&1; then \
	  open "vnc://127.0.0.1:$(VNC_PORT)"; \
	else \
	  echo "Not macOS. Point any VNC client at 127.0.0.1:$(VNC_PORT)."; \
	fi

web: ## Open noVNC in the default browser
	@if command -v open >/dev/null 2>&1; then \
	  open "http://127.0.0.1:$(WEB_PORT)/vnc.html?autoconnect=1&resize=remote"; \
	else \
	  echo "Open http://127.0.0.1:$(WEB_PORT)/vnc.html?autoconnect=1&resize=remote"; \
	fi

clean: ## Remove the container, the home volume and the image (keeps the ISO)
	-$(DC) down -v --remove-orphans
	-docker image rm "$(IMAGE)"
	@echo "ISO left untouched: $(ISO_PATH)"

inspect-iso: ## Re-run the read-only ISO inspection (loop-mounts in place, copies nothing)
	@test -f "$(ISO_PATH)" || { echo "ERROR: $(ISO_PATH) not found."; exit 1; }
	@# --privileged is needed for loop-mounting the ISO and the squashfs. This is
	@# an inspection container that exits immediately; the runtime service in
	@# docker-compose.yml is unprivileged. The project dir is bind-mounted :ro,
	@# so nothing here can write to the ISO and nothing is copied.
	@docker run --rm --privileged --platform linux/amd64 \
	  -v "$(PROJECT_DIR)":/host:ro alpine:3.20 sh -euc '\
	    mkdir -p /mnt/iso /mnt/root; \
	    mount -o loop,ro /host/$(ISO) /mnt/iso; \
	    echo "== ISO =="; \
	    ls -l /host/$(ISO); \
	    echo "archiso version: $$(cat /mnt/iso/arch/version)"; \
	    echo "live pkglist:    $$(wc -l < /mnt/iso/arch/pkglist.x86_64.txt) packages (LIVE INSTALLER ONLY, no Hyprland)"; \
	    ls -l /mnt/iso/arch/x86_64/airootfs.sfs; \
	    mount -o loop,ro /mnt/iso/arch/x86_64/airootfs.sfs /mnt/root; \
	    M=/mnt/root/var/cache/omarchy/mirror/offline; \
	    echo; echo "== bundled offline pacman mirror =="; \
	    echo "packages: $$(ls $$M | grep -c pkg.tar.zst)"; \
	    du -sh $$M; \
	    echo; echo "== [offline] stanza, live /etc/pacman.conf =="; \
	    tail -n 4 /mnt/root/etc/pacman.conf; \
	    echo; echo "== key versions in the mirror =="; \
	    for p in hyprland aquamarine mesa quickshell uwsm chromium pacman sddm; do \
	      ls $$M | grep -E "^$$p-[0-9]" | head -n 1; \
	    done; \
	    echo; echo "== installer package sets =="; \
	    wc -l /mnt/root/usr/share/omarchy-iso/*.packages; \
	    echo; echo "== VNC stack in the mirror (expected: 0, must come from the ALA snapshot) =="; \
	    echo "wayvnc/neatvnc/aml matches: $$(ls $$M | grep -cE "^(wayvnc|neatvnc|aml)-[0-9]" || true)"; \
	    umount /mnt/root; umount /mnt/iso'

compositor: ## Show which compositor was selected and why
	@$(DC) exec -T $(SERVICE) omarchy-egl-probe -v || true
	@echo
	@# -x matches the exact process name. -f would both miss (/usr/sbin/sway,
	@# since Arch symlinks /usr/sbin -> /usr/bin) and self-match the checking shell.
	@$(DC) exec -T $(SERVICE) sh -c 'pgrep -ax Hyprland || pgrep -ax sway || echo "no compositor running"'
