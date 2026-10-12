#!/usr/bin/env bash
# ==============================================================================
# ThinkPad P53 (Intel UHD 630 + NVIDIA Quadro T1000) Power Management Setup
# ==============================================================================
# This script configures Linux / KDE Plasma 6 (Wayland) to keep the NVIDIA
# Quadro T1000 GPU and its companion HDMI audio controller powered down in
# D3cold (0 Watts) when idle on battery, while retaining 100% plug-and-play
# compatibility if the BIOS is switched to "Discrete Graphics".
# ==============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[-] Error: This script must be run as root."
    echo "    Usage: sudo $0"
    exit 1
fi

echo "=========================================================="
echo "  Setting up ThinkPad P53 Hybrid Graphics Power Saving"
echo "=========================================================="

# ------------------------------------------------------------------------------
# 1. TLP Drop-in Configuration
# ------------------------------------------------------------------------------
echo "[1/7] Configuring TLP runtime power management..."
mkdir -p /etc/tlp.d
cat << 'EOF' > /etc/tlp.d/01-nvidia-rtd3.conf
# Allow NVIDIA Turing+ GPU and Audio controllers to enter runtime D3cold
RUNTIME_PM_DRIVER_DENYLIST="amdgpu mei_me nouveau xhci_hcd"
RUNTIME_PM_ON_AC=auto
RUNTIME_PM_ON_BAT=auto
SOUND_POWER_SAVE_ON_AC=1
SOUND_POWER_SAVE_ON_BAT=1
SOUND_POWER_SAVE_CONTROLLER=Y
EOF

# Comment out conflicting sound power save lines in /etc/tlp.conf (it overrides drop-ins)
if [[ -f /etc/tlp.conf ]]; then
    sed -i -E 's/^(SOUND_POWER_SAVE_(ON_AC|ON_BAT|CONTROLLER)=.*)/#\1/' /etc/tlp.conf
fi

# ------------------------------------------------------------------------------
# 2. NVIDIA Driver Module Options (RTD3 + Disable Turing GSP bug)
# ------------------------------------------------------------------------------
echo "[2/7] Configuring NVIDIA kernel module options..."
mkdir -p /etc/modprobe.d
cat << 'EOF' > /etc/modprobe.d/nvidia-pm.conf
options nvidia NVreg_DynamicPowerManagement=0x02
options nvidia NVreg_EnableGpuFirmware=0
EOF

# ------------------------------------------------------------------------------
# 3. Audio Controller Runtime Power Management
# ------------------------------------------------------------------------------
echo "[3/7] Configuring Intel/NVIDIA HDA audio power management..."
cat << 'EOF' > /etc/modprobe.d/audio-pm.conf
options snd_hda_intel power_save=1 power_save_controller=Y
EOF

# Remove rogue udev rules forcing audio on if present
if [[ -f /etc/udev/rules.d/90-nvidia-audio-wakeup.rules ]]; then
    echo "      Disabling rogue 90-nvidia-audio-wakeup.rules..."
    mv /etc/udev/rules.d/90-nvidia-audio-wakeup.rules /etc/udev/rules.d/90-nvidia-audio-wakeup.rules.disabled
fi

# ------------------------------------------------------------------------------
# 4. Dynamic KWin & Mesa Environment Generator (BIOS-Safe)
# ------------------------------------------------------------------------------
echo "[4/7] Installing dynamic KWin & Mesa user-session generator..."
mkdir -p /etc/systemd/user-environment-generators
cat << 'EOF' > /etc/systemd/user-environment-generators/10-kwin-intel.sh
#!/bin/sh
# Dynamically resolves the Intel iGPU symlink to its real device node (e.g. /dev/dri/card1)
# Avoiding colons in path which break KWin DRM device parser.
INTEL_CARD=$(readlink -f /dev/dri/by-path/pci-0000:00:02.0-card 2>/dev/null)

if [ -n "$INTEL_CARD" ] && [ -e "$INTEL_CARD" ]; then
    echo "KWIN_DRM_DEVICES=$INTEL_CARD"
    echo "__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json"
fi
# If Intel is absent (BIOS Discrete Mode), outputs nothing so Plasma boots on NVIDIA.
EOF
chmod +x /etc/systemd/user-environment-generators/10-kwin-intel.sh

# ------------------------------------------------------------------------------
# 5. Disable KDE Plasma ksystemstats GPU Polling Loop & Install Pacman Hook
# ------------------------------------------------------------------------------
echo "[5/7] Silencing KDE Plasma ksystemstats GPU polling bug..."
if [[ -f /usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so ]]; then
    mv -f /usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so \
          /usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so.disabled
fi

mkdir -p /etc/pacman.d/hooks
cat << 'EOF' > /etc/pacman.d/hooks/disable-ksystemstats-gpu.hook
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so

[Action]
Description = Disabling ksystemstats GPU polling plugin to prevent NVIDIA wakeups...
When = PostTransaction
Exec = /usr/bin/mv -f /usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so /usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so.disabled
EOF

# ------------------------------------------------------------------------------
# 6. Rebuild initramfs
# ------------------------------------------------------------------------------
echo "[6/7] Updating initramfs via mkinitcpio..."
if command -v mkinitcpio &>/dev/null; then
    mkinitcpio -P
else
    echo "      Warning: mkinitcpio not found. Update initramfs manually if using Dracut or Booster."
fi

# ------------------------------------------------------------------------------
# 7. Apply Immediate Runtime Settings
# ------------------------------------------------------------------------------
echo "[7/7] Applying runtime settings..."
if command -v tlp &>/dev/null; then
    tlp start || true
fi

echo "=========================================================="
echo "  Setup Complete! Reboot your system to activate."
echo "  After rebooting, run ./check-status.sh to verify D3cold."
echo "=========================================================="
