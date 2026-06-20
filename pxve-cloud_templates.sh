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

DEFAULT_VGA="default"
DEFAULT_SERIAL="socket"

distros=(
    "debian;9013;tmpl-debian-13;debian-13.qcow2;debian"
    "ubuntu;9026;tmpl-ubuntu-26-04;ubuntu-26-04.img;ubuntu"
    "rocky;9110;tmpl-rocky-10;rocky-10.qcow2;rocky"
    "coreos;9123;tmpl-coreos-stable;coreos.qcow2.xz;coreos"
    "fedora;9144;tmpl-fedora-latest;fedora-latest.qcow2;fedora"
    "arch;9200;tmpl-arch-latest;arch-latest.qcow2;arch"
    "alpine;9322;tmpl-alpine-latest;alpine-latest.qcow2;alpine"
)

show_help() {
    echo "${ylw}Usage:${rst} $0 [all|distro] [username]"
    echo ""
    echo "    ${grn}No arguments or 'all':${rst} Runs default batch."
    echo "    ${grn}Specific distro:${rst} $0 debian"
    echo "    ${grn}Custom user:${rst} $0 all newuser"
    echo "    ${grn}Available distros:${rst} all, $(get_distro_names)"
    echo "    ${grn}One-off input:${rst} $0 900 \"tmpl-custom\" \"image.qcow2\" \"https://example.com/image.qcow2\" [checksum]"
}

webtest() {
    curl -sf --connect-timeout 5 -o /dev/null "https://cloudflare.com"
}

manage_existing() {
    local vmid="$1"
    if [[ -f "$vm_confs/$vmid.conf" ]]; then
        echo "${ylw}Template/VM $vmid already exists.${rst}"
        read -r -p "Would you like to destroy and recreate it? (y/N): " choice
        case "$choice" in
            y|Y)
                echo "Destroying template $vmid..."
                qm destroy "$vmid" --purge
                return 0
                ;;
            *)
                echo "Skipping $vmid."
                return 1
                ;;
        esac
    fi
    return 0
}

resolve_debian() {
    local root_html suite suite_path page version image_prefix
    root_html=$(curl -fsSL "https://cloud.debian.org/images/cloud/") || return 1
    suite_path=$(printf '%s' "$root_html" | grep -oE 'href="[a-z]+/"' | cut -d'"' -f2 | sed 's:/$::' | while read -r suite; do
        page=$(curl -fsSL "https://cloud.debian.org/images/cloud/${suite}/latest/") || continue
        version=$(printf '%s' "$page" | grep -oE 'debian-[0-9]+-genericcloud-amd64\.qcow2' | head -n1 | grep -oE '[0-9]+')
        [[ -n "$version" ]] && printf '%s %s
' "$version" "$suite"
    done | sort -V | tail -n1 | awk '{print $2}')
    [[ -z "$suite_path" ]] && return 1
    page=$(curl -fsSL "https://cloud.debian.org/images/cloud/${suite_path}/latest/") || return 1
    image_prefix=$(printf '%s' "$page" | grep -oE 'debian-[0-9]+-genericcloud-amd64' | head -n1)
    [[ -z "$image_prefix" ]] && return 1
    RESOLVED_URL="https://cloud.debian.org/images/cloud/${suite_path}/latest/${image_prefix}.qcow2"
    RESOLVED_SUM="https://cloud.debian.org/images/cloud/${suite_path}/latest/SHA512SUMS"
}

resolve_ubuntu() {
    local releases_html codename release_page latest_path version
    releases_html=$(curl -fsSL "https://cloud-images.ubuntu.com/releases/") || return 1
    latest_path=$(printf '%s' "$releases_html" | grep -oE 'releases/[a-z]+/release/' | sort -u | while read -r p; do
        codename=$(basename "$(dirname "$p")")
        release_page="https://cloud-images.ubuntu.com/${p}"
        page=$(curl -fsSL "$release_page") || continue
        version=$(printf '%s' "$page" | grep -oE 'ubuntu-[0-9]+\.[0-9]+-server-cloudimg-amd64\.img' | head -n1 | grep -oE '[0-9]+\.[0-9]+')
        case "$version" in
            *.04) printf '%s %s
' "$version" "$p" ;;
        esac
    done | sort -V | tail -n1 | awk '{print $2}')
    [[ -z "$latest_path" ]] && return 1
    RESOLVED_URL="https://cloud-images.ubuntu.com/${latest_path}ubuntu-$(curl -fsSL "https://cloud-images.ubuntu.com/${latest_path}" | grep -oE 'ubuntu-[0-9]+\.[0-9]+-server-cloudimg-amd64\.img' | head -n1 | sed 's/-server-cloudimg-amd64\.img//')-server-cloudimg-amd64.img"
    RESOLVED_SUM="https://cloud-images.ubuntu.com/${latest_path}SHA256SUMS"
}

resolve_rocky() {
    RESOLVED_URL="https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
    RESOLVED_SUM="https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2.CHECKSUM"
}

resolve_coreos() {
    local json url sum
    json=$(curl -fsSL "https://builds.coreos.fedoraproject.org/streams/stable.json") || return 1
    url=$(printf '%s' "$json" | python3 -c 'import sys, json; d=json.load(sys.stdin); print(d["architectures"]["x86_64"]["artifacts"]["qemu"]["formats"]["qcow2.xz"]["disk"]["location"])') || return 1
    sum=$(printf '%s' "$json" | python3 -c 'import sys, json; d=json.load(sys.stdin); print(d["architectures"]["x86_64"]["artifacts"]["qemu"]["formats"]["qcow2.xz"]["disk"]["sha256"])') || return 1
    [[ -z "$url" || "$url" == "null" ]] && return 1
    [[ -z "$sum" || "$sum" == "null" ]] && return 1
    RESOLVED_URL="$url"
    RESOLVED_SUM="$sum"
}

resolve_fedora() {
    local html rel base img csum
    html=$(curl -fsSL "https://fedoraproject.org/cloud/download/") || return 1
    rel=$(printf '%s' "$html" | grep -oE 'Fedora Cloud [0-9]+' | head -n1 | grep -oE '[0-9]+')
    [[ -z "$rel" ]] && return 1
    base="https://download.fedoraproject.org/pub/fedora/linux/releases/${rel}/Cloud/x86_64/images"
    img=$(curl -fsSL "$base/" | grep -oE "Fedora-Cloud-Base-Generic(-[0-9A-Za-z._-]+)?\.x86_64\.qcow2|Fedora-Cloud-Base-Generic\.x86_64-${rel}-[0-9A-Za-z._-]+\.qcow2|Fedora-Cloud-Base-Generic-${rel}-[0-9A-Za-z._-]+\.x86_64\.qcow2" | head -n1)
    csum=$(curl -fsSL "$base/" | grep -oE "Fedora-Cloud-[A-Za-z0-9._-]*CHECKSUM" | head -n1)
    [[ -z "$img" || -z "$csum" ]] && return 1
    RESOLVED_URL="$base/$img"
    RESOLVED_SUM="$base/$csum"
}

resolve_arch() {
    RESOLVED_URL="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
    RESOLVED_SUM="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2.SHA256"
}

resolve_alpine() {
    local index file base
    base="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/cloud"
    index=$(curl -fsSL "$base/") || return 1
    file=$(printf '%s' "$index" | grep -oE 'generic_alpine-[0-9.]+-x86_64-bios-cloudinit(-metal)?-r[0-9]+\.qcow2' | sort -V | tail -n1)
    [[ -z "$file" ]] && return 1
    RESOLVED_URL="$base/$file"
    if printf '%s' "$index" | grep -q "${file}\.sha256"; then
        RESOLVED_SUM="$base/${file}.sha256"
    elif printf '%s' "$index" | grep -q "${file}\.sha512"; then
        RESOLVED_SUM="$base/${file}.sha512"
    else
        RESOLVED_SUM=""
    fi
}

resolve_distro() {
    local key="$1"
    RESOLVED_URL=""
    RESOLVED_SUM=""
    case "$key" in
        debian) resolve_debian ;;
        ubuntu) resolve_ubuntu ;;
        rocky) resolve_rocky ;;
        coreos) resolve_coreos ;;
        fedora) resolve_fedora ;;
        arch) resolve_arch ;;
        alpine) resolve_alpine ;;
        *) return 1 ;;
    esac
}

confirm_template() {
    local distro_name="$1"
    local vmid="$2"
    local name="$3"
    local image="$4"
    local url="$5"
    local exists_status="no"

    if [[ -f "$vm_confs/$vmid.conf" ]]; then
        exists_status="yes"
    fi

    echo ""
    echo "${ylw}Ready to create template:${rst} $distro_name"
    echo "    VMID:             $vmid"
    echo "    Name:             $name"
    echo "    Image:            $image"
    echo "    URL:              $url"
    echo "    Already exists:   $exists_status"
    while true; do
        read -r -p "Approve this template task? (Y/n): " choice
        case "$choice" in
            ''|y|Y) return 0 ;;
            n|N) echo "${ylw}Skipped $distro_name by user choice.${rst}"; return 1 ;;
            *) echo "Please answer Y or n." ;;
        esac
    done
}

verify_checksum() {
    local file input source_name expected_sum
    file="$1"
    input="${2:-}"
    source_name="${3:-$(basename "$file")}"
    expected_sum=""

    [[ -z "$input" ]] && echo "${ylw}No checksum provided. Skipping verification.${rst}" && return 0

    if [[ "$input" =~ ^https?:// ]]; then
        echo "Fetching checksum file from remote..."
        local sum_file match
        sum_file=$(mktemp)

        if ! wget -q "$input" -O "$sum_file"; then
            echo "${red}Failed to download checksum file.${rst}"
            rm -f "$sum_file"
            return 1
        fi

        match=$(grep -F "$source_name" "$sum_file" | head -n1)

        if [[ -z "$match" ]]; then
            match=$(grep -F "$(basename "$source_name")" "$sum_file" | head -n1)
        fi

        if [[ -z "$match" && "$source_name" != "$(basename "$file")" ]]; then
            match=$(grep -F "$(basename "$file")" "$sum_file" | head -n1)
        fi

        if [[ -z "$match" ]]; then
            match=$(awk 'NF==1 {print $1}' "$sum_file" | head -n1)
        fi

        rm -f "$sum_file"

        if [[ -z "$match" ]]; then
            echo "${red}Checksum entry not found for $source_name.${rst}"
            return 1
        fi

        if [[ "$match" == *" = "* ]]; then
            expected_sum=$(echo "$match" | awk -F ' = ' '{print $2}')
        else
            expected_sum=$(echo "$match" | awk '{print $1}')
        fi
    else
        expected_sum="$input"
    fi

    local cmd=""
    case ${#expected_sum} in
        64) cmd="sha256sum" ;;
        128) cmd="sha512sum" ;;
        *) echo "${ylw}Unknown hash length (${#expected_sum}). Skipping.${rst}"; return 0 ;;
    esac

    if echo "$expected_sum  $file" | $cmd --check --status; then
        echo "${grn}Checksum verified ($cmd).${rst}"
        return 0
    fi

    echo "${red}Checksum mismatch!${rst}"
    return 1
}

create_template() {
    local vmid="$1"
    local name="$2"
    local image="$3"
    local url="$4"
    local csum="${5:-}"
    local source_name
    local max_attempts=3
    local attempt=1
    local success=false

    source_name=$(basename "$url")

    if ! manage_existing "$vmid"; then
        return 0
    fi

    if ! webtest; then
        echo "${red}CRITICAL${rst}: DNS resolution or internet failure."
        return 1
    fi

    mkdir -p "$vm_image"
    cd "$vm_image" || return 1

    while (( attempt <= max_attempts )); do
        echo "Attempt $attempt of $max_attempts: Downloading $image..."
        if wget -q --show-progress "$url" -O "$image"; then
            if verify_checksum "$image" "$csum" "$source_name"; then
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
            xz -d "$image"
            image="${image%.xz}"
        elif [[ "$image" == *.gz ]]; then
            gunzip "$image"
            image="${image%.gz}"
        fi
        if ! qm set "$vmid" --scsi0 "${storage}:0,import-from=$(pwd)/$image,discard=on"; then
            echo "${red}Failed to import disk even after extraction.${rst} Cleanup..."
            rm -f "$image"
            qm destroy "$vmid" --purge >/dev/null 2>&1 || true
            return 1
        fi
    fi

    qm set "$vmid" --net0 virtio,bridge=vmbr0
    qm set "$vmid" --serial0 "$DEFAULT_SERIAL" --vga "$DEFAULT_VGA"
    qm set "$vmid" --memory 1024 --cores 2 --cpu x86-64-v2-AES
    qm set "$vmid" --boot order=scsi0 --scsihw virtio-scsi-single
    qm set "$vmid" --agent enabled=1,fstrim_cloned_disks=1
    qm set "$vmid" --ide2 "${storage}:cloudinit"
    qm set "$vmid" --ipconfig0 "ip6=auto,ip=dhcp"
    qm set "$vmid" --sshkeys "$ssh_keyfile"
    qm set "$vmid" --ciuser "$username"
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
            if ! resolve_distro "${params[4]}"; then
                echo "${red}Failed to resolve latest image for $distro_name.${rst}"
                return 1
            fi
            if ! confirm_template "$distro_name" "${params[1]}" "${params[2]}" "${params[3]}" "$RESOLVED_URL"; then
                return 0
            fi
            create_template "${params[1]}" "${params[2]}" "${params[3]}" "$RESOLVED_URL" "$RESOLVED_SUM"
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
