#!/usr/bin/env bash

pacman -S --noconfirm gnome gdm

# pacman -S --noconfirm gnome-extra

systemctl enable --now gdm
