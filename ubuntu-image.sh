#!/bin/bash
set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

export LANGUAGE=C
export LC_ALL=C
export LANG=C

rm -rf build && mkdir build

mem_size=$(free --giga | grep Mem | awk '{print $2}')
if [ $mem_size -gt 15 ]; then
     mount -t tmpfs -o size=13G tmpfs build
fi

snap install --classic ubuntu-image
ubuntu-image --debug --workdir build classic image-definition.yaml

rm -rf build/root

# Функции монтирования окружения chroot
setup_mountpoint() {
    local mountpoint="$1"
    if [ ! -c /dev/mem ]; then
        mknod -m 660 /dev/mem c 1 1
        chown root:kmem /dev/mem
    fi
    mount dev-live -t devtmpfs "$mountpoint/dev"
    mount devpts-live -t devpts -o nodev,nosuid "$mountpoint/dev/pts"
    mount proc-live -t proc "$mountpoint/proc"
    mount sysfs-live -t sysfs "$mountpoint/sys"
    mount securityfs -t securityfs "$mountpoint/sys/kernel/security"
    mount -t cgroup2 none "$mountpoint/sys/fs/cgroup"
    mount -t tmpfs none "$mountpoint/tmp"
    mount -t tmpfs none "$mountpoint/var/lib/apt/lists"
    mount -t tmpfs none "$mountpoint/var/cache/apt"
}

teardown_mountpoint() {
    local mountpoint
    mountpoint=$(realpath "$1")
    mountpoint_match=$(echo "$mountpoint" | sed -e's,/$,,; s,/,\\/,g;')'\/'
    awk </proc/self/mounts "\$2 ~ /$mountpoint_match/ { print \$2 }" | LC_ALL=C sort -r | while IFS= read -r submount; do
        mount --make-private "$submount"
        umount "$submount"
    done
}

# 1. Сначала подготавливаем точки монтирования
setup_mountpoint build/chroot
mkdir -p build/chroot/kernel
cp *.deb build/chroot/kernel/

# 2. ИСПРАВЛЕНИЕ: Копируем скрипт настроек ТОЛЬКО после того, как все точки монтирования активны
chmod +x setup-script.sh
cp setup-script.sh build/chroot/

# 3. Запуск скрипта установки пакетов ядра внутри изолированного окружения
chroot build/chroot /setup-script.sh

# 4. Корректный демонтаж и очистка
teardown_mountpoint build/chroot
rm -f build/chroot/setup-script.sh
rm -rf build/chroot/kernel

rootfs="./ubuntu.rootfs.tar"
echo "rootfs=$rootfs" > rootfs

# Вычисляем версию ARM64 ванильного ядра по имени установленного файла Image или по каталогу модулей
if [ -d build/chroot/lib/modules ]; then
    kernel_version=$(ls -1 build/chroot/lib/modules | head -n 1)
else
    # Резервный вариант парсинга ванильного имени Image-7.2.X
    kernel_version=$(ls -1 build/chroot/boot/Image-* 2>/dev/null | head -n 1 | sed 's#.*/Image-##')
fi

if [ -z "$kernel_version" ]; then
    echo "Ошибка: Не удалось определить версию установленного ядра в build/chroot!"
    exit 1
fi

echo "kernel_version=$kernel_version" > kernel_version

# Упаковываем RootFS (Заходим внутрь, выполняем tar, возвращаемся обратно)
cd build/chroot && tar -cf ../../$rootfs --xattrs ./*
cd ../..

if [ $mem_size -gt 15 ]; then
    # Выходим из папки перед размонтированием busy-диска
    umount build
    sleep 2
fi  

exit 0
