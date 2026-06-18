#!/usr/bin/env bash
set -e

REPO="cjccjj/pls"
INSTALL_DIR="/usr/local/bin"
BIN="pls"

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: $1 is required but not installed."
        exit 1
    }
}

need curl
need uname
need mktemp

# Detect OS and arch
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    arm64)   ARCH="arm64" ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

case "$OS" in
    linux|darwin) ;;
    *)
        echo "Unsupported OS: $OS"
        echo "Request other platforms at https://github.com/$REPO/issues"
        exit 1
        ;;
esac

ASSET="pls-${OS}-${ARCH}"
URL="https://github.com/$REPO/releases/latest/download/$ASSET"

TMP_DOWNLOAD="$(mktemp)"
trap 'rm -f "$TMP_DOWNLOAD"' EXIT

echo "Downloading $ASSET..."
curl -fSL --progress-bar -o "$TMP_DOWNLOAD" "$URL" || {
    echo "Download failed. Check https://github.com/$REPO/releases"
    exit 1
}

TARGET="$INSTALL_DIR/$BIN"
TMP_TARGET="$INSTALL_DIR/.$BIN.tmp.$$"

# Ensure install dir exists
if [ ! -d "$INSTALL_DIR" ]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "Creating $INSTALL_DIR requires sudo:"
        sudo mkdir -p "$INSTALL_DIR"
    else
        echo "Error: $INSTALL_DIR does not exist and sudo is not installed."
        exit 1
    fi
fi

# Install by writing a new file, then atomically replacing the old one.
#
# This is important for self-updates:
# - Do NOT cp directly over /usr/local/bin/pls.
# - A running Linux executable may reject truncation with "Text file busy".
# - Rename/mv replacement is safe: old running processes keep the old inode,
#   new invocations get the new binary.
if [ -w "$INSTALL_DIR" ]; then
    install -m 755 "$TMP_DOWNLOAD" "$TMP_TARGET"
    mv -f "$TMP_TARGET" "$TARGET"
else
    command -v sudo >/dev/null 2>&1 || {
        echo "Error: $INSTALL_DIR is not writable and sudo is not installed."
        exit 1
    }

    echo "Installing to $INSTALL_DIR requires sudo:"
    sudo install -m 755 "$TMP_DOWNLOAD" "$TMP_TARGET"
    sudo mv -f "$TMP_TARGET" "$TARGET"
fi

echo ""
echo "$BIN installed to $TARGET"
echo "Run 'pls' to start, or 'pls -h' for help."