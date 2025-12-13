#!/bin/bash

# P-BOX Linux One-Click Installation Script
# https://github.com/star8618/P-BOX

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
INSTALL_DIR="/etc/p-box"
SERVICE_NAME="p-box"
DEFAULT_PORT=8666
GITHUB_REPO="star8618/P-BOX"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

echo -e "${CYAN}"
echo "╔════════════════════════════════════════╗"
echo "║     🚀 P-BOX Linux Installer           ║"
echo "╚════════════════════════════════════════╝"
echo -e "${NC}"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Please run as root (sudo)${NC}"
    exit 1
fi

# Detect architecture
detect_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            echo ""
            ;;
    esac
}

ARCH=$(detect_arch)
if [ -z "$ARCH" ]; then
    echo -e "${RED}❌ Unsupported architecture: $(uname -m)${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Detected architecture: ${CYAN}${ARCH}${NC}"

# Get latest version
echo -e "${BLUE}📥 Fetching latest version...${NC}"

VERSION=""
if command -v curl &> /dev/null; then
    VERSION=$(curl -s "$GITHUB_API" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' | head -n 1)
elif command -v wget &> /dev/null; then
    VERSION=$(wget -qO- "$GITHUB_API" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' | head -n 1)
fi

# Remove 'v' prefix if present
VERSION=${VERSION#v}

if [ -z "$VERSION" ]; then
    echo -e "${RED}❌ Failed to get latest version${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Latest version: ${CYAN}v${VERSION}${NC}"

# Download URL (GitHub uses 'v' prefix in release tags)
FILENAME="p-box-${VERSION}-linux-${ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/${FILENAME}"

# Try CDN first
CDN_URL="https://ghfast.top/${DOWNLOAD_URL}"

echo -e "${BLUE}📥 Downloading P-BOX...${NC}"

TEMP_DIR=$(mktemp -d)
TEMP_FILE="${TEMP_DIR}/${FILENAME}"

# Download
download_success=false

# Try CDN
if curl -sL --connect-timeout 15 -o "$TEMP_FILE" "$CDN_URL" 2>/dev/null; then
    # Verify it's a valid gzip file
    if [ -s "$TEMP_FILE" ] && file "$TEMP_FILE" | grep -q "gzip"; then
        echo -e "${GREEN}✓ Downloaded from CDN${NC}"
        download_success=true
    else
        rm -f "$TEMP_FILE"
    fi
fi

# Fallback to GitHub
if [ "$download_success" = false ]; then
    echo -e "${YELLOW}→ CDN failed, trying GitHub...${NC}"
    if curl -sL --connect-timeout 30 -o "$TEMP_FILE" "$DOWNLOAD_URL" 2>/dev/null; then
        if [ -s "$TEMP_FILE" ] && file "$TEMP_FILE" | grep -q "gzip"; then
            echo -e "${GREEN}✓ Downloaded from GitHub${NC}"
            download_success=true
        fi
    fi
fi

if [ "$download_success" = false ]; then
    echo -e "${RED}❌ Download failed${NC}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Stop existing service
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo -e "${YELLOW}→ Stopping existing service...${NC}"
    systemctl stop "$SERVICE_NAME"
fi

# Create install directory
echo -e "${BLUE}📁 Installing to ${INSTALL_DIR}...${NC}"
mkdir -p "$INSTALL_DIR"

# Extract
tar -xzf "$TEMP_FILE" -C "$TEMP_DIR"

# Find extracted directory
EXTRACTED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "p-box-*" | head -n 1)
if [ -z "$EXTRACTED_DIR" ]; then
    EXTRACTED_DIR="$TEMP_DIR"
fi

# Copy files
if [ -d "$EXTRACTED_DIR" ] && [ "$(ls -A $EXTRACTED_DIR)" ]; then
    cp -r "$EXTRACTED_DIR"/* "$INSTALL_DIR/"
else
    echo -e "${RED}❌ Extraction failed${NC}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Set permissions
chmod +x "$INSTALL_DIR/p-box"
chmod +x "$INSTALL_DIR/install-nginx.sh" 2>/dev/null || true

# Update config port to 8666
if [ -f "$INSTALL_DIR/config.yaml" ]; then
    sed -i "s/port: 8383/port: ${DEFAULT_PORT}/" "$INSTALL_DIR/config.yaml"
    echo -e "${GREEN}✓ Updated default port to ${DEFAULT_PORT}${NC}"
fi

# Cleanup
rm -rf "$TEMP_DIR"
echo -e "${GREEN}✓ Installation complete${NC}"

# Create systemd service
echo -e "${BLUE}⚙️ Creating systemd service...${NC}"

cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=P-BOX Proxy Management Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/p-box
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd
systemctl daemon-reload

# Enable service
systemctl enable "$SERVICE_NAME"
echo -e "${GREEN}✓ Service enabled for auto-start${NC}"

# Run nginx installation script
if [ -f "$INSTALL_DIR/install-nginx.sh" ]; then
    echo -e "${BLUE}🔧 Running Nginx installation script...${NC}"
    chmod +x "$INSTALL_DIR/install-nginx.sh"
    cd "$INSTALL_DIR" && bash ./install-nginx.sh || echo -e "${YELLOW}⚠️ Nginx script completed with warnings${NC}"
fi

# Start service
echo -e "${BLUE}🚀 Starting P-BOX service...${NC}"
systemctl start "$SERVICE_NAME"

# Check status
sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo -e "${GREEN}✓ P-BOX is running${NC}"
else
    echo -e "${YELLOW}⚠️ Service may need manual start: systemctl start ${SERVICE_NAME}${NC}"
fi

# Get IP
IP_ADDR=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║      ✅ P-BOX Installation Complete!   ║${NC}"
echo -e "${CYAN}╠════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}                                        ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  📂 Install Path: ${GREEN}${INSTALL_DIR}${NC}         ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  🌐 Web Panel: ${GREEN}http://${IP_ADDR}:${DEFAULT_PORT}${NC}  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                        ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  📋 Commands:                          ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}     systemctl start ${SERVICE_NAME}            ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}     systemctl stop ${SERVICE_NAME}             ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}     systemctl restart ${SERVICE_NAME}          ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}     systemctl status ${SERVICE_NAME}           ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                        ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""
