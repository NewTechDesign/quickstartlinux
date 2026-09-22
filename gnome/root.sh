#!/usr/bin/env bash

localectl set-locale ru_RU.UTF-8

# setxkbmap -layout us,ru -option grp:alt_shift_toggle (old x11)

sed -i 's/^timeout .*/timeout 1/' /boot/loader/loader.conf

pacman -Suy
pacman -S --noconfirm pacman-contrib 
pacman -S --noconfirm gnome-tweaks adw-gtk-theme
pacman -S --noconfirm noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation ttf-arphic-ukai ttf-arphic-uming ttf-sazanami
