#!/bin/bash
set -u

# Based on the original approach from:
# https://www.apalrd.net/posts/2023/pve_cloud/

red=$(tput setaf 1 2>/dev/null || true)
grn=$(tput setaf 2 2>/dev/null || true)
ylw=$(tput setaf 3 2>/dev/null || true)
rst=$(tput sgr0 2>/dev/null || true)

export ssh_keyfile="/etc/pve/priv/authorized_keys"
export username="${2:-admin}"
storage=$(pvesm status | awk '/local-/{print $1; exit}')
vm_confs="/etc/pve/qemu-server"
vm_image="/var/lib/vz/template/iso"

ip_addr="192.168.186.100"
ip_cidr="${ip_addr}/24"
netmask="255.255.255.0"
gateway="192.168.186.254"
dns0="192.168.186.253"
dns1="9.9.9.9"
dns2="1.1.1.1"

# Distro definitions
# format:
# distro;vmid;template-name;local-image-name;image-url;checksum-or-checksum-url
# Notes:
# - Debian uses the stable 'latest' bookworm path.
# - Ubuntu uses current Noble LTS path.
# - Rocky 10 currently publishes GenericCloud Base under vault/10.0.
# - Fedora uses the current stable release shown on Fedora Cloud download page (44 at time of writing).
# - Arch uses the current mirror filename cloudimg, not cloudinit.
# - Alpine uses latest-stable NoCloud BIOS qcow2 for Proxmox/KVM.
distros=(
    "arch;9000;tmpl-arch-latest;arch-latest.qcow2;https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2;https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2.SHA256"
    "alpine;9022;tmpl-alpine-3-22;alpine-3.22.qcow2;https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/cloud/nocloud_alpine-virt-3.22.2-x86_64-bios-cloudinit-r0.qcow2;"
    "debian;9113;tmpl-debian-12;debian-12.qcow2;https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2;https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"
    "ubuntu;9125;tmpl-ubuntu-25;ubuntu-25-04.img;https://cloud-images.ubuntu.com/releases/plucky/release/ubuntu-25.04-server-cloudimg-amd64.img;534cbf0c44e86862535502f853829cefb771d19991892a31d14827d985829612"
    "rocky;9210;tmpl-rocky-10;rocky-10.qcow2;https://dl.rockylinux.org/vault/rocky/10.0/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2;https://dl.rockylinux.org/vault/rocky/10.0/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2.CHECKSUM"
    "coreos;9223;tmpl-coreos-stable;coreos.qcow2.xz;https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/43.20260119.3.1/x86_64/fedora-coreos-43.20260119.3.1-qemu.x86_64.qcow2.xz;76f1d1c22d09ac27a6ff2c78fc9418d82307f23a9fd558e40a289ff5a3212bcd"
    "fedora;9244;tmpl-fedora-44;fedora-44.qcow2;https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-20260424.n.0.x86_64.qcow2;https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-images-44-x86_64-20260424.n.0-CHECKSUM"
)

show_help() {
    echo "${ylw}Usage:${rst} $0 [all|distro] [username]"
    echo ""
    echo "  ${grn}No arguments or 'all':${rst} Runs default batch."
    echo "  ${grn}Specific distro:${rst} $0 debian"
    echo "  ${grn}Custom user:${rst} $0 all newuser"
    echo "  ${grn}Available distros:${rst} all, $(get_distro_names)"
    echo "  ${grn}One-off input:${rst} $0 900 \"tmpl-custom\" \"image.qcow2\" \"https://example.com/image.qcow2\" [checksum]"
}

webtest() {
  local target="cloudflare.com"
  curl -sf --connect-timeout 5 -o /dev/null "https://$target"
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

    [[ -z "$input" ]] && echo "${ylw}No checksum provided. Skipping verification.${rst}" && return 0

    local expected_sum=""

    if [[ "$input" =~ ^https?:// ]]; then
        echo "Fetching checksum file from remote..."
        local sum_file
        sum_file=$(mktemp)

        if ! wget -q "$input" -O "$sum_file"; then
            echo "${red}Failed to download checksum file.${rst}"
            rm -f "$sum_file"
            return 1
        fi

        local filename match
        filename=$(basename "$file")
        match=$(grep -F "$filename" "$sum_file" | head -n1)
        rm -f "$sum_file"

        if [[ -z "$match" ]]; then
            echo "${red}Filename '$filename' not found in remote checksum file.${rst}"
            return 1
        fi

        if [[ "$match" == *" = "* ]]; then
            expected_sum=$(echo "$match" | awk -F ' = ' '{print $2}')
        else
            expected_sum=$(echo "$match" | awk '{print $1}')
        fi
        echo "Found hash: ${expected_sum:0:12}..."
    else
        expected_sum="$input"
    fi

    local cmd=""
    case ${#expected_sum} in
        64)  cmd="sha256sum" ;;
        128) cmd="sha512sum" ;;
        *) echo "${ylw}Unknown hash length (${#expected_sum}). Skipping.${rst}"; return 0 ;;
    esac

    if echo "$expected_sum  $file" | $cmd --check --status; then
        echo "${grn}Checksum verified ($cmd).${rst}"
        return 0
    else
        echo "${red}Checksum mismatch!${rst}"
        return 1
    fi
}

create_template() {
    local vmid="$1"
    local name="$2"
    local image="$3"
    local url="$4"
    local csum="${5:-}"
    local max_attempts=3
    local attempt=1
    local success=false

    if ! manage_existing "$vmid"; then return 0; fi
    if ! webtest; then
        echo "${red}CRITICAL${rst}: DNS resolution or internet failure."
        return 1
    fi

    mkdir -p "$vm_image"
    cd "$vm_image" || return 1

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
        echo "${ylw}Failed to acquire valid image after $max_attempts attempts.${rst} Moving to next task."
        return 1
    fi

    echo "Creating template $name ($vmid)"
    qm create "$vmid" --name "$name" --ostype l26

    echo "Importing disk to $storage..."
    if ! qm set "$vmid" --scsi0 "${storage}:0,import-from=$(pwd)/$image,discard=on"; then
        echo "${ylw}Import failed.${rst} Checking if decompression is needed..."
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
            echo "${red}Failed to import disk even after extraction.${rst} Cleanup..."
            rm -f "$image"
            qm destroy "$vmid" --purge >/dev/null 2>&1 || true
            return 1
        fi
    fi

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

download_distro() {
    local distro_name="$1"
    for distro_data in "${distros[@]}"; do
        if [[ "$distro_data" == "$distro_name"* ]]; then
            IFS=';' read -r -a params <<< "$distro_data"
            create_template "${params[1]}" "${params[2]}" "${params[3]}" "${params[4]}" "${params[5]}"
            return
        fi
    done
    echo "${red}Distro '$distro_name' not found.${rst}"
}

get_distro_names() {
    for distro_data in "${distros[@]}"; do
        echo -n "$(echo "$distro_data" | cut -d';' -f1) "
    done
    echo ""
}

is_distro() {
    local name="$1"
    [[ "$name" == "all" ]] && return 0
    for distro_data in "${distros[@]}"; do
        if [[ "$distro_data" == "$name"* ]]; then
            return 0
        fi
    done
    return 1
}

main() {
    if [ "$#" -ge 4 ] && ! is_distro "$1"; then
        create_template "$1" "$2" "$3" "$4" "$5"
        exit 0
    fi

    read -r -p "Current username will be: ${username}. Continue? (Y/n/[u]pdate): " choice
    case "$choice" in
        n|N )
            echo "Exiting..."
            exit 1
            ;;
        u|U )
            while true; do
                read -r -p "New username (alphanumeric, starts with letter): " new_username
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

    distro_to_download="${1:-all}"

    if is_distro "$distro_to_download"; then
        if [ "$distro_to_download" == "all" ]; then
            for distro_data in "${distros[@]}"; do
                distro_name=$(echo "$distro_data" | cut -d';' -f1)
                download_distro "$distro_name"
            done
        else
            download_distro "$distro_to_download"
        fi
    else
        show_help
    fi
}

main "$@"
