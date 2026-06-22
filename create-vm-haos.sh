#!/usr/bin/env bash
# =============================================================================
# HAOS (Home Assistant OS) Proxmox Installer
# Tested on Proxmox VE 8.x
# =============================================================================

set -euo pipefail

# --- Colors & Formatting ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
ask()     { echo -e "${BOLD}$*${RESET}"; }

confirm() {
    local prompt="${1:-Continue?}"
    read -rp "$(echo -e "${YELLOW}${prompt} [y/N]: ${RESET}")" ans
    [[ "${ans,,}" == "y" ]] || { echo "Aborted."; exit 0; }
}

# --- Banner ---
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║     Home Assistant OS - Proxmox Installer            ║"
echo "║     Installs HAOS via qcow2 image into a new VM      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# --- Root check ---
[[ $EUID -ne 0 ]] && error "This script must be run as root on the Proxmox host."

# --- Dependency check ---
info "Checking dependencies (wget, xz-utils, qm, pvesh)..."
for cmd in wget qm pvesh curl; do
    command -v "$cmd" &>/dev/null || { warn "$cmd not found. Installing..."; apt-get install -y "${cmd}" &>/dev/null; }
done
dpkg -l xz-utils &>/dev/null || { warn "xz-utils not found. Installing..."; apt-get update -qq && apt-get install -y xz-utils &>/dev/null; }
success "All dependencies satisfied."
echo

# =============================================================================
# STEP 1: Collect User Input
# =============================================================================
echo -e "${BOLD}─── Step 1: Configuration ────────────────────────────────${RESET}"
echo

# VM ID
while true; do
    ask "Enter the VM ID for the HAOS VM (e.g. 100, 200):"
    read -rp "> " VMID
    if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
        warn "VM ID must be a positive integer. Try again."
        continue
    fi
    if qm status "$VMID" &>/dev/null 2>&1; then
        warn "VM ID ${VMID} already exists. Please choose a different ID."
        continue
    fi
    break
done
success "VM ID set to: ${VMID}"
echo

# VM Name
ask "Enter a name for the VM (default: HomeAssistant):"
read -rp "> " VMNAME
VMNAME="${VMNAME:-HomeAssistant}"
success "VM name set to: ${VMNAME}"
echo

# Storage
info "Available storage pools:"
pvesm status | awk 'NR>1 {printf "  %-20s type=%-10s avail=%s\n", $1, $2, $5}'
echo
ask "Enter the storage name to use (e.g. local-lvm, local-zfs, SSD_100GB):"
read -rp "> " STORAGE
# Validate storage exists
pvesm status | awk 'NR>1 {print $1}' | grep -qx "$STORAGE" || error "Storage '${STORAGE}' not found. Check the list above."
success "Storage set to: ${STORAGE}"
echo

# RAM
ask "Enter RAM in MB (default: 4096, minimum recommended: 2048):"
read -rp "> " RAM
RAM="${RAM:-4096}"
[[ "$RAM" -ge 2048 ]] || warn "Less than 2048 MB RAM may cause instability."
success "RAM set to: ${RAM} MB"
echo

# CPU cores
ask "Enter number of CPU cores (default: 2):"
read -rp "> " CORES
CORES="${CORES:-2}"
[[ "$CORES" -ge 1 ]] || CORES=2
success "Cores set to: ${CORES}"
echo

# Network bridge
ask "Enter the network bridge (default: vmbr0):"
read -rp "> " BRIDGE
BRIDGE="${BRIDGE:-vmbr0}"
success "Bridge set to: ${BRIDGE}"
echo

# HAOS IP (informational - for final access URL only)
ask "Enter the IP address HAOS will use (for your reference at the end):"
read -rp "> " HAOS_IP
HAOS_IP="${HAOS_IP:-<HAOS-IP>}"
success "HAOS IP noted as: ${HAOS_IP}"
echo

# =============================================================================
# STEP 2: Summary Confirmation
# =============================================================================
echo -e "${BOLD}─── Step 2: Summary ──────────────────────────────────────${RESET}"
echo
echo -e "  VM ID      : ${CYAN}${VMID}${RESET}"
echo -e "  VM Name    : ${CYAN}${VMNAME}${RESET}"
echo -e "  Storage    : ${CYAN}${STORAGE}${RESET}"
echo -e "  RAM        : ${CYAN}${RAM} MB${RESET}"
echo -e "  CPU Cores  : ${CYAN}${CORES}${RESET}"
echo -e "  Network    : ${CYAN}${BRIDGE}${RESET}"
echo -e "  HAOS IP    : ${CYAN}${HAOS_IP}${RESET}"
echo
confirm "Proceed with the above settings?"
echo

# =============================================================================
# STEP 3: Download Latest HAOS qcow2 Image
# =============================================================================
echo -e "${BOLD}─── Step 3: Downloading HAOS Image ──────────────────────${RESET}"
info "Querying GitHub API for the latest HAOS release..."

RELEASE_JSON=$(curl -sf https://api.github.com/repos/home-assistant/operating-system/releases/latest) \
    || error "Failed to reach GitHub API. Check your network connection."

DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -oP '"browser_download_url":\s*"\Khttps://github[^"]*haos_ova-[^"]*\.qcow2\.xz(?=")' | head -1)
[[ -n "$DOWNLOAD_URL" ]] || error "Could not find a qcow2.xz download URL in the latest release."

HAOS_VERSION=$(echo "$RELEASE_JSON" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
info "Latest HAOS version: ${HAOS_VERSION}"
info "Download URL: ${DOWNLOAD_URL}"
echo
confirm "Download HAOS ${HAOS_VERSION}?"

TMPFILE="/tmp/HAOS.qcow2.xz"
QCOW2FILE="/tmp/HAOS.qcow2"

info "Downloading to ${TMPFILE}..."
wget --progress=bar:force -O "$TMPFILE" "$DOWNLOAD_URL" 2>&1 || error "Download failed."
success "Download complete."
echo

# =============================================================================
# STEP 4: Extract Image
# =============================================================================
echo -e "${BOLD}─── Step 4: Extracting Image ─────────────────────────────${RESET}"
confirm "Extract the downloaded image?"
info "Extracting ${TMPFILE} ..."
unxz -v "$TMPFILE" || error "Extraction failed."
[[ -f "$QCOW2FILE" ]] || error "Expected ${QCOW2FILE} after extraction, but file not found."
success "Extraction complete: ${QCOW2FILE}"
echo

# =============================================================================
# STEP 5: Create the VM
# =============================================================================
echo -e "${BOLD}─── Step 5: Creating VM ──────────────────────────────────${RESET}"
confirm "Create VM ${VMID} (${VMNAME}) in Proxmox?"

info "Creating VM skeleton..."
qm create "$VMID" \
    --name "$VMNAME" \
    --memory "$RAM" \
    --cores "$CORES" \
    --cpu host \
    --net0 virtio,bridge="${BRIDGE}" \
    --ostype l26 \
    --bios ovmf \
    --machine q35 \
    --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0" \
    --scsihw virtio-scsi-pci \
    --onboot 1
success "VM ${VMID} created."
echo

# =============================================================================
# STEP 6: Import Disk
# =============================================================================
echo -e "${BOLD}─── Step 6: Importing Disk ───────────────────────────────${RESET}"
confirm "Import the HAOS qcow2 disk into storage '${STORAGE}'?"
info "This may take a minute depending on your storage speed..."
qm importdisk "$VMID" "$QCOW2FILE" "$STORAGE" || error "Disk import failed."
success "Disk imported successfully."
echo

# =============================================================================
# STEP 7: Attach Disk & Configure Boot
# =============================================================================
echo -e "${BOLD}─── Step 7: Attaching Disk & Setting Boot Order ─────────${RESET}"
confirm "Attach imported disk to VM and configure boot order?"

info "Attaching disk as scsi0..."
qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-1,discard=on" \
    || qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on" \
    || warn "Could not auto-attach disk. You may need to attach the 'Unused Disk' manually in the Proxmox UI."

info "Setting boot order to scsi0..."
qm set "$VMID" --boot order=scsi0 || warn "Could not set boot order automatically. Set it manually in VM Options."

success "Disk attached and boot order configured."
echo

# =============================================================================
# STEP 8: Cleanup
# =============================================================================
echo -e "${BOLD}─── Step 8: Cleanup ──────────────────────────────────────${RESET}"
confirm "Remove the temporary qcow2 file from /tmp?"
rm -f "$QCOW2FILE"
success "Cleanup done."
echo

# =============================================================================
# STEP 9: Start VM
# =============================================================================
echo -e "${BOLD}─── Step 9: Start VM ─────────────────────────────────────${RESET}"
confirm "Start the HAOS VM now?"
info "Starting VM ${VMID}..."
qm start "$VMID" || error "Failed to start VM. Check the Proxmox UI for details."
success "VM ${VMID} is starting!"
echo

# =============================================================================
# Done
# =============================================================================
echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║           Installation Complete!                     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  HAOS is booting. First boot may take ${BOLD}3-5 minutes${RESET}."
echo -e "  Once ready, open your browser and go to:"
echo -e "  ${BOLD}${CYAN}http://${HAOS_IP}:8123${RESET}"
echo
echo -e "  You can monitor boot progress in the Proxmox web UI:"
echo -e "  ${BOLD}VM ${VMID} → Console${RESET}"
echo
echo -e "${YELLOW}Note: If the Unused Disk was not attached automatically,${RESET}"
echo -e "${YELLOW}go to VM ${VMID} → Hardware → double-click 'Unused Disk' → Add.${RESET}"
echo -e "${YELLOW}Then set Boot Order: VM Options → Boot Order → enable scsi0 first.${RESET}"
echo
