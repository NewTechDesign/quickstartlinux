#!/usr/bin/env bash

sudo pacman -S --noconfirm virtualbox virtualbox-host-modules-arch
groupadd vboxusers
modprobe vboxdrv

pacman -S --noconfirm gnome-extra
