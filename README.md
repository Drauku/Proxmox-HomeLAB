# Proxmox-HomeLAB
Proxmox HomeLAB environment, consolidated configuration scripts.

**NOTE**: This repository might not work, and does some stuff you might not want done. Instead, check out the communuty run Helper-Scripts here:

 https://github.com/community-scripts/ProxmoxVE or https://helper-scripts.com/

 Thank you, tteck, for starting something amazing.

Obsolete content:

- **WARNING**: Do not run this script unless you understand what each line does.
- **NOTE**: I am not responsible for anything that might happen to your systdem as a result of this script.

* SETUP: run this bash command in the terminal of a new (freshly installed) Proxmox node:

```bash
wget -qO- https://raw.githubusercontent.com/Drauku/Proxmox-HomeLAB/main/proxmox-homelab-setup.sh | bash
```

* IMAGES: run the below command on a Proxmox node to download and create cloud images:

```bash
wget -qO- https://raw.githubusercontent.com/Drauku/Proxmox-HomeLAB/main/download_cloud_images.sh | bash
```

Operations in the script:
1. Create a ZFS checkpoint prior to running this script.
2. Add the PVE No Subscription repository source for those of us not using Proxmox commercially.
3. Disable the Enterprise repository source for the same reason as nr2.
4. Update and Upgrade the distro.
5. Optional: Disable the Proxmox subscription nag screen. Please consider purchashing a subscription to support the amazing team at Proxmox!
  - Thanks to https://johnscs.com/remove-proxmox51-subscription-notice for breaking down this procedure into two quick commands.
6. ~~Install the PVEDiscordDark theme for the Proxmox GUI~~
  - Thanks to Weilbyte for his work on the PVEDiscordDark theme here: https://github.com/Weilbyte/PVEDiscordDark
7. Create a new ZFS snapshot called `initconfig` after this script is complete.
