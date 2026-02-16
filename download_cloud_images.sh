#!/bin/bash

# Original logic from https://www.apalrd.net/posts/2023/pve_cloud/

# Colors using tput fallback
red=$(tput setaf 1)
grn=$(tput setaf 2)
ylw=$(tput setaf 3)
rst=$(tput sgr0)

# Variables
export ssh_keyfile="/etc/pve/priv/authorized_keys"
export username="${1:-admin}"
storage=$(pvesm status | awk '/local-/{print $1; exit}')
vm_confs="/etc/pve/qemu-server"
vm_image="/var/lib/vz/template/iso"

# For static IP address, not used until template is closed
ip_addr="192.168.186.100"
ip_cidr="${ip_addr}/24"
netmask="255.255.255.0"
gateway="192.168.186.254"
dns0="192.168.186.253"
dns1="9.9.9.9"
dns2="1.1.1.1"

show_help() {
    echo "${ylw}Usage:${rst} $0 [vmid] [name] [filename] [url]"
    echo ""
    echo "  ${grn}No arguments:${rst} Runs default batch (Debian, Ubuntu, Fedora, Rocky, CoreOS)."
    echo "  ${grn}One-off input:${rst} $0 900 \"tmpl-custom\" \"image.qcow2\" \"https://example.com/image.qcow2\""
}

webtest(){
    local target="cloudflare.com"
    if curl -sf --connect-timeout 5 -o /dev/null "https://$target"; then
        return 0
    else
        return 1
    fi
}

manage_existing() {
    local vmid="$1"
    if [[ -f "$vm_confs/$vmid.conf" ]]; then
        echo "${ylw}Template $vmid already exists.${rst}"
        read -p "Would you like to destroy and recreate it? (y/N): " choice
        case "$choice" in
            y|Y )
                echo "Destroying template $vmid..."
                qm destroy "$vmid" --purge
                return 0
                ;;
            * )
                echo "Skipping $vmid."
                return 1
                ;;
        esac
    fi
    return 0
}

verify_checksum() {
    local file="$1"
    local input="${2:-}"

    # Return success immediately if no checksum provided
    [[ -z "$input" ]] && echo "${ylw}No checksum provided. Skipping verification.${rst}" && return 0

    local expected_sum=""

    # Detect if input is a URL
    if [[ "$input" =~ ^https?:// ]]; then
        echo "Fetching checksum file from remote..."
        local sum_file=$(mktemp)

        # Download the checksum file
        if ! wget -q "$input" -O "$sum_file"; then
            echo "${red}Failed to download checksum file.${rst}"
            rm -f "$sum_file"
            return 1
        fi

        # Find the line matching the filename
        local filename=$(basename "$file")
        local match=$(grep "$filename" "$sum_file")
        rm -f "$sum_file"

        if [[ -z "$match" ]]; then
            echo "${red}Filename '$filename' not found in remote checksum file.${rst}"
            return 1
        fi

        # Extract hash: Handle BSD format (Fedora) vs Standard (Debian/Ubuntu)
        if [[ "$match" == *" = "* ]]; then
            # BSD format: SHA256 (filename) = <hash>
            expected_sum=$(echo "$match" | awk -F ' = ' '{print $2}')
        else
            # Standard format: <hash>  filename
            expected_sum=$(echo "$match" | awk '{print $1}')
        fi
        echo "Found hash: ${expected_sum:0:12}..."
    else
        # Input is a raw hash string
        expected_sum="$input"
    fi

    # Determine Algorithm based on hash length
    local cmd=""
    case ${#expected_sum} in
        64)  cmd="sha256sum" ;;
        128) cmd="sha512sum" ;;
        *)   echo "${ylw}Unknown hash length (${#expected_sum}). Skipping.${rst}"; return 0 ;;
    esac

    # Perform Verification
    if echo "$expected_sum  $file" | $cmd --check --status; then
        echo "${grn}Checksum verified ($cmd).${rst}"
        return 0
    else
        echo "${red}Checksum Mismatch!${rst}"
        return 1
    fi
}

create_template(){ # syntax: create_template <vmid> <name> <image> <url> [checksum]
    local vmid="$1"
    local name="$2"
    local image="$3"
    local url="$4"
    local csum="${5:-}"
    local max_attempts=3
    local attempt=1
    local success=false

    if ! manage_existing "$vmid"; then return; fi
    if ! webtest; then
        echo "${red}CRITICAL: DNS Resolution or Internet failure.${rst}"
        return 1
    fi

    # --- Download & Verify Loop ---
    while (( attempt <= max_attempts )); do
        echo "Attempt $attempt of $max_attempts: Downloading $image..."
        if wget -q --show-progress "$url" -O "$image"; then
            if verify_checksum "$image" "$csum"; then
                success=true
                break
            else
                echo "${red}Verification failed. Deleting corrupt image...${rst}"
                rm -f "$image"
            fi
        else
            echo "${red}Download failed for $url${rst}"
        fi
        ((attempt++))
        [[ $attempt -le $max_attempts ]] && echo "Retrying..."
    done

    if [[ "$success" != "true" ]]; then
        echo "${red}Failed to acquire valid image after $max_attempts attempts. Moving to next task.${rst}"
        return 1
    fi

    # --- Proxmox Configuration Logic ---
    echo "Creating template $name ($vmid)"
    qm create "$vmid" --name "$name" --ostype l26

    # Attempt to import disk
    echo "Importing disk to $storage..."
    if ! qm set "$vmid" --scsi0 "${storage}:0,import-from=$(pwd)/$image,discard=on"; then
        echo "${ylw}Import failed. Checking if decompression is needed...${rst}"

        if [[ "$image" == *.xz ]]; then
            echo "Extracting .xz file..."
            xz -d "$image"
            image="${image%.xz}"
        elif [[ "$image" == *.gz ]]; then
            echo "Extracting .gz file..."
            gunzip "$image"
            image="${image%.gz}"
        fi

        echo "Retrying import with $image..."
        if ! qm set "$vmid" --scsi0 "${storage}:0,import-from=$(pwd)/$image,discard=on"; then
            echo "${red}Failed to import disk even after extraction. Cleanup...${rst}"
            rm -f "$image"
            qm destroy "$vmid"
            return 1
        fi
    fi

    # Continue with remaining configuration
    qm set "$vmid" --net0 virtio,bridge=vmbr0
    qm set "$vmid" --serial0 socket --vga serial0
    qm set "$vmid" --memory 1024 --cores 2 --cpu x86-64-v2-AES
    qm set "$vmid" --boot order=scsi0 --scsihw virtio-scsi-single
    qm set "$vmid" --agent enabled=1,fstrim_cloned_disks=1
    qm set "$vmid" --ide2 "${storage}:cloudinit"
    qm set "$vmid" --ipconfig0 "ip6=auto,ip=dhcp"
    qm set "$vmid" --sshkeys "${ssh_keyfile}"
    qm set "$vmid" --ciuser "${username}"
    qm disk resize "$vmid" scsi0 8G
    qm template "$vmid"

    rm -f "$image"
    echo "${grn}Successfully created template $vmid with username: ${username}${rst}"
}

main(){
    if [ "$#" -eq 4 ]; then
        create_template "$1" "$2" "$3" "$4"
    elif [ "$#" -gt 0 ]; then
        show_help
    else
        # echo "Running default batch..."
        read -r -p "Current username will be: ${username}. Continue? (Y/n/[u]pdate): " choice
        case "$choice" in
            n|N )
                echo "Exiting..."
                exit 1
                ;;
            u|U )
                while true; do
                    read -r -p "New username (alphanumeric, starts with letter): " new_username
                    # Regex: Starts with letter, followed by lowercase letters, numbers, or hyphens
                    if [[ "$new_username" =~ ^[a-z][a-z0-9-]*$ ]]; then
                        username="$new_username"
                        echo "Username updated to: $username"
                        break
                    else
                        echo "${red}Invalid username.${rst} Use lowercase letters, numbers, and hyphens only (start with a letter)."
                    fi
                done
                ;;
            * ) ;;
        esac
        # create_template 912 "tmpl-debian-12" "debian-12.qcow2" \
        # "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
        create_template 9013 "tmpl-debian-13" "debian-13.qcow2" \
        "https://cloud.debian.org/images/cloud/bookworm/20260210-2384/debian-12-genericcloud-amd64-20260210-2384.qcow2" \
        "e5d776b9de352c89fbad4baec8bfd38a35c5905114a5f3b108946348cb44d869396d22e4a837a43afee4b11363d4759c358fb3e8a7cd07fa743ed6b663784fed"
-
        # create_template 9024 "tmpl-ubuntu-24-04" "ubuntu-24-04.img" \
        # "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img" \
        # "2f9acc20a381cde6fa678672e20a1408d2b3f346531b9026df2a935c37d2de20"

        create_template 9025 "tmpl-ubuntu-25" "ubuntu-25-04.img" \
        "https://cloud-images.ubuntu.com/releases/plucky/release/ubuntu-25.04-server-cloudimg-amd64.img" \
        "534cbf0c44e86862535502f853829cefb771d19991892a31d14827d985829612"

        # "https://cloud-images.ubuntu.com/minimal/releases/plucky/release/ubuntu-25.04-minimal-cloudimg-amd64.img" \
        # "9100043b7810ca4af933eeea7cb5c7d2806407b586086664b17254598550e71a"

        # create_template 943 "tmpl-fedora-43" "fedora-43.qcow2" \
        # "https://paducahix.mm.fcix.net/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2"
        create_template 9143 "tmpl-fedora-43" "fedora-43.qcow2" \
        "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2" \
        "846574c8a97cd2d8dc1f231062d73107cc85cbbbda56335e264a46e3a6c8ab2f" # sha256

        # create_template 9109 "tmpl-rocky-9" "rocky-9.qcow2" \
        # "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2" \
        # "15d81d3434b298142b2fdd8fb54aef2662684db5c082cc191c3c79762ed6360c"

        create_template 9110 "tmpl-rocky-10" "rocky-10.qcow2" \
        "https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2" \
        "28628abf08a134c6f9e1eccbcac3f2898715919a6da294ae2c6cd66d6bc347ad" # sha256

        # create_template 941 "tmpl-coreos" "coreos.qcow2.xz" \
        # "https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/41.20250125.3.0/x86_64/fedora-coreos-41.20250125.3.0-qemu.x86_64.qcow2.xz"
        create_template 9123 "tmpl-coreos-43" "coreos.qcow2.xz" \
        "https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/43.20260119.3.1/x86_64/fedora-coreos-43.20260119.3.1-qemu.x86_64.qcow2.xz" \
        "76f1d1c22d09ac27a6ff2c78fc9418d82307f23a9fd558e40a289ff5a3212bcd" # sha256

        # The NixOS OpenStack image link is incorrect
        # create_template 9225 "tmpl-nixos-25-11" "nixos-25-11.qcow2" \
        # "https://hydra.nixos.org/job/nixos/release-25.11/nixos.openstack-image.x86_64-linux/latest/download/1" \
        # ""
    fi
}

main "$@"
