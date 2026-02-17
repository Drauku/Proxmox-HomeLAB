#!/bin/bash

# Consolidated setup scripts used to prepare a Proxmox installation for HomeLab use
# To run this script, download and execute on the target proxmox machine
# wget https://raw.githubusercontent.com/Drauku/Proxmox-HomeLAB/proxmox-homelab-setup.sh && bash proxmox-homelab-setup.sh

# Check if the root filesystem is ZFS
if df -T / | grep -q 'zfs'; then
    echo "ZFS filesystem detected. Creating `rpool@install` snapshot."
    zfs snapshot rpool@install
fi

## add the 'pve-no-subscription' repository to sources.list
echo "deb http://download.proxmox.com/debian/pve $(cat /etc/*-release | grep CODENAME | head -n1 | cut -d '=' -f2) pve-no-subscription" >> /etc/apt/sources.list
# echo "\etc\apt\sources.list updated with pve-no-subscription repository"

## disable the enterprise repository source file
sed -zi '/^deb/s//#&/' /etc/apt/sources.list.d/pve-enterprise.list
# echo "\etc\apt\sources.list.d\pve-enterprise.list renamed so it is not used"

## update and upgrade the Proxmox installation
apt update -y && apt upgrade -y && apt dist-upgrade -y

## disable the Proxmox Subscription Notice with retry logic
NAG_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
SUCCESS=false
for i in 1 2; do
    sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" "$NAG_FILE"
    if grep -q "void({ //Ext.Msg.show" "$NAG_FILE"; then
        SUCCESS=true
        break
    fi
    if [ "$i" -eq 1 ] && [ "$SUCCESS" -eq false ]; then
        sleep 1
    fi
done
# Final action based on the outcome
if [ "$SUCCESS" = true ]; then
    echo "Subscription nag disabled successfully."
    systemctl restart pveproxy.service
    echo "Verification:"
    grep -n -B 1 'No valid sub' "$NAG_FILE"
else
    echo "ERROR: Failed to disable the subscription nag after two attempts."
    echo "The file '$NAG_FILE' may have changed, preventing the script from modifying it."
    echo "A backup of the original file was created at ${NAG_FILE}.bak"
fi
# Credit goes to https://johnscs.com/remove-proxmox51-subscription-notice for the `sed` and `grep` scripts just above

# to revert this change, run the below command to reinstall from the repository
# apt-get install --reinstall proxmox-widget-toolkit

## install Dark Theme for the Proxmox web interface from Weilbyte
#wget https://raw.githubusercontent.com/Weilbyte/PVEDiscordDark/master/PVEDiscordDark.sh && bash PVEDiscordDark.sh install --silent
#echo; echo "Thanks to Weilbyte for creating the Proxmox-GUI Dark Theme: https://github.com/Weilbyte/PVEDiscordDark"

## create a ZFS snapshot labeled 'initconfig'
if df -T / | grep -q 'zfs'; then
    zfs snapshot rpool@initconfig
    echo; echo "ZFS snapshot 'initconfig' created as a checkpoint"
fi

## --- Proxmox Backup Server (PXBS) Integration ---
echo
read -p "Do you want to configure a Proxmox Backup Server? (y/N): " choice
if [[ "$choice" =~ ^[Yy]$ ]]; then
    # Source .env file if it exists
    if [ -f ".env" ]; then
        echo "Found .env file, loading variables..."
        set -a
        source .env
        set +a
    fi
    # For each variable, check if it's set. If not, prompt for it.
    if [ -z "$PXBS_STORAGE_ID" ]; then
        read -p "Enter a local Storage ID for PXBS (e.g., 'pbs-main'): " PXBS_STORAGE_ID
    fi
    if [ -z "$PXBS_ADDRESS" ]; then
        read -p "Enter PXBS Address (IP or hostname): " PXBS_ADDRESS
    fi
    if [ -z "$PXBS_USERNAME" ]; then
        read -p "Enter PXBS Username (e.g., backup-user@pbs): " PXBS_USERNAME
    fi
    if [ -z "$PXBS_PASSWORD" ]; then
        read -s -p "Enter PXBS Password: " PXBS_PASSWORD
    fi
    if [ -z "$PXBS_DATASTORE" ]; then
        read -p "Enter PXBS Datastore name on the server: " PXBS_DATASTORE
    fi
    if [ -z "$PXBS_FINGERPRINT" ]; then
        read -p "Enter PXBS Certificate Fingerprint: " PXBS_FINGERPRINT
    fi
    echo "Adding PXBS storage to Proxmox VE..."
    pvesm add pbs "$PXBS_STORAGE_ID" --server "$PXBS_ADDRESS" --datastore "$PXBS_DATASTORE" \
        --username "$PXBS_USERNAME" --password "$PXBS_PASSWORD" --fingerprint "$PXBS_FINGERPRINT"
    if [ $? -eq 0 ]; then
        echo "Successfully added Proxmox Backup Server storage '$PXBS_STORAGE_ID'."
    else
        echo "Failed to add Proxmox Backup Server. Please check the details and try the 'pvesm' command manually."
    fi
fi

## final message and reminder
echo
echo "Proxmox has been configured for HOBBY-USE IN A NON-COMMERCIAL (HOME) ENVIRONMENT."
echo "Please consider purchasing a support subscription to the Proxmox project."
echo "https://www.proxmox.com/proxmox-ve/pricing"
echo

## reboot the system to start fresh
echo
read -p "Some of these changes might benefit from a reboot. Do you want to reboot now? (y/N): " choice
if [[ "$choice" =~ ^[Yy]$ ]]; then
    reboot
fi
