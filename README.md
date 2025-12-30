# Transcode Tools

Utility scripts for managing Docker networking and hardware transcoding on Unraid.

## Scripts

### backup_custom_docker.sh

**Purpose:** Automatically backs up custom Docker network configurations to enable quick recovery after system resets or rebuilds.

**What it does:**
- Scans all custom Docker networks (excluding default bridge, host, and none networks)
- Extracts network configuration details:
  - Network driver type
  - Subnet and gateway settings
  - Parent network interface (for macvlan/ipvlan networks)
- Generates a recovery script (`docker_network_restore.sh`) saved to `/boot/config/` on the Unraid flash drive
- The recovery script includes safety checks to prevent errors if networks already exist

**When to use:**
- After creating or modifying custom Docker networks
- Before major system updates or rebuilds
- As part of regular backup procedures

**Output:**
- Creates `/boot/config/docker_network_restore.sh` - a self-contained script that can recreate all custom networks

---

### renderer.sh

**Purpose:** Identifies and maps all available DRM (Direct Rendering Manager) render devices to their underlying hardware, useful for GPU/hardware transcoding setup.

**What it does:**
- Scans `/dev/dri/` for all render devices (renderD128, renderD129, etc.)
- Maps each render device to its corresponding card device
- Retrieves hardware information:
  - PCI address and bus location
  - Device vendor and device IDs
  - Hardware description via `lspci`
  - Loaded kernel driver
  - Additional udev properties (model ID, vendor ID, PCI class)
- Displays output in a formatted table for easy reading

**When to use:**
- Setting up hardware transcoding (Intel QuickSync, AMD VCE, etc.)
- Troubleshooting GPU device detection
- Determining which `/dev/dri/` device to pass to containers
- Verifying correct drivers are loaded for transcoding hardware

**Output:**
- Formatted display showing all render devices and their associated hardware details

---

## Unraid Context

These scripts are designed to run on **Unraid** systems:

- **backup_custom_docker.sh** - Works with Unraid's Docker subsystem and persistent flash drive (`/boot/config/`)
- **renderer.sh** - Useful when configuring Unraid containers for hardware transcoding (e.g., Plex, Jellyfin, Emby, Handbrake)

Both scripts are non-destructive - they only read system information and generate recovery/diagnostic output.
