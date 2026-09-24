#!/usr/bin/env bash

cargo build --release
sudo ./target/release/arch-setup
