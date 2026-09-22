#!/usr/bin/env bash

pacman -S --noconfirm gdm gnome

systemctl enable --now gdm
