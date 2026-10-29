#!/bin/bash
set -x
set -eE

# 1. Update the local package cache (Needed due to empty tmpfs /var/lib/apt/lists)
apt-get update

# 2. Video group permissions configuration
sed -i 's/#EXTRA_GROUPS=.*/EXTRA_GROUPS="video"/g' /etc/adduser.conf
sed -i 's/#ADD_EXTRA_GROUPS=.*/ADD_EXTRA_GROUPS=1/g' /etc/adduser.conf

# 3. Setup kernel boot arguments for RK3588 (ttyFIQ0 serial console)
echo -n "rootwait rw console=ttyS2,1500000 console=tty1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory" > /etc/kernel/cmdline
echo -n " quiet splash plymouth.ignore-serial-consoles" >> /etc/kernel/cmdline

# 4. Automate default user creation (ubuntu / ubuntu)
if ! id -u ubuntu >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,video ubuntu
    echo "ubuntu:ubuntu" | chpasswd
fi

# 5. Configure u-boot boot menu choices
#mkdir -p /usr/share/u-boot-menu/conf.d
#cat << 'EOF' > /usr/share/u-boot-menu/conf.d/ubuntu.conf
#U_BOOT_UPDATE="true"
#U_BOOT_PROMPT="1"
#U_BOOT_PARAMETERS="$(cat /etc/kernel/cmdline)"
#U_BOOT_TIMEOUT="20" 
#EOF

# 6. Reset Machine IDs to force recalculation on first boot
rm -f /var/lib/dbus/machine-id
true > /etc/machine-id
touch /var/log/syslog
chown root:adm /var/log/syslog
ssh-keygen -A

# 7. Install custom vanilla kernel packages
if [ "$(ls -A kernel/)" ]; then
    dpkg -i kernel/*.deb
fi
cd / && rm -rf kernel

# 8. Purge conflicting utilities and packages that block custom u-boot
#apt-get -y purge cloud-init flash-kernel fwupd ufw grub-efi-arm64 || true
#apt-get -y autoremove
#apt-get clean

sync
