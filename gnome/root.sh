#!/usr/bin/env bash

localectl set-locale ru_RU.UTF-8

# setxkbmap -layout us,ru -option grp:alt_shift_toggle # (old x11)

sed -i 's/^timeout .*/timeout 1/' /boot/loader/loader.conf # only systemdboot

pacman -Suy
pacman -S --noconfirm pacman-contrib 
pacman -S --noconfirm adw-gtk-theme gnome-tweaks gnome-sound-recorder
pacman -S --noconfirm ttf-dejavu ttf-liberation ttf-arphic-ukai ttf-arphic-uming ttf-sazanami noto-fonts noto-fonts-emoji noto-fonts-cjk

systemctl enable --now bluetooth
