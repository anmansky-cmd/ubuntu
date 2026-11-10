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

# ============================================================
# ИСПРАВЛЕНИЕ: Установка ubuntu-image с повторными попытками
# ============================================================
for i in {1..5}; do
    echo "Попытка установки ubuntu-image (попытка $i из 5)..."
    if snap install --classic ubuntu-image; then
        echo "Ubuntu-image успешно установлен."
        break
    fi
    
    if [ $i -eq 5 ]; then
        echo "КРИТИЧЕСКАЯ ОШИБКА: Не удалось установить ubuntu-image после 5 попыток."
        exit 1
    fi
    
    echo "Сетевая ошибка при скачивании Snap. Ожидание 15 секунд перед следующей попыткой..."
    sleep 15
done

#### ubuntu-image --debug --workdir build classic image-definition.yaml
# Попытка сборки образа с ретраями (из-за нестабильности Snap Store)
for attempt in {1..3}; do
    echo "Попытка сборки образа (попытка $attempt из 3)..."
    if ubuntu-image --debug --workdir build classic image-definition.yaml; then
        echo "Сборка образа успешно завершена."
        break
    fi
    
    if [ $attempt -eq 3 ]; then
        echo "КРИТИЧЕСКАЯ ОШИБКА: Не удалось собрать образ после 3 попыток."
        exit 1
    fi
    
    echo "Ошибка при сборке. Очистка build и ожидание 30 секунд..."
    rm -rf build/chroot  # Очищаем частично собранный chroot, чтобы начать заново
    sleep 30
done

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

# 2. ИСПРАВЛЕНИЕ: Копируем рабочий DNS перед chroot
# Удаляем битую ссылку (если есть), чтобы cp не ругался
rm -f build/chroot/etc/resolv.conf

# Копируем реальное содержимое (флаг -L разыменовывает ссылки на хосте)
if [ -L /etc/resolv.conf ]; then
    cp -L /etc/resolv.conf build/chroot/etc/resolv.conf 2>/dev/null || \
    cp /run/systemd/resolve/stub-resolv.conf build/chroot/etc/resolv.conf
else
    cp /etc/resolv.conf build/chroot/etc/resolv.conf
fi

# 3. Копируем скрипт настроек
chmod +x setup-script.sh
cp setup-script.sh build/chroot/

# 4. Запуск скрипта установки пакетов ядра внутри изолированного окружения
chroot build/chroot /setup-script.sh

# 5. Корректный демонтаж и очистка
teardown_mountpoint build/chroot
rm -f build/chroot/setup-script.sh
rm -rf build/chroot/kernel

# ============================================================
# ИСПРАВЛЕНИЕ: Восстанавливаем стандартную ссылку для systemd-resolved
# ============================================================
rm -f build/chroot/etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf build/chroot/etc/resolv.conf

rootfs="./ubuntu.rootfs.tar"
echo "rootfs=$rootfs" > rootfs

# Вычисляем версию ARM64 ванильного ядра по имени установленного файла Image или по каталогу модулей
if [ -d build/chroot/lib/modules ]; then
    kernel_version=$(ls -1 build/chroot/lib/modules | head -n 1)
else
    # Резервный вариант парсинга ванильного имени Image-7.3.X
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
