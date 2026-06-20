#!/bin/bash

# Consolidated setup scripts used to prepare a Proxmox installation for HomeLab use
# To run this script, download and execute on the target proxmox machine
# wget https://raw.githubusercontent.com/Drauku/Proxmox-HomeLAB/proxmox-homelab-setup.sh && bash proxmox-homelab-setup.sh

# Function to remove duplicate lines from a file while preserving order
cleanup_duplicates() {
    if [ -f "$1" ]; then
        awk '!seen[$0]++' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
    fi
}

# Check if the root filesystem is ZFS, create "install" snapshot if it is
if df -T / | grep -q 'zfs'; then
    echo "ZFS filesystem detected. Creating `rpool@install` snapshot."
    zfs snapshot rpool@install
fi

# Add the PVE no-subscription repository, but only if it's not already present.
# This prevents duplicate entries if the script is run multiple times.
CODENAME=$(cat /etc/*-release | grep CODENAME | head -n1 | cut -d '=' -f2)
REPO_LINE="deb http://download.proxmox.com/debian/pve $CODENAME pve-no-subscription"
if ! grep -qF "$REPO_LINE" /etc/apt/sources.list; then
    echo "$REPO_LINE" >> /etc/apt/sources.list
    echo "PVE no-subscription repository added."
else
    echo "PVE no-subscription repository already configured."
fi

# Disable enterprise repositories to prevent '401 Unauthorized' errors.
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
    sed -i 's/^deb/#&/' /etc/apt/sources.list.d/pve-enterprise.list
    echo "pve-enterprise.list disabled."
fi
if [ -f /etc/apt/sources.list.d/ceph.list ]; then
    # Only comment out enterprise ceph repos
    if grep -q "enterprise.proxmox.com" /etc/apt/sources.list.d/ceph.list; then
        sed -i 's/^deb/#&/' /etc/apt/sources.list.d/ceph.list
        echo "Ceph enterprise repository disabled."
    fi
fi

# Check for and clean up duplicate entries from all sources lists
FOUND_DUPES=false
for f in "/etc/apt/sources.list" /etc/apt/sources.list.d/*.list; do
    if [ -f "$f" ]; then
        # If awk exits with non-zero status, duplicates were found.
        if ! awk 'seen[$0]++{exit 1}' "$f"; then
            FOUND_DUPES=true
            break # Exit the loop as soon as we find any duplicates
        fi
    fi
done

if [ "$FOUND_DUPES" = true ]; then
    echo "Duplicate repository entries found. Cleaning up..."
    cleanup_duplicates "/etc/apt/sources.list"
    for f in /etc/apt/sources.list.d/*.list; do
        cleanup_duplicates "$f"
    done
else
    echo "No duplicate repository entries found."
fi

## update and upgrade the Proxmox installation
apt update -y && apt upgrade -y && apt dist-upgrade -y

# --- UI Tweaks ---
# Disable the Proxmox Subscription Notice
NAG_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
if [ -f "$NAG_FILE" ]; then
    if ! grep -q "void({ //Ext.Msg.show" "$NAG_FILE"; then
        echo "Disabling subscription nag..."
        sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" "$NAG_FILE"
        systemctl restart pveproxy.service
        echo "A backup of the original file was created at ${NAG_FILE}.bak"
    else
        echo "Subscription nag already disabled."
    fi
else
    echo "INFO: Subscription nag file not found, skipping."
fi

# Credit goes to https://johnscs.com/remove-proxmox51-subscription-notice for the `sed` and `grep` scripts just above

# to revert this change, run the below command to reinstall from the repository
# apt-get install --reinstall proxmox-widget-toolkit

## install Dark Theme for the Proxmox web interface from Weilbyte
#wget https://raw.githubusercontent.com/Weilbyte/PVEDiscordDark/master/PVEDiscordDark.sh && bash PVEDiscordDark.sh install --silent
#echo; echo "Thanks to Weilbyte for creating the Proxmox-GUI Dark Theme: https://github.com/Weilbyte/PVEDiscordDark"

# --- Proxmox Backup Server (PXBS) Integration ---
echo
echo -n "Do you want to configure a Proxmox Backup Server? (y/N): "
read -r choice < /dev/tty
if [[ "$choice" =~ ^[Yy]$ ]]; then
    if [ -f ".env" ]; then
        echo "Found .env file, loading variables..."
        set -a; source .env; set +a
    fi

    [[ -z "$PXBS_STORAGE_ID" ]] && echo -n "Enter a local Storage ID for PXBS (e.g., 'pbs-main'): " && read -r PXBS_STORAGE_ID < /dev/tty
    [[ -z "$PXBS_ADDRESS" ]] && echo -n "Enter PXBS Address (IP or hostname): " && read -r PXBS_ADDRESS < /dev/tty
    [[ -z "$PXBS_USERNAME" ]] && echo -n "Enter PXBS Username (e.g., backup-user@pbs): " && read -r PXBS_USERNAME < /dev/tty
    [[ -z "$PXBS_PASSWORD" ]] && echo -n "Enter PXBS Password: " && read -r PXBS_PASSWORD < /dev/tty
    [[ -z "$PXBS_DATASTORE" ]] && echo -n "Enter PXBS Datastore name on the server: " && read -r PXBS_DATASTORE < /dev/tty
    [[ -z "$PXBS_FINGERPRINT" ]] && echo -n "Enter PXBS Certificate Fingerprint: " && read -r PXBS_FINGERPRINT < /dev/tty

    echo "Adding PXBS storage to Proxmox VE..."
    pvesm add pbs "$PXBS_STORAGE_ID" --server "$PXBS_ADDRESS" --datastore "$PXBS_DATASTORE"
        --username "$PXBS_USERNAME" --password "$PXBS_PASSWORD" --fingerprint "$PXBS_FINGERPRINT"
    if [ $? -eq 0 ]; then
        echo "Successfully added Proxmox Backup Server storage '$PXBS_STORAGE_ID'."
    else
        echo "Failed to add Proxmox Backup Server. Please check the details and try the 'pvesm' command manually."
    fi
fi

## create a ZFS snapshot labeled 'initconfig'
if df -T / | grep -q 'zfs'; then
    zfs snapshot rpool@initconfig
    echo; echo "ZFS snapshot 'initconfig' created as a checkpoint"
fi

## outro and reminder
echo
echo "Proxmox has been configured for HOBBY-USE IN A NON-COMMERCIAL (HOME) ENVIRONMENT."
echo "Please consider purchasing a support subscription to the Proxmox project."
echo "https://www.proxmox.com/proxmox-ve/pricing"
echo

## reboot the system to start fresh
echo
echo -n "Some of these changes might benefit from a reboot. Do you want to reboot now? (y/N): "
read -r choice < /dev/tty
if [[ "$choice" =~ ^[Yy]$ ]]; then
    reboot
fi
