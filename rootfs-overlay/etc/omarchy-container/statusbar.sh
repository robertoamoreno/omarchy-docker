#!/usr/bin/env bash
# swaybar status line. A script rather than an inline `status_command`, because
# sway's config parser strips quotes and any format string containing a space
# reaches the shell as multiple arguments.
while true; do
  printf '%s  |  omarchy container\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  sleep 1
done
