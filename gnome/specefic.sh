#!/usr/bin/env bash

# Firmware

sudo pacman -S pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils sof-firmware alsa-ucm-conf v4l-utils bluez bluez-utils pciutils

# Intel

sudo pacman -S mesa mesa-utils libva-intel-driver intel-media-driver vulkan-intel lib32-vulkan-intel lib32-mesa

# Nvidia

sudo pacman -S nvidia nvidia-utils nvidia-settings lib32-nvidia-utils vulkan-icd-loader lib32-vulkan-icd-loader libvdpau lib32-libvdpau opencl-nvidia lib32-opencl-nvidia

# Amd

sudo pacman -S mesa mesa-utils vulkan-radeon lib32-vulkan-radeon libva-mesa-driver lib32-mesa
