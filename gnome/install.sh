#!/usr/bin/env bash

pacman -S --noconfirm gnome gnome-extra
systemctl enable gdm
