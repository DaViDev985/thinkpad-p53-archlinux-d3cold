#!/usr/bin/env bash
# ThinkPad P53 GPU & Audio Power Status Checker
# Reads sysfs directly so it does NOT wake the GPU from D3cold sleep.

set -euo pipefail

GPU_PCI="0000:01:00.0"
AUDIO_PCI="0000:01:00.1"

echo "=========================================================="
echo "   ThinkPad P53: NVIDIA Quadro T1000 Power State"
echo "=========================================================="

# Check GPU
if [[ -d "/sys/bus/pci/devices/${GPU_PCI}" ]]; then
    gpu_status=$(cat "/sys/bus/pci/devices/${GPU_PCI}/power/runtime_status" 2>/dev/null || echo "unknown")
    gpu_state=$(cat "/sys/bus/pci/devices/${GPU_PCI}/power_state" 2>/dev/null || echo "unknown")
    gpu_suspended_ms=$(cat "/sys/bus/pci/devices/${GPU_PCI}/power/runtime_suspended_time" 2>/dev/null || echo "0")
    gpu_suspended_sec=$(( gpu_suspended_ms / 1000 ))

    printf "GPU PCI (%s):     Status: %-10s State: %-8s\n" "${GPU_PCI}" "${gpu_status}" "${gpu_state}"
    if [[ "${gpu_status}" == "suspended" ]]; then
        echo "GPU Sleep Duration:     ${gpu_suspended_sec}s continuously in D3cold (0 Watts)"
    fi
else
    echo "GPU PCI (${GPU_PCI}): Not found on bus (Discrete mode disabled or PCIe off?)"
fi

echo "----------------------------------------------------------"

# Check Audio
if [[ -d "/sys/bus/pci/devices/${AUDIO_PCI}" ]]; then
    audio_status=$(cat "/sys/bus/pci/devices/${AUDIO_PCI}/power/runtime_status" 2>/dev/null || echo "unknown")
    audio_state=$(cat "/sys/bus/pci/devices/${AUDIO_PCI}/power_state" 2>/dev/null || echo "unknown")
    printf "Audio PCI (%s):   Status: %-10s State: %-8s\n" "${AUDIO_PCI}" "${audio_status}" "${audio_state}"
else
    echo "Audio PCI (${AUDIO_PCI}): Not found on bus"
fi

if [[ -f "/sys/module/snd_hda_intel/parameters/power_save" ]]; then
    pwr_save=$(cat /sys/module/snd_hda_intel/parameters/power_save)
    pwr_ctrl=$(cat /sys/module/snd_hda_intel/parameters/power_save_controller)
    echo "ALSA power_save:        ${pwr_save} (controller: ${pwr_ctrl})"
fi

echo "----------------------------------------------------------"

# Check Active NVIDIA Handles only if GPU is active (avoids waking the card if asleep)
if [[ "${gpu_status:-}" == "suspended" ]]; then
    echo "NVIDIA Handles:         None (GPU is asleep in D3cold)"
else
    active_procs=$(fuser -v /dev/nvidia* /dev/dri/card0 /dev/dri/renderD129 2>/dev/null || true)
    if [[ -z "${active_procs}" ]]; then
        echo "NVIDIA Handles:         None (Idle, waiting for autosuspend timer)"
    else
        echo "NVIDIA Handles Detected (Active processes holding GPU):"
        echo "${active_procs}"
    fi
fi

echo "=========================================================="
