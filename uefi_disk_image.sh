#!/bin/bash
set -eE

cleanup_loopdev() {
    local loop="$1"
    sync --file-system && sync && sleep 1
    if [ -b "${loop}" ]; then
        local mountpoint_match
        mountpoint_match=$(echo "/tmp/mnt/writable" | sed -e's,/$,,; s,/,\\/,g;')'\/'
        awk </proc/self/mounts "\$2 ~ /$mountpoint_match/ { print \$2 }" | LC_ALL=C sort -r | while IFS= read -r submount; do
            mount --make-private "$submount" || true
            umount -l "$submount" || true
        done
        losetup -d "${loop}" || true
    fi
}

wait_loopdev() {
    local loop="$1" seconds="$2"
    until test $((seconds--)) -eq 0 -o -b "${loop}"; do sleep 1; done
    ((++seconds))
    ls -l "${loop}" &> /dev/null
}

if [ "$(id -u)" -ne 0 ]; then echo "Please run as root"; exit 1; fi
export LC_ALL=C LC_CTYPE=C LANGUAGE=C LANG=C

if [ ! -f ./rootfs ]; then exit 1; fi
. ./rootfs
. ./kernel_version

mkdir -p images
now=$(date +%F)
img="./images/Ubuntu-${kernel_version}-$2-$now.img"
size="$(( $(wc -c < "${rootfs}" ) / 1024 / 1024 ))"
# UEFI-образ требует минимум 8 ГБ (ESP + rootfs + запас)
truncate -s "8192M" "${img}"

loop="$(losetup -f)"
losetup -P "${loop}" "${img}"
disk="${loop}"
trap 'cleanup_loopdev ${loop}' EXIT

mount_point=/tmp/mnt
umount "${disk}"* 2> /dev/null || true
umount ${mount_point}/* 2> /dev/null || true
mkdir -p ${mount_point}/writable
mkdir -p ${mount_point}/boot

# ============================================================
# ШАГ 1: Создание GPT с ESP и rootfs разделами
# ESP: 512 MB (FAT32), rootfs: остальное (ext4)
# ============================================================
echo "=== Создание таблицы разделов GPT (ESP + rootfs) ==="
dd if=/dev/zero of="${disk}" count=4096 bs=512 conv=notrunc

parted --script "${disk}" mklabel gpt
parted --script "${disk}" mkpart ESP fat32 1MiB 513MiB
parted --script "${disk}" set 1 esp on
parted --script "${disk}" mkpart root ext4 513MiB 100%

# Устанавливаем тип раздела Linux rootfs для второго раздела
sgdisk --typecode=2:B921B045-1DF0-41C3-AF44-4C6F280D3FAE "${disk}"

partprobe "${disk}"
partition_char="$(if [[ ${disk: -1} == [0-9] ]]; then echo p; fi)"
sleep 1
wait_loopdev "${disk}${partition_char}1" 60
wait_loopdev "${disk}${partition_char}2" 60

# ============================================================
# ШАГ 2: Форматирование разделов
# ============================================================
echo "=== Форматирование ESP (FAT32) ==="
mkfs.vfat -F 32 -n ESP "${disk}${partition_char}1"

echo "=== Форматирование rootfs (ext4) ==="
root_uuid=$(uuidgen)
mkfs.ext4 -U "${root_uuid}" -L desktop-rootfs "${disk}${partition_char}2"

# ============================================================
# ШАГ 3: Монтирование и распаковка rootfs
# ============================================================
mount "${disk}${partition_char}2" ${mount_point}/writable
mkdir -p ${mount_point}/writable/boot/efi
mount "${disk}${partition_char}1" ${mount_point}/writable/boot/efi

tar -xpf "${rootfs}" -C ${mount_point}/writable

# ============================================================
# ШАГ 4: Настройка fstab
# ============================================================
esp_uuid=$(blkid -s UUID -o value "${disk}${partition_char}1")

cat > ${mount_point}/writable/etc/fstab << EOF
# <file system>     <mount point>  <type>  <options>   <dump>  <fsck>
UUID=${root_uuid,,} /              ext4    defaults,x-systemd.growfs    0       1
UUID=${esp_uuid,,}  /boot/efi      vfat    defaults                     0       2
EOF

# ============================================================
# ШАГ 5: Chroot для установки GRUB EFI
# ============================================================
mountpoint="${mount_point}/writable"

# Автоматически определяем точные имена файлов установленного ядра 7.3
vmlinuz_file=$(basename "$(ls "$mountpoint"/boot/vmlinuz-7.3.* 2>/dev/null | head -n 1)" 2>/dev/null || echo "")
initrd_file=$(basename "$(ls "$mountpoint"/boot/initrd.img-7.3.* 2>/dev/null | head -n 1)" 2>/dev/null || echo "")

if [ -z "$vmlinuz_file" ] || [ -z "$initrd_file" ]; then
    echo "КРИТИЧЕСКАЯ ОШИБКА: Ядро или initramfs версии 7.3 не найдены в /boot распакованной rootfs!"
    exit 1
fi

mount dev-live -t devtmpfs "$mountpoint/dev"
mount devpts-live -t devpts -o nodev,nosuid "$mountpoint/dev/pts"
mount proc-live -t proc "$mountpoint/proc"
mount sysfs-live -t sysfs "$mountpoint/sys"
mount securityfs -t securityfs "$mountpoint/sys/kernel/security"

# Копируем qemu для chroot на ARM64 (если хост не ARM64)
if [ ! -f "$mountpoint/usr/bin/qemu-aarch64-static" ] && [ -f /usr/bin/qemu-aarch64-static ]; then
    cp /usr/bin/qemu-aarch64-static "$mountpoint/usr/bin/"
fi

# ------------------------------------------------------------
# ИСПРАВЛЕНИЕ: Копируем рабочий DNS с хоста внутрь chroot
# без этого apt-get внутри chroot не сможет скачать пакеты
# ------------------------------------------------------------
echo "=== Настройка DNS для chroot ==="
if [ -L /etc/resolv.conf ]; then
    # Если на хосте systemd-resolved, копируем реальный файл
    cp /run/systemd/resolve/stub-resolv.conf "$mountpoint/etc/resolv.conf" 2>/dev/null || cp -L /etc/resolv.conf "$mountpoint/etc/resolv.conf"
else
    cp /etc/resolv.conf "$mountpoint/etc/resolv.conf"
fi

# Устанавливаем GRUB EFI внутри chroot
cat << 'CHROOT_SCRIPT' > "$mountpoint/tmp/install-grub.sh"
#!/bin/bash
set -eE
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends grub-efi-arm64 grub-efi-arm64-bin efibootmgr

# Устанавливаем GRUB на ESP (removable — без NVRAM записей, EDK2 UEFI подхватит его сам)
grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --removable --no-nvram
CHROOT_SCRIPT

chmod +x "$mountpoint/tmp/install-grub.sh"
chroot "$mountpoint" /tmp/install-grub.sh
rm -f "$mountpoint/tmp/install-grub.sh"

# Очищаем resolv.conf, чтобы не тащить настройки хоста в образ
rm -f "$mountpoint/etc/resolv.conf"
ln -sf /run/systemd/resolve/stub-resolv.conf "$mountpoint/etc/resolv.conf"

# Генерируем структуру grub.cfg НАПРЯМУЮ из сессии хоста (сразу с готовыми переменными)
# Мы создаем её и в корне EFI-раздела, и в папочке EFI/BOOT, и в системе
generate_grub_cfg() {
    local target_file="$1"
    cat > "${target_file}" << EOF
set default="0"
set timeout="3"

menuentry "Ubuntu 26.10 LTS (Linux 7.3 Mainline patched)" {
    insmod gzio
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root ${root_uuid}
    linux /boot/${vmlinuz_file} root=UUID=${root_uuid} rw rootwait console=ttyS2,1500000n8 console=tty1
    initrd /boot/${initrd_file}
    devicetree /boot/rk3588-nanopc-t6.dtb
}

menuentry "Ubuntu 26.10 LTS (rescue mode)" {
    insmod gzio
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root ${root_uuid}
    linux /boot/${vmlinuz_file} root=UUID=${root_uuid} rw rootwait single
    initrd /boot/${initrd_file}
    devicetree /boot/rk3588-nanopc-t6.dtb
}
EOF
}

# Записываем конфигурацию во все места, где её могут искать съемный GRUB и EDK2
mkdir -p "$mountpoint/boot/grub"
mkdir -p "$mountpoint/boot/efi/EFI/BOOT"

generate_grub_cfg "$mountpoint/boot/grub/grub.cfg"
generate_grub_cfg "$mountpoint/boot/efi/grub.cfg"
generate_grub_cfg "$mountpoint/boot/efi/EFI/BOOT/grub.cfg"

echo "=== GRUB успешно настроен под EDK2 UEFI ==="
ls -la "$mountpoint/boot/efi/EFI/BOOT/"

# ============================================================
# ШАГ 6: Финальная очистка
# ============================================================
trap '' EXIT
cleanup_loopdev "${loop}"

echo -e "\nCompressing $(basename "${img}.xz")\n"
xz -v -9 -T0 "${img}"
exit 0
