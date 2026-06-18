#!/usr/bin/env bash
set -e

REPO="cjccjj/pls"
INSTALL_DIR="/usr/local/bin"
BIN="pls"

# Detect OS and arch
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    arm64)   ARCH="arm64" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

if [ "$OS" != "linux" ] && [ "$OS" != "darwin" ]; then
    echo "Unsupported OS: $OS"
    echo "Request other platforms at https://github.com/$REPO/issues"
    exit 1
fi

ASSET="pls-${OS}-${ARCH}"
URL="https://github.com/$REPO/releases/latest/download/$ASSET"

echo "Downloading $ASSET..."
curl -fSL --progress-bar -o "/tmp/$ASSET" "$URL" || {
    echo "Download failed. Check https://github.com/$REPO/releases"
    exit 1
}

chmod 755 "/tmp/$ASSET"

if [ -w "$INSTALL_DIR" ]; then
    cp "/tmp/$ASSET" "$INSTALL_DIR/$BIN"
else
    echo "Installing to $INSTALL_DIR (requires sudo):"
    sudo cp "/tmp/$ASSET" "$INSTALL_DIR/$BIN"
fi

rm -f "/tmp/$ASSET"

echo ""
echo "$BIN installed to $INSTALL_DIR/$BIN"
echo "Run 'pls' to start, or 'pls -h' for help."
