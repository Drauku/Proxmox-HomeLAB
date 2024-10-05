#!/bin/bash

# original script from https://www.apalrd.net/posts/2023/pve_cloud/

## debug flag on/off
debug(){ [ $debug -eq 1 ] && echo "DEBUG: $*" }

#Path to your ssh authorized_keys file
# export ssh_keyfile=/root/id_rsa-homelan.pub
#Alternatively, use /etc/pve/priv/authorized_keys if you are already authorized on the Proxmox system
export ssh_keyfile="/etc/pve/priv/authorized_keys"

#Username to create on VM template
export username="${1:-drauku}"

#Name of your storage
storage=$(pvesm status | awk '/local-/{print $1}')
vm_confs="/etc/pve/qemu-server"
vm_image="/var/lib/vz/template/iso"

#Check for internet connectivity:
extract_domain(){
    local s="$1"
    s="${s/#*:\/\/}" # remove protocol
    echo -n "${s/%+(:*|\/*)}" # remove path
}

webtest(){
    debug=$2
    debug "\$1 is '$1'"
    if [ -z "$1" ]; then test="cloudflare.com"; else test="$1"; fi
    debug "\$test is '$test'"
    test_url="$(extract_domain $test)"
    debug "\$test_url is '$test_url'"
    if curl -sf -o /dev/null https://$test_url; then
        # echo "connection with $test_url successful"
        return 0
    else
        # echo "connection with $test_url > failed <"
        return 1
    fi
}

#Create template
#args:
# vm_id
# vm_name
# file name in the current directory
create_template(){
    #Check if the template already exists
    if [[ -f "$vm_confs/$1.conf" ]]
    then echo "Template $vm_confs/$1 already exists, not creating."; return
    else
        if [ $(webtest "$4") > 0 ]
        then
            echo "No internet connection detected. Unable to download image, exiting."
            return
        fi
        #Download the template image
        # used to specify "prefix" directory for download path
        # wget "$4" -P $vm_image
        # no specified download path because image is removed after
        if wget "$4"
        then
            #Print all of the configuration
            echo "Creating template $2 ($1)"
            #Create new VM
            #Feel free to change any of these to your liking
            qm create $1 --name $2 --ostype l26
            #Set networking to default bridge
            qm set $1 --net0 virtio,bridge=vmbr0
            #Set display to serial
            qm set $1 --serial0 socket --vga serial0
            #Set memory, cpu, type defaults
            #If you are in a cluster, you might need to change cpu type
            qm set $1 --memory 1024 --cores 2 --cpu x86-64-v2-AES
            #Set boot device to new file
            qm set $1 --scsi0 ${storage}:0,import-from="$(pwd)/$3",discard=on
            #Set scsi hardware as default boot disk using virtio scsi single
            qm set $1 --boot order=scsi0 --scsihw virtio-scsi-single
            #Enable Qemu guest agent in case the guest has it available
            qm set $1 --agent enabled=1,fstrim_cloned_disks=1
            #Add cloud-init device
            qm set $1 --ide2 ${storage}:cloudinit
            #Set CI ip config
            #IP6 = auto means SLAAC (a reliable default with no bad effects on non-IPv6 networks)
            #IP = DHCP means what it says, so leave that out entirely on non-IPv4 networks to avoid DHCP delays
            qm set $1 --ipconfig0 "ip6=auto,ip=dhcp"
            #Import the ssh keyfile
            qm set $1 --sshkeys ${ssh_keyfile}
            #If you want to do password-based auth instaed
            #Then use this option and comment out the line above
            #qm set $1 --cipassword password
            #Add the user
            qm set $1 --ciuser ${username}
            #Resize the disk to 8G, a reasonable minimum. You can expand it more later.
            #If the disk is already bigger than 8G, this will fail, and that is okay.
            qm disk resize $1 scsi0 8G
            #Make it a template
            qm template $1

            #Remove file when done
            rm $3
        else
            echo "Image download failed. Exiting."
            return
        fi
    fi
}

#The images that I've found premade
#Feel free to add your own

## Debian
##Buster (10)
# img_url="https://cloud.debian.org/images/cloud/buster/latest/debian-10-genericcloud-amd64.qcow2"
# create_template 910 "tmpl-debian-10" "debian-10-genericcloud-amd64.qcow2" $img_url
##Bullseye (11)
# img_url="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2"
# create_template 911 "tmpl-debian-11" "debian-11-genericcloud-amd64.qcow2" $img_url
#Bookworm (12)
img_url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
create_template 912 "tmpl-debian-12" "debian-12-genericcloud-amd64.qcow2" $img_url
##Trixie hasn't started pushing dailies yet, but it will be template 913
##Sid (Unstable)
# img_url="https://cloud.debian.org/images/cloud/sid/daily/latest/debian-sid-genericcloud-amd64-daily.qcow2"
# create_template 919 "tmpl-debian-sid" "debian-sid-genericcloud-amd64-daily.qcow2" $img_url

## Ubuntu
##20.04 (Focal Fossa)
# img_url="https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img"
# create_template 920 "tmpl-ubuntu-20-04" "ubuntu-20.04-server-cloudimg-amd64.img" $img_url
#22.04 (Jammy Jellyfish)
img_url="https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"
create_template 922 "tmpl-ubuntu-22-04" "ubuntu-22.04-server-cloudimg-amd64.img" $img_url
##23.04 (Lunar Lobster) - daily builds
# img_url="https://cloud-images.ubuntu.com/lunar/current/lunar-server-cloudimg-amd64.img"
# create_template 923 "tmpl-ubuntu-23-04-daily" "lunar-server-cloudimg-amd64.img" $img_url
##24.04 (Noble Numbat) - daily rlease build
img_url="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
create_template 924 "tmpl-ubuntu-24-04" "ubuntu-24.04-server-cloudimg-amd64.img" $img_url

## Fedora 37
##Image is compressed, so need to uncompress first
# img_url="https://download.fedoraproject.org/pub/fedora/linux/releases/37/Cloud/x86_64/images/Fedora-Cloud-Base-37-1.7.x86_64.raw.xz"
# xz -d -v Fedora-Cloud-Base-37-1.7.x86_64.raw.xz
# create_template 937 "tmpl-fedora-37" "Fedora-Cloud-Base-37-1.7.x86_64.raw" $img_url

## CentOS Stream
#Stream 8
# img_url="https://cloud.centos.org/centos/8-stream/x86_64/images/CentOS-Stream-GenericCloud-8-20220913.0.x86_64.qcow2"
# create_template 948 "tmpl-centos-8-stream" "CentOS-Stream-GenericCloud-8-20220913.0.x86_64.qcow2" $img_url
##Stream 9 (daily) - they don't have a 'latest' link?
# img_url="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-20230123.0.x86_64.qcow2"
# create_template 949 "tmpl-centos-9-stream-daily" "CentOS-Stream-GenericCloud-9-20230123.0.x86_64.qcow2" $img_url

## Rocky Linux
#RockyLinux 8

#RockyLinux 9
img_url="https://download.rockylinux.org/pub/rocky/9.2/images/x86_64/Rocky-9-GenericCloud-Base-9.2-20230513.0.x86_64.qcow2"
create_template 949 "tmpl-rocky-9" "Rocky-9-GenericCloud-Base-9.2-20230513.0.x86_64.qcow2" $img_url
