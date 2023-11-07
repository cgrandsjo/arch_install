#!/usr/bin/env bash


# Fakeroot
# US Mirrors
# Installing
# Formatting
# Many packages
# Grub BIOS Boot loader
# 1-setup
# Network setup
# Snapper
# Plymouth Boot Splash
# Done - Eject - Reboot - 4m24s
# Shutdown
# Remove CD Disk
# Start up
# Log in

###### MAIN ######
[[ "$(id -u)" != "0" ]] && echo "ERROR! This script must be run as the 'root' user." && exit 1
[[ ! -e /etc/arch-release ]] && echo "ERROR! This script must be run in Arch Linux." && exit 1
[[ -f /var/lib/pacman/db.lck ]] && echo "ERROR! Pacman is blocked. If not running, remove /var/lib/pacman/db.lck." && exit 1
(awk -F/ '$2 == "docker"' /proc/self/cgroup || [[ -f /.dockerenv ]]) && echo "ERROR! Docker container is not supported (at the moment)" && exit 1

# Enable network time synchronization
timedatectl set-ntp true

# Update the Arch Linux keyring (system's trusted keys)
pacman -S --noconfirm archlinux-keyring

# # Install necessary packages - pacman-contrib and terminus-font
# pacman -S --noconfirm --needed pacman-contrib terminus-font

# # Set the console font to Terminus 22 pixels high
# setfont ter-v22b

# Enable parallel package downloads in pacman configuration
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

# Install essential packages - reflector, rsync, and grub
pacman -S --noconfirm --needed reflector rsync grub

# Create a backup of the current mirrorlist configuration
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

# Generate a new mirrorlist using reflector with specific criteria
reflector --verbose --latest 5 --sort rate --save /etc/pacman.d/mirrorlist

# Synchronize the package databases
sudo pacman -Syy

# Create a directory for mounting a file system (e.g., /mnt)
mkdir -p /mnt

# Install necessary packages for disk management and filesystem support
pacman -S --noconfirm --needed gptfdisk btrfs-progs glibc

# Unmount all mounted filesystems recursively under /mnt
umount -A --recursive /mnt

# Disk preparation: Zero out the GPT data on the specified disk
sgdisk -Z "$DISK"

# Disk preparation: Create a new GPT disk with a 2048-sector alignment
sgdisk -a 2048 -o "$DISK"

# Create a BIOS Boot Partition (partition 1) with a size of 1M
# Set the partition type to ef02 (BIOS Boot) and change the name to 'BIOSBOOT'
sgdisk -n 1::+1M --typecode=1:ef02 --change-name=1:'BIOSBOOT' "$DISK"

# Create a UEFI Boot Partition (partition 2) with a size of 300M
# Set the partition type to ef00 (UEFI Boot) and change the name to 'EFIBOOT'
sgdisk -n 2::+300M --typecode=2:ef00 --change-name=2:'EFIBOOT' "$DISK"

# Create the Root Partition (partition 3) using the default start and the remaining space
# Set the partition type to 8300 (Linux filesystem) and change the name to 'ROOT'
sgdisk -n 3::-0 --typecode=3:8300 --change-name=3:'ROOT' "$DISK"

# Check if the system is in BIOS mode (not UEFI) and if so, set the first partition (BIOS Boot) to the 'boot' flag
if [[ ! -d "/sys/firmware/efi" ]]; then
    sgdisk -A 1:set:2 "$DISK"
fi

# Reread the partition table on "$DISK" to ensure it reflects recent changes
partprobe "$DISK"

if [[ "${DISK}" =~ "nvme" ]]; then
    partition2=${DISK}p2
    partition3=${DISK}p3
else
    partition2=${DISK}2
    partition3=${DISK}3
fi

createsubvolumes () {
    # Create Btrfs subvolumes for specific directory structures
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@var
    btrfs subvolume create /mnt/@tmp
    btrfs subvolume create /mnt/@.snapshots
}

mountallsubvol () {
    # Mount various Btrfs subvolumes on their respective directories
    mount -o ${MOUNT_OPTIONS},subvol=@home ${partition3} /mnt/home
    mount -o ${MOUNT_OPTIONS},subvol=@tmp ${partition3} /mnt/tmp
    mount -o ${MOUNT_OPTIONS},subvol=@var ${partition3} /mnt/var
    mount -o ${MOUNT_OPTIONS},subvol=@.snapshots ${partition3} /mnt/.snapshots
}

subvolumesetup () {
    # Create non-root Btrfs subvolumes
    createsubvolumes
    # Unmount the root to remount with the @ subvolume
    umount /mnt
    # Mount the @ subvolume with specific options
    mount -o ${MOUNT_OPTIONS},subvol=@ ${partition3} /mnt
    # Create directories for home, .snapshots, var, tmp
    mkdir -p /mnt/{home,var,tmp,.snapshots}
    # Mount the Btrfs subvolumes on their respective directories
    mountallsubvol
}

mkfs.vfat -F32 -n "EFIBOOT" ${partition2}
mkfs.btrfs -L ROOT ${partition3} -f
mount -t btrfs ${partition3} /mnt
subvolumesetup

# Create a directory for the EFI system partition
mkdir -p /mnt/boot/efi

# Mount the EFI system partition using its label 'EFIBOOT'
# The '-t vfat' option specifies the filesystem type as FAT (common for EFI partitions)
mount -t vfat -L EFIBOOT /mnt/boot/

# Check if '/mnt' is mounted; if not, it might indicate a problem and trigger a reboot
if ! grep -qs '/mnt' /proc/mounts; then
    echo "Drive is not mounted, cannot continue"
    echo "Rebooting in 3 Seconds ..." && sleep 1
    echo "Rebooting in 2 Seconds ..." && sleep 1
    echo "Rebooting in 1 Second ..." && sleep 1
    reboot now
fi

# Install essential packages on the target system using pacstrap
pacstrap /mnt base base-devel linux linux-firmware vim nano sudo archlinux-keyring wget libnewt --noconfirm --needed

# Add a keyserver configuration to the GnuPG configuration on the target system
echo "keyserver hkp://keyserver.ubuntu.com" >> /mnt/etc/pacman.d/gnupg/gpg.conf

# Copy the contents of ${SCRIPT_DIR} to a directory on the target system
cp -R ${SCRIPT_DIR} /mnt/root/ArchTitus

# Copy the system's mirrorlist configuration to the target system
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

# Generate an /etc/fstab file on the target system based on the existing disk labels
genfstab -L /mnt >> /mnt/etc/fstab

# Display the contents of the generated /etc/fstab for verification
echo "Generated /etc/fstab:"
cat /mnt/etc/fstab

# Check if the system is not using UEFI (EFI)
if [[ ! -d "/sys/firmware/efi" ]]; then
    # Install the GRUB bootloader for non-UEFI systems
    grub-install --boot-directory=/mnt/boot ${DISK}
else
    # If the system uses UEFI, install the efibootmgr package
    pacstrap /mnt efibootmgr --noconfirm --needed
fi

# Get the total system memory from /proc/meminfo
TOTAL_MEM=$(cat /proc/meminfo | grep -i 'memtotal' | grep -o '[[:digit:]]*')

# Check if the total memory is less than 8GB (8000000 KB)
if [[  $TOTAL_MEM -lt 8000000 ]]; then
    # Create a swap file on the actual system (not in RAM) to improve memory management
    # Create a directory for the swap file and apply NOCOW attribute for Btrfs compatibility
    mkdir -p /mnt/opt/swap
    chattr +C /mnt/opt/swap

    # Create a 2GB swap file in the directory using dd
    dd if=/dev/zero of=/mnt/opt/swap/swapfile bs=1M count=2048 status=progress

    # Set appropriate permissions and ownership for the swap file
    chmod 600 /mnt/opt/swap/swapfile
    chown root /mnt/opt/swap/swapfile

    # Configure the swap file using mkswap
    mkswap /mnt/opt/swap/swapfile

    # Enable the swap file
    swapon /mnt/opt/swap/swapfile

    # Add an entry to /etc/fstab to ensure that the swap file is used on boot
    # The entry specifies the swap file path and its configuration
    echo "/opt/swap/swapfile	none	swap	sw	0	0" >> /mnt/etc/fstab
fi

###### 1-setup.sh

# Install NetworkManager and dhclient packages without confirmation
pacman -S --noconfirm --needed networkmanager dhclient

# Enable and start the NetworkManager service using systemctl
systemctl enable --now NetworkManager

# Install essential packages - pacman-contrib and curl
pacman -S --noconfirm --needed pacman-contrib curl

# Install necessary packages for the installation process
pacman -S --noconfirm --needed reflector rsync grub arch-install-scripts git

# Create a backup of the current mirrorlist configuration
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak

# Count the number of processors (CPU cores) and store it in the 'nc' variable
nc=$(grep -c ^processor /proc/cpuinfo)

# Get the total system memory from /proc/meminfo
TOTAL_MEM=$(cat /proc/meminfo | grep -i 'memtotal' | grep -o '[[:digit:]]*')

# Check if the total memory is greater than 8GB (8000000 KB)
if [[  $TOTAL_MEM -gt 8000000 ]]; then
    # If the memory is greater than 8GB, adjust the makepkg.conf settings for better performance

    # Modify the MAKEFLAGS in /etc/makepkg.conf to use parallel jobs (based on the 'nc' variable)
    sed -i "s/#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j$nc\"/g" /etc/makepkg.conf

    # Modify the COMPRESSXZ in /etc/makepkg.conf to use multiple threads (based on the 'nc' variable)
    sed -i "s/COMPRESSXZ=(xz -c -z -)/COMPRESSXZ=(xz -c -T $nc -z -)/g" /etc/makepkg.conf
fi

# Uncomment the en_US.UTF-8 UTF-8 locale in locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen

# Generate locales based on the updated locale.gen file
locale-gen

# Set the system timezone to ${TIMEZONE}
timedatectl --no-ask-password set-timezone ${TIMEZONE}

# Enable automatic time synchronization using NTP (Network Time Protocol)
timedatectl --no-ask-password set-ntp 1

# Set system locale and LC_TIME to en_US.UTF-8
localectl --no-ask-password set-locale LANG="en_US.UTF-8" LC_TIME="en_US.UTF-8"

# Create a symbolic link from the selected timezone to /etc/localtime
ln -s /usr/share/zoneinfo/${TIMEZONE} /etc/localtime

# Set the system keymap to ${KEYMAP}
localectl --no-ask-password set-keymap ${KEYMAP}

# Grant sudo privileges without a password prompt
sed -i 's/^# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

# Enable parallel package downloads in pacman configuration
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

# Uncomment the [multilib] repository in pacman configuration
sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf

# Synchronize the package databases to include multilib
pacman -Sy --noconfirm --needed

# Use 'sed' to read lines from pacman-pkgs.txt until it encounters the specified pattern ('$INSTALL_TYPE')
# This is done to separate the package list based on the installation type
sed -n '/'$INSTALL_TYPE'/q;p' $HOME/ArchTitus/pkg-files/pacman-pkgs.txt |
while read line
do
    # Check if the line is the end marker for minimal installation
    if [[ ${line} == '--END OF MINIMAL INSTALL--' ]]; then
        # If the selected installation type is FULL, skip this line and continue to the next package
        continue
    fi

    # Display the package being installed
    echo "INSTALLING: ${line}"

    # Install the package using 'pacman' with the specified options
    sudo pacman -S --noconfirm --needed ${line}
done

# Determine the processor type by running 'lscpu' and store the output in the 'proc_type' variable
proc_type=$(lscpu)

# Check if the 'proc_type' variable contains the string "GenuineIntel" using grep
if grep -E "GenuineIntel" <<< ${proc_type}; then
    # If it's an Intel processor, install the Intel microcode updates
    echo "Installing Intel microcode"
    pacman -S --noconfirm --needed intel-ucode
    proc_ucode=intel-ucode.img
# Check if the 'proc_type' variable contains the string "AuthenticAMD" using grep
elif grep -E "AuthenticAMD" <<< ${proc_type}; then
    # If it's an AMD processor, install the AMD microcode updates
    echo "Installing AMD microcode"
    pacman -S --noconfirm --needed amd-ucode
    proc_ucode=amd-ucode.img
fi

# Determine the GPU type by running 'lspci' and store the output in the 'gpu_type' variable
gpu_type=$(lspci)

# Check if the 'gpu_type' variable contains "NVIDIA" or "GeForce" using grep
if grep -E "NVIDIA|GeForce" <<< ${gpu_type}; then
    # If it's an NVIDIA GPU, install the NVIDIA driver and configure it using nvidia-xconfig
    pacman -S --noconfirm --needed nvidia
    nvidia-xconfig
# Check if the 'lspci' output contains 'VGA' and the word "Radeon" or "AMD"
elif lspci | grep 'VGA' | grep -E "Radeon|AMD"; then
    # If it's an AMD GPU, install the xf86-video-amdgpu driver
    pacman -S --noconfirm --needed xf86-video-amdgpu
# Check if the 'gpu_type' variable contains "Integrated Graphics Controller" using grep
elif grep -E "Integrated Graphics Controller" <<< ${gpu_type}; then
    # If it's an integrated Intel GPU, install relevant Intel graphics drivers and libraries
    pacman -S --noconfirm --needed libva-intel-driver libvdpau-va-gl lib32-vulkan-intel vulkan-intel libva-intel-driver libva-utils lib32-mesa
# Check if the 'gpu_type' variable contains "Intel Corporation UHD" using grep
elif grep -E "Intel Corporation UHD" <<< ${gpu_type}; then
    # If it's an Intel UHD GPU, install relevant Intel graphics drivers and libraries
    pacman -S --needed --noconfirm libva-intel-driver libvdpau-va-gl lib32-vulkan-intel vulkan-intel libva-intel-driver libva-utils lib32-mesa
fi

# Check if the setup.conf file is not already sourced (run)
if ! source $HOME/ArchTitus/configs/setup.conf; then
    # Loop through user input until a valid username is provided
    while true
    do
        read -p "Please enter a username: " username
        # Validate the username using regex
        if [[ "${username,,}" =~ ^[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\$)$ ]]
        then
            break
        fi
        echo "Incorrect username."
    done

    # Convert the username to lowercase and save it to the setup.conf file
    echo "username=${username,,}" >> ${HOME}/ArchTitus/configs/setup.conf

    # Set the user's password
    read -p "Please enter a password: " password
    echo "password=${password,,}" >> ${HOME}/ArchTitus/configs/setup.conf

    # Loop through user input until a valid hostname is provided, with an option to force save
    while true
    do
        read -p "Please name your machine: " name_of_machine
        # Validate the hostname using regex
        if [[ "${name_of_machine,,}" =~ ^[a-z][a-z0-9_.-]{0,62}[a-z0-9]$ ]]
        then
            break
        fi
        # If validation fails, allow the user to force saving of the hostname
        read -p "Hostname doesn't seem correct. Do you still want to save it? (y/n) " force
        if [[ "${force,,}" = "y" ]]
        then
            break
        fi
    }

    # Save the lowercase hostname to the setup.conf file
    echo "NAME_OF_MACHINE=${name_of_machine,,}" >> ${HOME}/ArchTitus/configs/setup.conf
fi

# Check if the current user is 'root'
if [ $(whoami) = "root"  ]; then
    # Create a 'libvirt' group
    groupadd libvirt

    # Create a user, add them to the 'wheel' and 'libvirt' groups, and set their shell to /bin/bash
    useradd -m -G wheel,libvirt -s /bin/bash $USERNAME
    echo "$USERNAME created, home directory created, added to wheel and libvirt group, default shell set to /bin/bash"

    # Set the user's password using 'chpasswd'
    echo "$USERNAME:$PASSWORD" | chpasswd
    echo "$USERNAME password set"

    # Copy the 'ArchTitus' directory to the user's home directory and adjust ownership
    cp -R $HOME/ArchTitus /home/$USERNAME/
    chown -R $USERNAME: /home/$USERNAME/ArchTitus
    echo "ArchTitus copied to the home directory"

    # Set the system hostname to $NAME_OF_MACHINE
    echo $NAME_OF_MACHINE > /etc/hostname
else
    # If the current user is not 'root', they are already a user, and the script proceeds with AUR installs
    echo "You are already a user, proceed with AUR installs"
fi

# Check if the selected filesystem is 'luks'
if [[ ${FS} == "luks" ]]; then
    # Edit mkinitcpio.conf to include 'encrypt' before 'filesystems' in the 'hooks' section
    sed -i 's/filesystems/encrypt filesystems/g' /etc/mkinitcpio.conf

    # Regenerate the initramfs with 'mkinitcpio' using the 'linux' preset
    mkinitcpio -p linux
fi

### 2-user.sh

# Change to the user's home directory
cd ~

# Create a '.cache' directory in the user's home directory
mkdir "/home/$USERNAME/.cache"

# Create an empty 'zshhistory' file in the '.cache' directory
touch "/home/$USERNAME/.cache/zshhistory"

# Clone the 'zsh' repository from GitHub
git clone "https://github.com/ChrisTitusTech/zsh"

# Clone the 'powerlevel10k' repository from GitHub with depth=1
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ~/powerlevel10k

# Create a symbolic link to the '.zshrc' file in the 'zsh' repository
ln -s "~/zsh/.zshrc" ~/.zshrc

# Use 'sed' to read lines from ${DESKTOP_ENV}.txt until it encounters the specified pattern (${INSTALL_TYPE})
sed -n '/'$INSTALL_TYPE'/q;p' ~/ArchTitus/pkg-files/${DESKTOP_ENV}.txt |
while read line
do
    # Check if the line is the end marker for minimal installation
    if [[ ${line} == '--END OF MINIMAL INSTALL--' ]]
    then
        # If the selected installation type is FULL, skip this line and continue to the next package
        continue
    fi

    # Display the package being installed
    echo "INSTALLING: ${line}"

    # Install the package using 'pacman' with the specified options
    sudo pacman -S --noconfirm --needed ${line}
done

# Check if an AUR helper is specified (not equal to 'none')
if [[ ! $AUR_HELPER == none ]]; then
    # Change to the user's home directory
    cd ~

    # Clone the specified AUR helper repository from the AUR
    git clone "https://aur.archlinux.org/$AUR_HELPER.git"

    # Change to the AUR helper directory
    cd ~/$AUR_HELPER

    # Build and install the AUR helper package using 'makepkg'
    makepkg -si --noconfirm

    # Use 'sed' to read lines from aur-pkgs.txt until it encounters the specified pattern (${INSTALL_TYPE})
    sed -n '/'$INSTALL_TYPE'/q;p' ~/ArchTitus/pkg-files/aur-pkgs.txt |
    while read line
    do
        # Check if the line is the end marker for minimal installation
        if [[ ${line} == '--END OF MINIMAL INSTALL--' ]]; then
            # If the selected installation type is FULL, skip this line and continue to the next package
            continue
        fi

        # Display the package being installed from the AUR
        echo "INSTALLING: ${line}"

        # Install the AUR package using the specified AUR helper
        $AUR_HELPER -S --noconfirm --needed ${line}
    done
fi

# Add ~/.local/bin to the system's PATH environment variable
export PATH=$PATH:~/.local/bin

# Theming the desktop environment if the user chose FULL installation
if [[ $INSTALL_TYPE == "FULL" ]]; then
    if [[ $DESKTOP_ENV == "kde" ]]; then
        # Copy configuration files from the ArchTitus directory to the user's ~/.config directory
        cp -r ~/ArchTitus/configs/.config/* ~/.config/

        # Install 'konsave' using pip
        pip install konsave

        # Import the KDE theme configuration using 'konsave'
        konsave -i ~/ArchTitus/configs/kde.knsv
        sleep 1

        # Apply the imported KDE theme
        konsave -a kde
    fi
fi


# 3-post-setup.sh

# Check if the "/sys/firmware/efi" directory exists, which indicates UEFI firmware
if [[ -d "/sys/firmware/efi" ]]; then
    # Install the GRUB bootloader in UEFI mode, specifying the EFI directory and the target disk
    grub-install --efi-directory=/boot ${DISK}
fi

# Set kernel parameter for decrypting the drive if the filesystem is LUKS
if [[ "${FS}" == "luks" ]]; then
    # Modify the GRUB_CMDLINE_LINUX_DEFAULT to include the 'cryptdevice' parameter
    sed -i "s%GRUB_CMDLINE_LINUX_DEFAULT=\"%GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=${ENCRYPTED_PARTITION_UUID}:ROOT root=/dev/mapper/ROOT %g" /etc/default/grub
fi

# Set kernel parameter for adding the 'splash' screen
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*/& splash /' /etc/default/grub

echo -e "Installing CyberRe Grub theme..."

# Define the directory and theme name for the GRUB theme
THEME_DIR="/boot/grub/themes"
THEME_NAME=CyberRe

echo -e "Creating the theme directory..."

# Create the theme directory if it doesn't exist
mkdir -p "${THEME_DIR}/${THEME_NAME}"

echo -e "Copying the theme..."

# Copy the theme files from the ArchTitus directory to the theme directory
cd ${HOME}/ArchTitus
cp -a configs${THEME_DIR}/${THEME_NAME}/* ${THEME_DIR}/${THEME_NAME}

echo -e "Backing up Grub config..."

# Create a backup of the GRUB configuration
cp -an /etc/default/grub /etc/default/grub.bak

echo -e "Setting the theme as the default..."

# Check if 'GRUB_THEME' is already set in the GRUB configuration and remove it if it exists
grep "GRUB_THEME=" /etc/default/grub 2>&1 >/dev/null && sed -i '/GRUB_THEME=/d' /etc/default/grub

# Set the 'GRUB_THEME' parameter in the GRUB configuration to use the installed theme
echo "GRUB_THEME=\"${THEME_DIR}/${THEME_NAME}/theme.txt\"" >> /etc/default/grub

echo -e "Updating grub..."

# Update the GRUB configuration
grub-mkconfig -o /boot/grub/grub.cfg

echo -e "All set!"

# Check if the selected desktop environment is "kde"
if [[ ${DESKTOP_ENV} == "kde" ]]; then
    # Enable the SDDM (Simple Desktop Display Manager) service
    systemctl enable sddm.service

    # Check if the installation type is "FULL"
    if [[ ${INSTALL_TYPE} == "FULL" ]]; then
        # Add a theme configuration to the /etc/sddm.conf file
        echo [Theme] >> /etc/sddm.conf
        echo Current=Nordic >> /etc/sddm.conf
    fi

# Check if the selected desktop environment is "gnome"
elif [[ "${DESKTOP_ENV}" == "gnome" ]]; then
    # Enable the GDM (GNOME Display Manager) service
    systemctl enable gdm.service

# For other desktop environments (not "kde" or "gnome")
else
    # Check if the selected desktop environment is not "server"
    if [[ ! "${DESKTOP_ENV}" == "server"  ]]; then
        # Install LightDM and LightDM GTK Greeter, and enable the LightDM service
        sudo pacman -S --noconfirm --needed lightdm lightdm-gtk-greeter
        systemctl enable lightdm.service
    fi
fi

# Enable the CUPS (Common UNIX Printing System) service
systemctl enable cups.service
echo "  Cups enabled"

# Synchronize the system time with an NTP server using 'ntpd'
ntpd -qg

# Enable the NTP (Network Time Protocol) service
systemctl enable ntpd.service
echo "  NTP enabled"

# Disable and stop the 'dhcpcd' (DHCP client) service
systemctl disable dhcpcd.service
echo "  DHCP disabled"
systemctl stop dhcpcd.service
echo "  DHCP stopped"

# Enable the NetworkManager service
systemctl enable NetworkManager.service
echo "  NetworkManager enabled"

# Enable the Bluetooth service
systemctl enable bluetooth
echo "  Bluetooth enabled"

# Enable the Avahi service (used for zero-configuration networking)
systemctl enable avahi-daemon.service
echo "  Avahi enabled"

# If the filesystem is LUKS or Btrfs, create and configure Snapper
if [[ "${FS}" == "luks" || "${FS}" == "btrfs" ]]; then
    # Define the paths to the Snapper configuration files
    SNAPPER_CONF="$HOME/ArchTitus/configs/etc/snapper/configs/root"
    SNAPPER_CONF_D="$HOME/ArchTitus/configs/etc/conf.d/snapper"

    # Create the necessary directories and copy the Snapper configuration files to their locations
    mkdir -p /etc/snapper/configs/
    cp -rfv ${SNAPPER_CONF} /etc/snapper/configs/
    mkdir -p /etc/conf.d/
    cp -rfv ${SNAPPER_CONF_D} /etc/conf.d/
fi

# Define the directory where Plymouth themes are stored
PLYMOUTH_THEMES_DIR="$HOME/ArchTitus/configs/usr/share/plymouth/themes"

# Specify the Plymouth theme to be used (in this case, "arch-glow")
PLYMOUTH_THEME="arch-glow"

# Create the directory for Plymouth themes if it doesn't exist
mkdir -p /usr/share/plymouth/themes

# Install the chosen Plymouth theme by copying it to the Plymouth themes directory
echo 'Installing Plymouth theme...'
cp -rf ${PLYMOUTH_THEMES_DIR}/${PLYMOUTH_THEME} /usr/share/plymouth/themes

# Check if the filesystem is LUKS
if  [[ $FS == "luks" ]]; then
    # Add 'plymouth' hook after 'base' and 'udev' in mkinitcpio.conf
    sed -i 's/HOOKS=(base udev*/& plymouth/' /etc/mkinitcpio.conf

    # Create 'plymouth-encrypt' hook after 'block' in mkinitcpio.conf
    sed -i 's/HOOKS=(base udev \(.*block\) /&plymouth-/' /etc/mkinitcpio.conf
else
    # Add 'plymouth' hook after 'base' and 'udev' in mkinitcpio.conf
    sed -i 's/HOOKS=(base udev*/& plymouth/' /etc/mkinitcpio.conf
fi

# Set the default Plymouth theme and regenerate initramfs
plymouth-set-default-theme -R arch-glow

# Print a message to indicate the successful installation of the Plymouth theme
echo 'Plymouth theme installed'

# Remove sudo rights without a password prompt
sed -i 's/^%wheel ALL=(ALL) NOPASSWD: ALL/# %wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers
sed -i 's/^%wheel ALL=(ALL:ALL) NOPASSWD: ALL/# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

# Add sudo rights for the 'wheel' group
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Return to the previous working directory (presumably where the script was executed from)
cd ~
