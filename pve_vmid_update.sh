#!/bin/bash

fnc_bad_input() { echo "Bad input. --exiting--"; exit; }

# check first variable. If present, assign to {var_vmid_old}, else request user input
case ${1} in
    (''|*[!0-9]*)
        echo "Enter the VMID to change: "
        read -r var_vmid_old
        ;;
    (*[0-9]*)
        var_vmid_old="${1}"
        ;;
esac

# verify var_vmid_old is a number, else display var contents and exit.
case ${var_vmid_old} in
    (''|*[!0-9]*)
        fnc_bad_input
        ;;
    (*)
        echo "Old VMID -> ${var_vmid_old}"
        ;;
esac

# check second variable. If present, assign to {var_vmid_new}, else request user input
case ${2} in
    (''|*[!0-9]*)
        echo -e "\nEnter the new VMID: "
        read -r var_vmid_new
        ;;
    (*[0-9]*)
        var_vmid_new="${2}"
        ;;
esac

# verify var_vmid_new is a number, else display var contents and exit.
case ${var_vmid_new} in
    (''|*[!0-9]*)
        fnc_bad_input
        ;;
    (*)
        echo "New VMID -> ${var_vmid_new}"
        ;;
esac
echo

# check if the old VMID is in the Volume Group
var_vg_name="$(lvs --noheadings -o lv_name,vg_name | grep "${var_vmid_old}" | awk -F ' ' '{print $2}' | uniq -d)"

# if the old VMID is not in the Volume Group then exit the script, else continue
case "${var_vg_name}" in
    ("")
        echo "VMID(old) \"${var_vmid_old}\" not in Volume Group. --exiting--"
        exit
        ;;
    (*)
        echo "Volume Group -> ${var_vg_name}"
        ;;
esac

# rename all the disks from the old VMID to the new VMID
for i in $(lvs -a | grep "${var_vg_name}" | awk '{print $1}' | grep "${var_vmid_old}");
    do lvrename "${var_vg_name}"/vm-"${var_vmid_old}"-disk-"$(echo "${i}" | awk '{print substr($0,length,1)}')" vm-"${var_vmid_new}"-disk-"$(echo "${i}" | awk '{print substr($0,length,1)}')";
done;

# create a backup of the old VMID.conf
cp /etc/pve/qemu-server/"${var_vmid_old}.conf" /etc/pve/qemu-server/"${var_vmid_new}.conf.$(date +%Y%m%d-%H%M%S)";

# replace the old VMID with the new VMID in the old VMID.conf
sed -i "s/${var_vmid_old}/${var_vmid_new}/g" /etc/pve/qemu-server/"${var_vmid_old}".conf;

# rename the old VMID.conf to the new VMID.conf
mv /etc/pve/qemu-server/"${var_vmid_old}".conf /etc/pve/qemu-server/"${var_vmid_new}".conf;

echo "VMID update from \"${var_vmid_old}\" to \"${var_vmid_new}\" complete!"