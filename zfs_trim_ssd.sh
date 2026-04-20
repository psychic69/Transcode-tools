#!/bin/bash
# zfs_trim_ssd.sh — Trim all ZFS pools backed by SSD/NVMe devices

set -euo pipefail

# Must run as root
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root." >&2
  exit 1
fi

# Strip partition suffix from a device name to get the base disk.
# Handles:
#   nvme0n1p2  -> nvme0n1
#   sda1       -> sda
#   sda        -> sda
strip_partition() {
  local dev="$1"
  if [[ "$dev" =~ ^(nvme[0-9]+n[0-9]+)(p[0-9]+)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "$dev" | sed 's/[0-9]*$//'
  fi
}

echo "==> Scanning ZFS pools for SSD/NVMe-backed vdevs..."

ssd_pools=()

while IFS= read -r pool; do
  has_ssd=false

  while IFS= read -r device; do
    [[ -z "$device" || "$device" == "-" ]] && continue

    # Resolve symlinks to canonical path, then isolate the device name
    canonical=$(realpath "$device" 2>/dev/null || echo "$device")
    dev_name=$(basename "$canonical")
    base_disk=$(strip_partition "$dev_name")

    rotational="/sys/block/${base_disk}/queue/rotational"

    if [[ -f "$rotational" ]]; then
      rot=$(cat "$rotational")
      if [[ "$rot" == "0" ]]; then
        has_ssd=true
        echo "    [SSD vdev] $pool <- /dev/${base_disk} (rotational=0)"
        break
      fi
    else
      # sysfs path not found — log it to help with debugging
      echo "    [WARN] $pool: sysfs not found for base disk '${base_disk}' (from device '$device')"
    fi
  done < <(zpool list -H -v "$pool" | awk 'NF && $1 !~ /^(mirror|raidz[0-9]?|spare|log|cache|NAME|-)$/ {print "/dev/"$1}')

  if $has_ssd; then
    ssd_pools+=("$pool")
    echo "    [SSD] Pool '$pool' queued for trim."
  else
    echo "    [HDD] Pool '$pool' skipped (no SSD vdevs detected)."
  fi

  echo ""

done < <(zpool list -H -o name)

if [[ ${#ssd_pools[@]} -eq 0 ]]; then
  echo "No SSD-backed ZFS pools found. Nothing to trim."
  exit 0
fi

echo "==> Issuing TRIM on ${#ssd_pools[@]} SSD/NVMe pool(s)..."
echo ""

for pool in "${ssd_pools[@]}"; do
  echo -n "    Trimming pool: $pool ... "
  if zpool trim "$pool"; then
    echo "OK"
  else
    echo "FAILED (exit $?)"
  fi
done

echo ""
echo "==> TRIM commands issued. Check trim status with: zpool status -t <pool>"
