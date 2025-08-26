#!/usr/bin/env bash
set -e

echo "This will install/update 'pls' to /usr/local/bin (requires sudo)."
read -p "Continue? [y/N] " a
[[ "$a" != [yY] ]] && echo "Aborted." && exit 1

# Backup existing config if present
mv ~/.config/pls/pls.conf ~/.config/pls/pls_old.conf 2>/dev/null || true

# Download to temp and install
tmp=$(mktemp)
echo "Downloading pls..."
curl -fSL -# https://raw.githubusercontent.com/cjccjj/pls/main/pls.sh -o "$tmp" || { echo "Download failed"; exit 1; }

chmod 755 "$tmp"
sudo cp "$tmp" /usr/local/bin/pls
rm -f "$tmp"

echo "Install/update done."
echo "Run 'pls' to start, or 'pls -h' for help."
