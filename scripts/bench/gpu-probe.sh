#!/bin/sh
# Vitrine GPU probe: Vulkan device and vkmark (headless) results to /var/log/vitrine-gpu-probe.log.
LOG=/var/log/vitrine-gpu-probe.log
{
  echo "=== vitrine gpu probe $(date -u +%FT%TZ) on $(uname -r) ==="
  vulkaninfo --summary 2>&1 | grep -E "deviceName|apiVersion|driverName" | head -6
  vulkaninfo 2>/dev/null | sed -n "/GPU0/,/GPU1/p" | grep -E "^\s+VK_(KHR|EXT)_[a-z_0-9]+" | head -80 | tr -s " " | tr "\n" " "; echo
  echo "--- vkmark (headless, 1280x720) ---"
  timeout 600 vkmark -d --winsys headless --size 1280x720 2>&1 | grep -i -E "extension|error|score|^\[" | tail -30
  echo "=== end ==="
} > "$LOG" 2>&1
sync
