#!/usr/bin/env bash
# =============================================================================
# HAOS (Home Assistant OS) Proxmox Installer
# Tested on Proxmox VE 8.x
# =============================================================================

set -euo pipefail

FORCE=0

# =============================================================================
# LOGGING & COLOR UTILITIES
# =============================================================================

_check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

_tput_safe() { _check_cmd tput && tput "$@" 2>/dev/null || true; }

_color_setup() {
    if [[ -n ${CSM_NO_COLOR:-} || ! -t 1 ]]; then
        red="" grn="" ylw="" blu="" mgn="" cyn=""
        wht="" blk="" bld="" uln="" rst=""
    else
        red=$(_tput_safe setaf 1)
        grn=$(_tput_safe setaf 2)
        ylw=$(_tput_safe setaf 3)
        blu=$(_tput_safe setaf 4)
        mgn=$(_tput_safe setaf 5)
        cyn=$(_tput_safe setaf 6)
        wht=$(_tput_safe setaf 7)
        blk=$(_tput_safe setaf 0)
        bld=$(_tput_safe bold)
        uln=$(_tput_safe smul)
        rst=$(_tput_safe sgr0)
    fi
}

_log() {
    local level="${1:-INFO}" message="${2:-}"
    local color
    local prefix=""

    if [[ "${dry_run:-0}" == "1" ]]; then prefix="[DRY-RUN] "; fi

    case "$level" in
        EXIT|FAIL)  color="${red}" ;;
        INFO)       color="${cyn}" ;;
        PASS)       color="${grn}" ;;
        STEP)       color="${mgn}"; if [[ "${csm_debug:-0}" == "0" ]]; then return 0; fi ;;
        WARN)       color="${ylw}" ;;
        *)          color="${ylw}"; level="WARN"
                    message="[Unknown log type: '${level}'] $message"
                    ;;
    esac
    printf " %s%s%-4s >> %s%s%s %s%s<<%s\n" \
        "${color}" "${bld}" "${level}" "${prefix}" "${rst}" "${message}" "${color}" "${bld}" "${rst}" >&2
    if [[ "$level" == "EXIT" ]]; then exit 1; fi
}

_die() { _log FAIL "$1"; exit 1; }

# =============================================================================
# HELPERS
# =============================================================================

_confirm_yes() {
    local prompt reply
    prompt="${1:-Are you sure?}"
    [[ "${forced_mode:-0}" == "1" ]] && { _log INFO "${prompt} ${suffix} [auto-yes]"; return 0; }
    read -r -p "$(printf " %s%s?%s    >> %s [Y/n]: " "${ylw}" "${bld}" "${rst}" "${prompt}")" reply
    case "${reply,,}" in
        y|yes|"") return 0 ;;
        *)        return 1 ;;
    esac
}

_confirm_no() {
    local prompt reply
    prompt="${1:-Are you sure?}"
    [[ "${forced_mode:-0}" == "1" ]] && { _log INFO "${prompt} ${suffix} [auto-no]"; return 1; }
    read -r -p "$(printf " %s%s?%s    >> %s [y/N]: " "${ylw}" "${bld}" "${rst}" "${prompt}")" reply
    case "${reply,,}" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

_prompt() {
    local varname="$1"
    local prompt="$2"
    local default="${3:-}"
    local display_default=""
    local value=""
    [[ -n "$default" ]] && display_default=" (default: ${default})"
    if ! read -r -p "$(printf " %s%s?%s    >> %s%s: " "${cyn}" "${bld}" "${rst}" "${prompt}" "${display_default}")" value; then
        _die "Input cancelled or stdin closed while reading: ${prompt}"
    fi
    [[ -z "$value" && -n "$default" ]] && value="$default"
    printf -v "$varname" '%s' "$value"
}

_section() {
    printf "\n%s%s─── %s %s%s\n" "${mgn}" "${bld}" "$1" "$(printf '─%.0s' {1..40})" "${rst}"
}

_banner() {
    printf "\n%s%s" "${cyn}" "${bld}"
    printf "╔══════════════════════════════════════════════════════╗\n"
    printf "║     Home Assistant OS - Proxmox Installer            ║\n"
    printf "║     Installs HAOS via qcow2 image into a new VM      ║\n"
    printf "╚══════════════════════════════════════════════════════╝\n"
    printf "%s\n" "${rst}"
}

_ensure_cmd() {
    local cmd="$1" pkg="${2:-$1}"
    _check_cmd "$cmd" && return 0
    _log WARN "${cmd} not found — installing ${pkg}..."
    apt-get install -y "$pkg" -qq || _die "Failed to install ${pkg}."
}

_get_vm_ipv4() {
    local vmid="$1"
    qm agent "$vmid" network-get-interfaces 2>/dev/null \
    | grep -oE '"ip-address"[[:space:]]*:[[:space:]]*"([0-9]{1,3}\.){3}[0-9]{1,3}"' \
    | sed -E 's/.*"([0-9]{1,3}(\.[0-9]{1,3}){3})"/\1/' \
    | grep -v '^127\.' \
    | head -n 1
}

_get_vm_ipv6() {
    local vmid="$1"
    qm agent "$vmid" network-get-interfaces 2>/dev/null \
    | grep -oE '"ip-address"[[:space:]]*:[[:space:]]*"([0-9a-fA-F:]+)"' \
    | sed -E 's/.*"([0-9a-fA-F:]+)"/\1/' \
    | grep ':' \
    | grep -vi '^::1$' \
    | grep -vi '^fe80:' \
    | head -n 1
}

_valid_mac() {
    [[ "$1" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]
}

# =============================================================================
# STEPS
# =============================================================================

step_preflight() {
    _section "Step 1: Preflight Checks"
    [[ $EUID -ne 0 ]] && _die "This script must be run as root on the Proxmox host."
    for cmd_pkg in "wget wget" "curl curl" "qm pve-manager" "pvesh pve-manager"; do
        _ensure_cmd $cmd_pkg
    done
    _check_cmd xz || { _log WARN "xz-utils not found — installing..."; apt-get update -qq && apt-get install -y xz-utils -qq; }
    _log PASS "All dependencies satisfied."
}

step_collect_input() {
    _section "Step 2: Configuration"

    # VM ID — must be a positive integer and not already in use
    while true; do
        _prompt VMID "VM ID for the HAOS VM (e.g. 100)" ""
        if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
            _log WARN "VM ID must be a positive integer."
            continue
        fi
        if qm status "$VMID" &>/dev/null 2>&1; then
            _log WARN "VM ID ${VMID} already exists. Choose another."
            continue
        fi
        break
    done
    _log PASS "VM ID: ${VMID}"

    _prompt VMNAME "VM name" "HomeAssistant"
    _log PASS "VM name: ${VMNAME}"

    # Storage — list available pools, validate name, then check free space
    _log INFO "Available storage pools:"
    pvesm status | awk 'NR>1 {printf "        %-20s type=%-10s avail=%s\n", $1, $2, $5}' >&2

    local DEFAULT_STORAGE=""
    if pvesm status | awk 'NR>1 {print $1}' | grep -qx "local-lvm"; then
        DEFAULT_STORAGE="local-lvm"
    elif pvesm status | awk 'NR>1 {print $1}' | grep -qx "local-zfs"; then
        DEFAULT_STORAGE="local-zfs"
    fi

    while true; do
        _prompt STORAGE "Storage name" "$DEFAULT_STORAGE"
        if ! pvesm status | awk 'NR>1 {print $1}' | grep -qx "$STORAGE"; then
            _log WARN "Storage '${STORAGE}' not found. Check the list above."
            continue
        fi
        # Check free space — pvesm avail column is in bytes; require >= 12 GB
        local avail_kib min_kib avail_gib
        avail_kib=$(pvesm status | awk -v s="$STORAGE" '$1==s {print $5}')
        min_kib=$(( 12 * 1024 * 1024 ))
        if [[ -n "$avail_kib" && "$avail_kib" =~ ^[0-9]+$ && "$avail_kib" -lt "$min_kib" ]]; then
            avail_gib=$(( avail_kib / 1024 / 1024 ))
            _log WARN "Storage '${STORAGE}' only has ~${avail_gib} GiB free (12 GiB recommended)."
            if ! _confirm_yes "Continue anyway?"; then
                continue
            fi
        fi
        break
    done
    _log PASS "Storage: ${STORAGE}"

    # RAM — must be an integer, warn if under 2048
    while true; do
        _prompt RAM "RAM in MB" "4096"
        if ! [[ "$RAM" =~ ^[0-9]+$ ]]; then
            _log WARN "RAM must be a positive integer."
            continue
        fi
        if [[ "$RAM" -lt 2048 ]]; then
            _log WARN "Less than 2048 MB RAM may cause instability."
            if ! _confirm_yes "Continue anyway?"; then
                continue
            fi
        fi
        break
    done
    _log PASS "RAM: ${RAM} MB"

    # CPU cores — must be a positive integer
    while true; do
        _prompt CORES "CPU cores" "2"
        if [[ "$CORES" =~ ^[0-9]+$ && "$CORES" -ge 1 ]]; then
            break
        fi
        _log WARN "Cores must be a positive integer."
    done
    _log PASS "Cores: ${CORES}"

    # MAC address — optional; leave blank to let Proxmox auto-generate one
    while true; do
        _prompt MACADDR "MAC address for the VM NIC (blank = auto-generate)" ""
        if [[ -z "$MACADDR" ]]; then
            _log PASS "No MAC provided — Proxmox will auto-generate one."
            break
        fi
        if _valid_mac "$MACADDR"; then
            MACADDR="${MACADDR,,}"
            _log PASS "Requested MAC address: ${MACADDR}"
            break
        fi
        _log WARN "MAC address must be in the form 52:54:00:12:34:56."
    done

    # Network bridge — read from Proxmox network config, not raw ip link output
    _log INFO "Available network bridges from Proxmox config:"
    local available_bridges
    available_bridges=$(
        awk '/^auto[[:space:]]+vmbr[[:alnum:]:._-]*/ {
            for (i = 2; i <= NF; i++) print $i
        }
        /^iface[[:space:]]+vmbr[[:alnum:]:._-]+[[:space:]]+inet/ {
            print $2
        }' /etc/network/interfaces 2>/dev/null | sort -u
    )
    [[ -n "$available_bridges" ]] || _die "No Linux bridges were found in /etc/network/interfaces."
    printf '%s\n' "$available_bridges" | awk '{print "       ", $1}' >&2
    while true; do
        _prompt BRIDGE "Network bridge" "vmbr0"
        if printf '%s\n' "$available_bridges" | grep -qx "$BRIDGE"; then
            break
        fi
        _log WARN "Bridge '${BRIDGE}' not found in Proxmox network config. Available: $(printf '%s ' $available_bridges)"
    done
    _log PASS "Bridge: ${BRIDGE}"

    # VLAN tag — optional, must be 1–4094 if provided
    while true; do
        _prompt VLAN_TAG "VLAN tag (leave blank for none / untagged)" ""
        if [[ -z "$VLAN_TAG" ]]; then
            _log INFO "No VLAN tag — adapter will be untagged."
            break
        fi
        if [[ "$VLAN_TAG" =~ ^[0-9]+$ && "$VLAN_TAG" -ge 1 && "$VLAN_TAG" -le 4094 ]]; then
            _log PASS "VLAN tag: ${VLAN_TAG}"
            break
        fi
        _log WARN "VLAN tag must be an integer between 1 and 4094."
    done

    # _prompt HAOS_IP "Desired ${VMNAME} IP / DHCP reservation target (informational only)" "192.168.1.X"
    # _log PASS "HAOS IP noted: ${HAOS_IP}"
}

step_summary() {
    _section "Step 3: Summary"
    local vlan_display="${VLAN_TAG:-none (untagged)}"
    printf "\n"
    printf "   %-12s %s\n" "VM ID:"    "${VMID}"
    printf "   %-12s %s\n" "VM Name:"  "${VMNAME}"
    printf "   %-12s %s\n" "Storage:"  "${STORAGE}"
    printf "   %-12s %s\n" "RAM:"      "${RAM} MB"
    printf "   %-12s %s\n" "Cores:"    "${CORES}"
    printf "   %-12s %s\n" "MAC:"      "${MACADDR:-auto}"
    printf "   %-12s %s\n" "Bridge:"   "${BRIDGE}"
    printf "   %-12s %s\n" "VLAN:"     "${vlan_display}"
    printf "\n"
    _confirm_yes "Proceed with the above settings?" || { _log WARN "Aborted by user."; exit 0; }
}

step_download() {
    _section "Step 4: Download Latest HAOS Image"
    _log INFO "Querying GitHub API for the latest HAOS release..."
    local release_json
    release_json=$(curl -sf https://api.github.com/repos/home-assistant/operating-system/releases/latest) \
        || _die "Failed to reach GitHub API. Check your network connection."

    DOWNLOAD_URL=$(printf '%s' "$release_json" \
        | grep -oP '"browser_download_url":\s*"\Khttps://github[^"]*haos_ova-[^"]*\.qcow2\.xz(?=")' \
        | head -1)
    [[ -n "$DOWNLOAD_URL" ]] || _die "Could not find a qcow2.xz URL in the latest release."

    HAOS_VERSION=$(printf '%s' "$release_json" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
    _log INFO "Latest HAOS version : ${HAOS_VERSION}"
    _log INFO "Download URL        : ${DOWNLOAD_URL}"
    _confirm_yes "Download HAOS ${HAOS_VERSION}?" || { _log WARN "Aborted by user."; exit 0; }
    _log INFO "Downloading to ${TMPXZ}..."
    wget --progress=bar:force -O "$TMPXZ" "$DOWNLOAD_URL" 2>&1 || _die "Download failed."
    _log PASS "Download complete."
}

step_extract() {
    _section "Step 5: Extract Image"
    _confirm_yes "Extract ${TMPXZ}?" || { _log WARN "Aborted by user."; exit 0; }
    _log INFO "Extracting image..."
    unxz -v "$TMPXZ" || _die "Extraction failed."
    [[ -f "$TMPQCOW2" ]] || _die "Expected ${TMPQCOW2} after extraction but file not found."
    _log PASS "Extraction complete: ${TMPQCOW2}"
}

step_create_vm() {
    _section "Step 6: Create VM"
    _confirm_yes "Create VM ${VMID} (${VMNAME})?" || { _log WARN "Aborted by user."; exit 0; }

    local net0="virtio,bridge=${BRIDGE}"
    [[ -n "${MACADDR:-}" ]] && net0="virtio=${MACADDR},bridge=${BRIDGE}"
    [[ -n "${VLAN_TAG:-}" ]] && net0="${net0},tag=${VLAN_TAG}"

    _log INFO "Creating VM skeleton..."
    qm create "$VMID" \
        --name      "${VMNAME}" \
        --memory    "${RAM}" \
        --cores     "${CORES}" \
        --cpu       host \
        --net0      "${net0}" \
        --ostype    l26 \
        --bios      ovmf \
        --machine   q35 \
        --efidisk0  "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0" \
        --scsihw    virtio-scsi-pci \
        --onboot    1 \
        --agent     enabled=1 \
        || _die "VM creation failed."
    ACTUAL_MAC=$(qm config "$VMID" | awk -F'[=,]' '/^net0:/ {print $2; exit}')
    [[ -n "${ACTUAL_MAC:-}" ]] || _log WARN "Could not read back the assigned MAC from qm config."
    _log PASS "VM ${VMID} created."
    [[ -n "${ACTUAL_MAC:-}" ]] && _log PASS "Effective MAC address: ${ACTUAL_MAC}"
}

step_import_disk() {
    _section "Step 7: Import Disk"
    _confirm_yes "Import HAOS disk into storage '${STORAGE}'?" || { _log WARN "Aborted by user."; exit 0; }
    _log INFO "Importing disk (this may take a moment)..."
    qm importdisk "$VMID" "$TMPQCOW2" "$STORAGE" || _die "Disk import failed."
    _log PASS "Disk imported."
}

step_attach_disk() {
    _section "Step 8: Attach Disk & Set Boot Order"
    _confirm_yes "Attach imported disk and set boot order?" || { _log WARN "Aborted by user."; exit 0; }

    local attached=0
    for slot in 1 0; do
        local disk_id="${STORAGE}:vm-${VMID}-disk-${slot}"
        if qm set "$VMID" --scsi0 "${disk_id},discard=on" 2>/dev/null; then
            _log PASS "Disk attached as scsi0 (${disk_id})."
            attached=1
            break
        fi
    done
    if [[ "$attached" -eq 0 ]]; then
        _log WARN "Could not auto-attach disk. Attach the 'Unused Disk' manually in the Proxmox UI."
    fi

    qm set "$VMID" --boot order=scsi0 \
        && _log PASS "Boot order set to scsi0." \
        || _log WARN "Could not set boot order automatically — set it manually in VM Options."
}

step_cleanup() {
    _section "Step 9: Cleanup"
    _confirm_yes "Remove temporary file ${TMPQCOW2}?" || { _log WARN "Aborted by user."; exit 0; }
    rm -f "$TMPQCOW2"
    _log PASS "Temp file removed."
}

step_start_vm() {
    _section "Step 10: Start VM"
    if _confirm_no "Start VM ${VMID} now?"; then
        qm start "$VMID" || _die "Failed to start VM. Check the Proxmox UI for details."
        VM_STARTED=1
        VM_IPV4=""
        VM_IPV6=""
        if [[ "${VM_STARTED:-0}" == "1" ]]; then
            _log INFO "Waiting for guest agent to report IP addresses..."
            for _ in {1..30}; do
                [[ -z "$VM_IPV4" ]] && VM_IPV4="$(_get_vm_ipv4 "$VMID" || true)"
                [[ -z "$VM_IPV6" ]] && VM_IPV6="$(_get_vm_ipv6 "$VMID" || true)"
                [[ -n "$VM_IPV4" || -n "$VM_IPV6" ]] && break
                sleep 5
            done
        fi
    else
        VM_STARTED=0
        _log INFO "VM ${VMID} was created but not started."
    fi
}

step_done() {
    printf "\n%s%s" "${grn}" "${bld}"
    printf "╔══════════════════════════════════════════════════════╗\n"
    printf "║           Installation Complete!                     ║\n"
    printf "╚══════════════════════════════════════════════════════╝\n"
    printf "%s\n" "${rst}"
    printf "  Monitor boot progress: Proxmox UI → VM %s → Console\n" "${VMID}"
    printf "  Use the below MAC Address for a DHCP reservation on your router if you want a static IP.\n"
    printf "    VM MAC: %s%s%s\n\n" "${cyn}" "${ACTUAL_MAC:-unknown}" "${rst}"
    if [[ "${VM_STARTED:-0}" == "1" ]]; then
        printf "  %s is booting. First boot may take %s3–5 minutes%s.\n\n" "$VMNAME" "${bld}" "${rst}"
        printf "  Open your browser and navigate to:\n"
        printf "  %s  VM IPv4%s http://%s:8123%s\n" "${cyn}" "${bld}" "${VM_IPV4}" "${rst}"
        printf "  %s  VM IPv6%s http://%s:8123%s\n\n" "${cyn}" "${bld}" "${VM_IPV6}" "${rst}"
    else
        printf "  %s is not started yet — start it from Proxmox when ready.\n\n" "$VMNAME"
        printf "  When it is running, get the IP from the Proxmox Console, or with this command:\n"
        printf "  %s%s qm agent \"%s\" network-get-interfaces%s\n\n" "${cyn}" "${bld}" "${VMID}" "${rst}"
    fi
    printf "  %sNote:%s If the disk was not attached automatically,\n" "${ylw}" "${rst}"
    printf "  go to VM %s → Hardware → double-click 'Unused Disk' → Add.\n" "${VMID}"
    printf "  Then: VM Options → Boot Order → enable scsi0 first.\n\n"
}

main() {
    _color_setup

    while [[ $# -gt 0 ]]; do
        case "${1,,}" in
            -y|--force) FORCE=1; shift ;;
            *)          _die "Unknown argument: $1" ;;
        esac
    done

    readonly TMPXZ="/tmp/HAOS.qcow2.xz"
    readonly TMPQCOW2="/tmp/HAOS.qcow2"

    VMID="" VMNAME="" STORAGE="" RAM="" CORES=""
    MACADDR="" ACTUAL_MAC="" BRIDGE="" VLAN_TAG=""
    VM_IPV4="" VM_IPV6=""
    VM_STARTED=0 DOWNLOAD_URL="" HAOS_VERSION=""

    _banner
    step_preflight
    step_collect_input
    step_summary
    step_download
    step_extract
    step_create_vm
    step_import_disk
    step_attach_disk
    step_cleanup
    step_start_vm
    step_done
}

main "$@"
