#!/bin/bash
set -e  # Exit immediately if any command fails

echo "[1/2] Installing requirements..."
sudo pacman -S --needed keyd fish starship

echo "[2/2] Updating keyboard layout..."
# Ensure the destination directory exists
sudo mkdir -p /etc/keyd

# Copy with the correct filename (default.conf)
sudo cp etc/keyd/default.conf /etc/keyd/default.conf

# Add user to keyd group (optional, but allows running 'keyd monitor' without sudo)
sudo usermod -aG keyd "$USER"

# Enable and reload keyd
sudo systemctl enable --now keyd
sudo keyd reload

echo "Done! If this is your first time adding yourself to the 'keyd' group, log out or reboot to apply group permissions."
