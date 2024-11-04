# Proxmox-HomeLAB
Proxmox HomeLAB environment, consolidated configuration scripts.

**NOTE**: This repository should not be used, instead check out the communuty run Helper-Scripts here: 
 
 https://github.com/community-scripts/ProxmoxVE or https://helper-scripts.com/
 
 Thank you, tteck, for starting something amazing.

Obsolete content:

- **WARNING**: Do not run this script unless you understand what each line does.
- **NOTE**: I am not responsible for anything that might happen to your systdem as a result of this script.
- **NOTE**: This script is built to run on Proxmox 6.x versions, i.e. the "buster" codename.

* SETUP: run this bash command in the terminal of a new (freshly installed) Proxmox node:
* NOTE: The PVE installation must use ZFS for the boot partition, or you can comment those lines out.

```bash
wget https://raw.githubusercontent.com/Drauku/Proxmox-HomeLAB/main/proxmox-homelab-setup.sh && proxmox-homelab-setup.sh
```

Operations in the script:
1. Create a ZFS checkpoint prior to running this script.
2. Add the PVE No Subscription repository source for those of us not using Proxmox commercially.
3. Disable the Enterprise repository source for the same reason as nr2.
4. Update and Upgrade the distro.
5. Optionl: Disable the Proxmox subscription nag screen. Please consider purchashing a subscription to support the amazing team at Proxmox!
  - Thanks to https://johnscs.com/remove-proxmox51-subscription-notice for breaking down this procedure into two quick commands.
6. Install the PVEDiscordDark theme for the Proxmox GUI
  - Thanks to Weilbyte for his work on the PVEDiscordDark theme here: https://github.com/Weilbyte/PVEDiscordDark
7. Create a new ZFS snapshot called `initconfig` after this script is complete.
