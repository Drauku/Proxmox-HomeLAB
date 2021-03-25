## Consolidated setup scripts used to prepare a Proxmox installation for HomeLab use
# To run this script, download and execute on the target proxmox machine
# wget https://raw.githubusercontent.com/Drauku/Proxmox-HomeLAB/proxmox-homelab-setup.sh && bash proxmox-homelab-setup.sh

zfs snapshot rpool@install
echo "ZFS snapshot 'install' created as a checkpoint"


## add the 'pve-no-subscription' repository to sources.list
echo "deb http://download.proxmox.com/debian/pve buster pve-no-subscription" >> /etc/apt/sources.list
# echo "\etc\apt\sources.list updated with pve-no-subscription repository"


## disable the enterprise repository source file
sed -zi '/^deb/s//#&/' /etc/apt/sources.list.d/pve-enterprise.list
# echo "\etc\apt\sources.list.d\pve-enterprise.list renamed so it is not used"


## update and upgrade the Proxmox installation
apt update -y && apt upgrade -y && apt dist-upgrade -y


## disable the Proxmox Subscription Notice when logging in
sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js && systemctl restart pveproxy.service
# echo "Login prompt nag-message for not having a subscription removed."

# test that the change was successful
grep -n -B 1 'No valid sub' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
# Credit goes to https://johnscs.com/remove-proxmox51-subscription-notice for the `sed` and `grep` scripts just above

# to revert this change, run the below command to reinstall from the repository
# apt-get install --reinstall proxmox-widget-toolkit


## install Dark Theme for the Proxmox web interface from Weilbyte
wget https://raw.githubusercontent.com/Weilbyte/PVEDiscordDark/master/PVEDiscordDark.sh && bash PVEDiscordDark.sh install --silent


## create a ZFS snapshot labeled 'install'
zfs snapshot rpool@initconfig
echo; echo "ZFS snapshot 'initconfig' created as a checkpoint"


## final message and reminder
echo
echo "Proxmox has been configured for HOBBY-USE IN A NON-COMMERCIAL (HOME) ENVIRONMENT."
echo "Please consider purchasing a support subscription to the Proxmox project."
echo "https://www.proxmox.com/proxmox-ve/pricing"
echo

## reboot the system to start fresh
# reboot
