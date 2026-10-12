# ThinkPad P53 Hybrid Graphics Power Management Guide
**Target Hardware:** Lenovo ThinkPad P53 (Intel UHD 630 + NVIDIA Quadro T1000 Mobile, Turing TU117GLM)  
**Target Environment:** Arch Linux, KDE Plasma 6 (Wayland), TLP, PipeWire

---

## Overview

On hybrid graphics laptops, the dedicated NVIDIA GPU (dGPU) should power down to **`D3cold` (0 Watts)** when idle on battery, leaving the energy-efficient Intel iGPU to drive the desktop.

Out of the box on Linux, several independent bugs prevent the dGPU from sleeping:
1. **KDE Plasma & KWin bind to NVIDIA:** KWin and Electron/Wayland apps scan GLVND and initialize contexts on NVIDIA, preventing autosuspend.
2. **KWin Colon Parsing Crash:** Setting `KWIN_DRM_DEVICES` to standard by-path symlinks (like `/dev/dri/by-path/pci-0000:00:02.0-card`) crashes KWin to a blinking cursor because KWin splits on colons `:`.
3. **NVIDIA Driver 580 GSP Firmware Bug:** Driver 580+ defaults to GSP firmware on Turing cards, which breaks Runtime D3 (RTD3).
4. **HDMI Audio PCIe Power Dependency:** The NVIDIA companion HDMI audio controller (`0000:01:00.1`) shares the GPU's PCIe power domain. If ALSA powersave is off, audio stays in `D0`, physically locking the GPU in `D0`.
5. **TLP Config Precedence:** `/etc/tlp.conf` takes priority over drop-ins in `/etc/tlp.d/`. Setting audio powersave in a drop-in file is silently overridden by `/etc/tlp.conf`.
6. **KDE `ksystemstats` GPU Polling Loop:** Plasma 6's GPU monitoring plugin launches `nvidia-smi dmon -d 2` in the background, waking the card every 2 seconds.

This repository provides an automated script and manual documentation to fix all these issues while **preserving 100% plug-and-play compatibility if you temporarily switch the BIOS to "Discrete Graphics"**.

---

## Quick Start (Automated)

To set up everything on a fresh Arch installation:

```bash
cd ~/thinkpad-p53-gpu-powersave
sudo ./setup.sh
```

Then **reboot your laptop**.

After rebooting, check that the card is sleeping in `D3cold`:

```bash
./check-status.sh
```

---

## Detailed Manual Steps & Explanations

If you prefer applying each fix manually, follow these steps:

### 1. TLP Power Management Configuration
TLP by default denylists the `nvidia` driver from runtime power management.

Create `/etc/tlp.d/01-nvidia-rtd3.conf`:
```ini
# Allow NVIDIA Turing+ GPU and Audio controllers to enter runtime D3cold
RUNTIME_PM_DRIVER_DENYLIST="amdgpu mei_me nouveau xhci_hcd"
RUNTIME_PM_ON_AC=auto
RUNTIME_PM_ON_BAT=auto
SOUND_POWER_SAVE_ON_AC=1
SOUND_POWER_SAVE_ON_BAT=1
SOUND_POWER_SAVE_CONTROLLER=Y
```

**Crucial:** Check `/etc/tlp.conf`. If `SOUND_POWER_SAVE_ON_AC`, `SOUND_POWER_SAVE_ON_BAT`, or `SOUND_POWER_SAVE_CONTROLLER` are uncommented, comment them out with `#` so `/etc/tlp.conf` does not override the drop-in:
```bash
sudo sed -i -E 's/^(SOUND_POWER_SAVE_(ON_AC|ON_BAT|CONTROLLER)=.*)/#\1/' /etc/tlp.conf
```

---

### 2. NVIDIA Driver RTD3 & Turing GSP Firmware Fix
Create `/etc/modprobe.d/nvidia-pm.conf`:
```ini
options nvidia NVreg_DynamicPowerManagement=0x02
options nvidia NVreg_EnableGpuFirmware=0
```
- `NVreg_DynamicPowerManagement=0x02`: Enables fine-grained Runtime D3 power management.
- `NVreg_EnableGpuFirmware=0`: Restores the mature non-GSP firmware path. (The GSP firmware in driver 580+ breaks RTD3 on Turing TU117 GPUs).

---

### 3. Audio Controller Power Management
Create `/etc/modprobe.d/audio-pm.conf`:
```ini
options snd_hda_intel power_save=1 power_save_controller=Y
```
Remove any rogue udev rules that force the audio controller awake:
```bash
sudo rm -f /etc/udev/rules.d/90-nvidia-audio-wakeup.rules
```
Update your initramfs:
```bash
sudo mkinitcpio -P
```

---

### 4. Dynamic KWin & Mesa Environment Generator (BIOS-Safe)
Create `/etc/systemd/user-environment-generators/10-kwin-intel.sh`:
```sh
#!/bin/sh
# Dynamically resolves the Intel iGPU symlink to its real device node (e.g. /dev/dri/card1)
# Avoiding colons in path which break KWin's DRM device parser.
INTEL_CARD=$(readlink -f /dev/dri/by-path/pci-0000:00:02.0-card 2>/dev/null)

if [ -n "$INTEL_CARD" ] && [ -e "$INTEL_CARD" ]; then
    echo "KWIN_DRM_DEVICES=$INTEL_CARD"
    echo "__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json"
fi
# If Intel is absent (BIOS Discrete Mode), outputs nothing so Plasma boots on NVIDIA.
```
Make it executable:
```bash
sudo chmod +x /etc/systemd/user-environment-generators/10-kwin-intel.sh
```

**Why this works:**
- Uses `readlink -f` to resolve to `/dev/dri/cardX`, preventing KWin's colon-split crash.
- Directs KWin and Electron/Mesa apps away from the NVIDIA GLVND loader.
- If you reboot into the BIOS and switch to **Discrete Graphics**, the Intel card is absent, so the script outputs nothing and Plasma cleanly boots natively on NVIDIA.

---

### 5. Silence KDE `ksystemstats` GPU Polling Bug
KDE Plasma 6's GPU monitoring plugin launches `nvidia-smi dmon -d 2` in the background, continuously waking the card every 2 seconds.

Disable the plugin:
```bash
sudo mv /usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so \
        /usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so.disabled
```

To prevent Arch package updates (`pacman -Syu`) from restoring the broken plugin, create a pacman hook at `/etc/pacman.d/hooks/disable-ksystemstats-gpu.hook`:
```ini
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so

[Action]
Description = Disabling ksystemstats GPU polling plugin to prevent NVIDIA wakeups...
When = PostTransaction
Exec = /usr/bin/mv -f /usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so /usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so.disabled
```

---

## Verifying Power State

> **Warning:** Do NOT run `nvidia-smi` repeatedly to check if the GPU is sleeping! Running `nvidia-smi` communicates with the GPU and immediately wakes it up from D3cold, resetting the idle timer.

Instead, inspect the Linux sysfs interface directly:

```bash
# Check GPU PCI Runtime Status
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
# Expected: suspended

# Check GPU Power State
cat /sys/bus/pci/devices/0000:01:00.0/power_state
# Expected: D3cold

# Check Audio Controller Status
cat /sys/bus/pci/devices/0000:01:00.1/power/runtime_status
# Expected: suspended
```

Or simply run the included script:
```bash
./check-status.sh
```
