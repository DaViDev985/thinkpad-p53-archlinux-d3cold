# ThinkPad P53 Hybrid Graphics Power Management Guide
**Target Hardware:** Lenovo ThinkPad P53 (Intel UHD 630 + NVIDIA Quadro T1000 Mobile, Turing TU117GLM)  
**Target Environment:** Arch Linux, KDE Plasma 6 (Wayland), TLP, PipeWire

---

## Overview

On hybrid graphics laptops, the dedicated NVIDIA GPU (dGPU) should power down to **`D3cold` (0 Watts)** when idle on battery, leaving the energy-efficient Intel iGPU to drive the desktop.

At the same time, external displays (HDMI and Mini-DisplayPort/Type-C) on the ThinkPad P53 are **physically wired directly to the NVIDIA Quadro dGPU**, while the internal laptop panel is wired to the **Intel iGPU**.

Out of the box on Linux, several independent bugs prevent this setup from working properly:
1. **External Display Routing & KWin Wayland:** By default, if KWin only binds to the Intel GPU (`card1`), external ports wired to NVIDIA remain unprobed, resulting in a black screen and no detected monitors in KDE Display Settings. Passing both cards (`card1:card0`) configures Intel as primary (saving power) and NVIDIA as secondary (driving external monitors).
2. **Xwayland Secondary Device Locking:** When an external monitor is plugged in, Xwayland opens `/dev/dri/card0`. When unplugged, Xwayland leaks the file descriptor and never closes the device, preventing the GPU from returning to `D3cold`. Setting `XWAYLAND_NO_GLAMOR=1` stops Xwayland from ever touching DRM hardware devices while leaving native Wayland desktop compositing and external display driving to KWin.
3. **KWin Colon Parsing Crash:** Setting `KWIN_DRM_DEVICES` to standard by-path symlinks (like `/dev/dri/by-path/pci-0000:00:02.0-card`) crashes KWin to a blinking cursor because KWin splits on colons `:`. Resolving with `readlink -f` avoids this.
4. **NVIDIA Driver 580 GSP Firmware Bug:** Driver 580+ defaults to GSP firmware on Turing cards, which breaks Runtime D3 (RTD3).
5. **HDMI Audio PCIe Power Dependency:** The NVIDIA companion HDMI audio controller (`0000:01:00.1`) shares the GPU's PCIe power domain. If ALSA powersave is off, audio stays in `D0`, physically locking the GPU in `D0`.
6. **TLP Config Precedence:** `/etc/tlp.conf` takes priority over drop-ins in `/etc/tlp.d/`. Setting audio powersave in a drop-in file is silently overridden by `/etc/tlp.conf` if not commented out.
7. **KDE `ksystemstats` GPU Polling Loop:** Plasma 6's GPU monitoring plugin launches `nvidia-smi dmon -d 2` in the background, waking the card every 2 seconds.

This repository provides an automated script and manual documentation to fix all these issues while **preserving 100% plug-and-play compatibility if you temporarily switch the BIOS to "Discrete Graphics"**.

⚠️**Known issue:** If the laptop is connected to an external monitor and then you disconnect it, the GPU won't be able to enter D3cold until you reboot the laptop. I (and antigravity) have yet to find a solution that doesn't break other stuff, but the issue is caused by an Xwayland process keeping the GPU awake.  

---

## Quick Start (Automated)

To set up everything on a fresh Arch installation:

```bash
cd ~/thinkpad-p53-gpu-powersave
sudo ./setup.sh
```

Then **reboot your laptop**.

After rebooting, check that the card is sleeping in `D3cold` (when unplugged from external monitors):

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

### 4. Dynamic KWin Multi-GPU Environment Generator (BIOS-Safe)
Create `/etc/systemd/user-environment-generators/10-kwin-intel.sh`:
```sh
#!/bin/sh
# Dynamically resolves the Intel iGPU and NVIDIA dGPU symlinks to real device nodes.
# Avoiding colons in path which break KWin's DRM device parser.
INTEL_CARD=$(readlink -f /dev/dri/by-path/pci-0000:00:02.0-card 2>/dev/null)
NVIDIA_CARD=$(readlink -f /dev/dri/by-path/pci-0000:01:00.0-card 2>/dev/null)

if [ -n "$INTEL_CARD" ] && [ -e "$INTEL_CARD" ]; then
    if [ -n "$NVIDIA_CARD" ] && [ -e "$NVIDIA_CARD" ]; then
        # Intel as Primary (desktop/laptop screen), NVIDIA as Secondary (external HDMI/DP ports)
        echo "KWIN_DRM_DEVICES=$INTEL_CARD:$NVIDIA_CARD"
    else
        echo "KWIN_DRM_DEVICES=$INTEL_CARD"
    fi
    # Restrict desktop EGL to Mesa so background apps don't lock NVIDIA
    echo "__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json"
    # Prevent Xwayland from locking secondary DRM nodes across hotplugs
    echo "XWAYLAND_NO_GLAMOR=1"
fi
# If Intel is absent (BIOS Discrete Mode), outputs nothing so Plasma boots natively on NVIDIA.
```
Make it executable:
```bash
sudo chmod +x /etc/systemd/user-environment-generators/10-kwin-intel.sh
```

**Why this works:**
- Uses `readlink -f` to resolve device paths, preventing KWin's colon-split crash.
- Declares Intel as the **Primary GPU** (compositing desktop and internal screen at low power).
- Declares NVIDIA as the **Secondary GPU** (allowing KWin to discover and drive external monitors connected to HDMI / Mini-DP).
- Exports `__EGL_VENDOR_LIBRARY_FILENAMES` and `XWAYLAND_NO_GLAMOR=1` so background desktop helpers and Xwayland never touch or hold handles on the secondary DRM device (`card0`).
- When the external monitor is unplugged on battery, NVIDIA cleanly enters `D3cold`.
- If you reboot into the BIOS and switch to **Discrete Graphics**, the Intel card is absent on the PCIe bus, so the script outputs nothing and Plasma cleanly boots natively on NVIDIA.

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

Instead, run the included safe checker:

```bash
./check-status.sh
```

When an external monitor is plugged into HDMI, the NVIDIA card is expected to be `active (D0)` to drive the display.  
When the external monitor is unplugged and idle on battery, it will report:
```text
GPU PCI (0000:01:00.0):     Status: suspended  State: D3cold
Audio PCI (0000:01:00.1):   Status: suspended  State: D3cold
```

---

**Disclaimer:** This solution was made with the use of AI (antigravity-cli:Gemini-3.8-Flash). If you find some ugly stuff in the code, or have some suggestions/improvements, feel free to submit a pull request or open an issue.
