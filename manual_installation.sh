#!/bin/bash

# Installation based on https://wiki.archlinux.org/title/Installation_guide

set -e

# 1. Pre-installation
# Download Arch Linux ISO
download_and_verify_iso() {
    echo "****************************************"
    echo "*** 1.1 Aquire an installation image ***"
    echo "****************************************"
    curl -s -o arch_checksums.html https://archlinux.org/download/#checksums
    ARCH_RELEASE=$(cat arch_checksums.html | grep -oP 'Current Release:.*?\K[0-9.]+')
    ISO_CHECKSUM=$(cat arch_checksums.html | grep -oP 'SHA256:.*?\K([0-9a-fA-F]{64})')
    ISO_FILENAME="archlinux-${ARCH_RELEASE}-x86_64.iso"
    ISO_DL_PATH="https://ftp.lysator.liu.se/pub/archlinux/iso/${ARCH_RELEASE}/${ISO_FILENAME}"
    rm arch_checksums.html
    echo -e "Downloading '${ISO_FILENAME}'...\n"

    [ ! -f "$ISO_FILENAME" ] && curl -o "$ISO_FILENAME" "$ISO_DL_PATH"


    echo ""
    echo "****************************"
    echo "*** 1.2 Verify signature ***"
    echo "****************************"
    DOWNLOADED_ISO_CHECKSUM=$(sha256sum "${ISO_FILENAME}" | awk '{print $1}' )
    [ "$ISO_CHECKSUM" != "$DOWNLOADED_ISO_CHECKSUM" ] && { echo "Checksum error on downloaded ISO."; exit 1; }
    echo "Signature of '${ISO_FILENAME}' is OK..."
}

write_iso() {
    echo ""
    echo "******************************************"
    echo "*** 1.3 Prepare an installation medium ***"
    echo "******************************************"
    echo "Partitions:"
    sudo parted -l | grep "Disk /"
    echo ""
    echo "Run this command with the correct value for 'of='"
    echo ""
    echo "sudo dd if=archlinux.iso of=/dev/sdX bs=4M status=progress && sync"
}

main() {
    echo "**********************************************"
    echo "* Arch Linux Installation - Pre-installation *"
    echo "**********************************************"
    echo ""
    download_and_verify_iso
    write_iso
    exit
}

main




efi=false
loadkeys sv-latin1
ls /sys/firmware/efi/efivars && efi=true
echo "efi: $efi"
ping archlinux.org -c3 || { echo "Cannot connect to Internet."; exit 1; }
timedatectl set-ntp true
# parition disk
# format disks
# mkswap?