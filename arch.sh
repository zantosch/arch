#!/bin/bash

set -euo pipefail

exec > >(tee /var/log/arch_install.log) 2>&1

# SET TIMEZONE AND ENABLE NTP FOR PACMAN RELIABILITY
ln -sf /usr/share/zoneinfo/Asia/Manila /etc/localtime
hwclock --systohc
systemctl enable systemd-timesyncd.service

# INITIALIZE KEYS
pacman-key --init
#pacman-key --refresh-keys
pacman-key --populate archlinux

# DISK WIPE AND PARTITION (Warning: this will destroy all data on /dev/nvme0n1)
disk=/dev/nvme0n1
efi=${disk}p1
boot=${disk}p2
lvm_part=${disk}p3

# CHECK THAT TARGET DISK EXISTS BEFORE PROCEEDING
[ -b "$disk" ] || { echo "Disk $disk not found. Aborting."; exit 1; }

# CREATE PARTITIONS USING SGDISK
sgdisk -Z $disk
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:EFI $disk
sgdisk -n 2:0:+512M -t 2:8300 -c 2:BOOT $disk
sgdisk -n 3:0:0 -t 3:8e00 -c 3:LVM $disk
partprobe $disk
sleep 2

# VERIFY THAT PARTITIONS WERE CREATED
[ -b "$efi" ] && [ -b "$boot" ] && [ -b "$lvm_part" ] || { echo "Partitioning failed. Aborting."; exit 1; }

# FORMAT PARTITIONS
mkfs.fat -F32 $efi
mkfs.ext4 $boot

# ENCRYPT AND SETUP LVM
cryptsetup luksFormat $lvm_part
cryptsetup open --type luks $lvm_part lvm

# ENSURE LUKS OPEN SUCCEEDED
[ -b /dev/mapper/lvm ] || { echo "LUKS container did not open correctly. Aborting."; exit 1; }

pvcreate --dataalignment 1m /dev/mapper/lvm
vgcreate volgroup0 /dev/mapper/lvm
lvcreate -L 150G volgroup0 -n lv_root
lvcreate -L 21G volgroup0 -n lv_swap
lvcreate -l 99%FREE volgroup0 -n lv_home
modprobe dm_mod
vgscan
vgchange -ay

mkfs.ext4 /dev/volgroup0/lv_root
mount /dev/volgroup0/lv_root /mnt

mkfs.ext4 /dev/volgroup0/lv_home
mkdir /mnt/home
mount /dev/volgroup0/lv_home /mnt/home

mkswap /dev/volgroup0/lv_swap
swapon /dev/volgroup0/lv_swap

mkdir -p /mnt/boot
mount $boot /mnt/boot
mkdir -p /mnt/boot/efi
mount $efi /mnt/boot/efi

# VERIFY MOUNT POINTS EXIST
mountpoint -q /mnt || { echo "/mnt not mounted. Aborting."; exit 1; }
mountpoint -q /mnt/boot || { echo "/mnt/boot not mounted. Aborting."; exit 1; }
mountpoint -q /mnt/boot/efi || { echo "/mnt/boot/efi not mounted. Aborting."; exit 1; }

mkdir -p /mnt/etc
genfstab -U /mnt >> /mnt/etc/fstab
cat /mnt/etc/fstab

# INSTALL BASE SYSTEM
pacstrap -i /mnt base

# VERIFY BASE SYSTEM WAS INSTALLED
[ -d /mnt/etc ] || { echo "pacstrap failed. /mnt/etc not found. Aborting."; exit 1; }

# CHROOT SETUP
arch-chroot /mnt /bin/bash <<EOF

# SET TIMEZONE, HOSTNAME, AND HOSTS INSIDE CHROOT
ln -sf /usr/share/zoneinfo/Asia/Manila /etc/localtime
hwclock --systohc
systemctl enable systemd-timesyncd.service
echo "triton" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1 localhost
127.0.1.1 triton
HOSTS

pacman-key --init
#pacman-key --refresh-keys
pacman-key --populate archlinux

# ENABLE EXTRA AND MULTILIB REPOS
sed -i '/\[extra\]/,/Include/s/^#//' /etc/pacman.conf

sed -i '/multilib/s/^#//' /etc/pacman.conf
sed -i '/^multilib/,/^$/s/^#Include.*/\1/' /etc/pacman.conf


pacman -Syu --noconfirm
pacman -S --noconfirm linux linux-headers linux-lts linux-lts-headers linux-firmware nano base-devel openssh networkmanager wpa_supplicant wireless_tools netctl dialog lvm2 grub efibootmgr dosfstools os-prober mtools mesa

systemctl enable NetworkManager

# MKINITCPIO SETUP — ADD ENCRYPT AND LVM2 HOOKS
sed -i '/^HOOKS/s/block/block encrypt lvm2/' /etc/mkinitcpio.conf
mkinitcpio -p linux
mkinitcpio -p linux-lts

# LOCALE SETUP
sed -i '/^#en_US.UTF-8 UTF-8/s/^#//' /etc/locale.gen
locale-gen

# SUDO CONFIG — UNCOMMENT WHEEL GROUP LINE
pacman -S --noconfirm sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
visudo -c || { echo "/etc/sudoers is invalid. Aborting."; exit 1; }

# GRUB INSTALLATION AND CONFIGURATION
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=grub_uefi --recheck
mkdir -p /boot/grub/locale
cp /usr/share/locale/en\@quot/LC_MESSAGES/grub.mo /boot/grub/locale/en.mo

sed -i 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="cryptdevice=/dev/nvme0n1p3:volgroup0:allow-discards resume=/dev/volgroup0/lv_swap loglevel=3 quiet"|' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# SET VM.SWAPPINESS TO 1
echo 'vm.swappiness=1' >> /etc/sysctl.d/99-swappiness.conf

# ROOT PASSWORD SETUP
passwd

# USER ACCOUNT SETUP
useradd -m -g users -G wheel zantos
passwd zantos

# FIX HOME OWNERSHIP (optional, post-theme clone)
chown -R zantos:zantos /home/zantos

# CREATE USER HOME DIRECTORIES
sudo -u zantos mkdir -p /home/zantos/{Applications/scripts,Applications/vpn,Downloads,Pictures/wallpapers,Videos,Documents,.fonts,.config/rofi,.config/REAPER/KeyMaps}

# INSTALL DESKTOP APPLICATIONS (non-fatal)
pacman -S --noconfirm gnome-keyring gvfs udisks2 ufw nm-connection-editor network-manager-applet pavucontrol pulseaudio bluez bluez-utils blueman gtk-engine-murrine gtk-engines sass keepassxc rofi git bleachbit signal-desktop audacity psensor htop speedtest-cli pdfarranger krita qbittorrent handbrake kdenlive mixxx obs-studio soundconverter digikam cheese ibus-hangul lsscsi fastfetch noto-fonts hdparm acpi mpv hwinfo procinfo tmux nload cmus cmake reaper homebank obsidian yubikey-manager android-tools retroarch steam supertuxkart supertux flatpak timeshift grsync vlc libreoffice audacious redshift pcmanfm xarchiver p7zip lxappearance hddtemp rdfind alsa-utils brightnessctl inxi slock xf86-video-intel flameshot dunst mupdf mednafen || echo "Some desktop packages failed to install. Continuing..."

# INSTALL ARDOUR AND RELATED TOOLS
pacman -S --noconfirm ardour harvid new-session-manager xjadeo

# INSTALL POWER MANAGEMENT UTILITIES
pacman -S --noconfirm powertop thermald cpupower acpi acpid tlp

# INSTALL INTEL MICROCODE, MESA
pacman -S --noconfirm intel-ucode mesa 

# INSTALL SWAY AND LOGIN MANAGER
pacman -S --noconfirm sway swaylock waybar wofi alacritty greetd seatd

# CONFIGURE GREETD FOR MANUAL LOGIN INTO SWAY
mkdir -p /etc/greetd
cat <<CFG > /etc/greetd/config.toml
[terminal]
vt = 1

[default_session]
command = "sway"
user = ""
CFG

# ENABLE POST-INSTALL SERVICES
systemctl enable greetd
systemctl enable tlp.service
systemctl mask systemd-rfkill.service
systemctl mask systemd-rfkill.socket
systemctl enable udisks2
systemctl enable bluetooth.service
ufw enable

# INSTALL QOGIR THEME AND ICONS
sudo -u zantos bash -c "
cd ~
git clone https://github.com/vinceliuice/Qogir-theme
cd Qogir-theme
./install.sh
cd ~
git clone https://github.com/vinceliuice/Qogir-icon-theme
cd Qogir-icon-theme
./install.sh
"

# INSTALL YAY (AUR HELPER)
sudo -u zantos bash -c "
cd ~
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
"

sudo -u zantos yay -S brave-bin --noconfirm

EOF

umount -a
reboot
