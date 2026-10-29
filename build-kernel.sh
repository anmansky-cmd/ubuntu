#!/bin/bash

# Останавливать скрипт при любых ошибках
set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

if [ $# -ne 1 ]; then
	echo "Использование: $0 имя_папки_сборки"
	exit 1
fi

# Установка необходимых инструментов для сборки ядра и инструментов упаковки .deb
sudo apt-get update && sudo apt-get -y install build-essential gcc-aarch64-linux-gnu bison \
qemu-user-binfmt qemu-system-arm qemu-efi-aarch64 binfmt-support \
debootstrap flex libssl-dev bc rsync kmod cpio xz-utils fakeroot parted \
udev dosfstools uuid-runtime git-lfs device-tree-compiler python3 \
python-is-python3 fdisk bc debhelper python3-pyelftools python3-setuptools \
python3-pkg-resources swig libfdt-dev libpython3-dev gawk \
git ncurses-dev libelf-dev libgnutls28-dev libdw-dev wget kmod crossbuild-essential-arm64 dwarves 

START_DIR=$(pwd)
linux_dir=$1

# Очистка и создание директории
rm -rf "$linux_dir" && mkdir "$linux_dir"

# Монтирование в ОЗУ для ускорения сборки
mem_size=$(free --giga | grep Mem | awk '{print $2}')
if [ $mem_size -gt 8 ]; then
	sudo mount -t tmpfs -o size=8G tmpfs "$linux_dir"
fi

cd "$linux_dir"
BASE_DIR=$(pwd)

# Клонируем ядро сразу в папку 'source' внутри виртуального диска
git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git -b linux-7.3.y source

# Скачивание патчей медиа-декодера rkvdec
mkdir patches && cd patches
wget https://raw.githubusercontent.com/anmansky-cmd/ubuntu/refs/heads/main/patches/gpu.patch
wget https://raw.githubusercontent.com/rcawston/rockchip-rk3588-mainline-patches/refs/heads/main/0001-rockchip-rk3588-vepu580-encoder-support-v3.patch
# 3559-media-rkvdec-fix-PM-runtime-teardown-ordering-in-remove.patch
wget https://raw.githubusercontent.com/warpme/minimyth2/refs/heads/master/script/kernel/linux-7.3/files/3559-media-rkvdec-fix-PM-runtime-teardown-ordering-in-remove.patch
# 3569-media-rkvdec-prime-VDPU383-deblock-warmup-rk3576.patch
wget https://raw.githubusercontent.com/warpme/minimyth2/refs/heads/master/script/kernel/linux-7.3/files/3569-media-rkvdec-prime-VDPU383-deblock-warmup-rk3576.patch
# 3570-media-rkvdec-add-VP9-VDPU381-decoder-support.patch
wget https://raw.githubusercontent.com/warpme/minimyth2/refs/heads/master/script/kernel/linux-7.3/files/3570-media-rkvdec-add-VP9-VDPU381-decoder-support.patch
# 3571-media-rkvdec-vp9-fix-altref-vscale-and-segmap-size-for-2K-decode.patch
wget https://raw.githubusercontent.com/warpme/minimyth2/refs/heads/master/script/kernel/linux-7.3/files/3571-media-rkvdec-vp9-fix-altref-vscale-and-segmap-size-for-2K-decode.patch
# 3572-media-rkvdec-vdpu381-add-VP9-profile-2-10bit-support.patch
wget https://raw.githubusercontent.com/warpme/minimyth2/refs/heads/master/script/kernel/linux-7.3/files/3572-media-rkvdec-vdpu381-add-VP9-profile-2-10bit-support.patch
# 3573-media-rkvdec-vdpu381-vp9-use-the-real-buffer-stride.patch
wget https://raw.githubusercontent.com/warpme/minimyth2/refs/heads/master/script/kernel/linux-7.3/files/3573-media-rkvdec-vdpu381-vp9-use-the-real-buffer-stride.patch
# 3574-media-rkvdec-Add-support-for-the-VDPU346-variant.patch
wget https://raw.githubusercontent.com/warpme/minimyth2/refs/heads/master/script/kernel/linux-7.3/files/3574-media-rkvdec-Add-support-for-the-VDPU346-variant.patch
# ДОБАВИТЬ: патч питания SD-слота для NanoPC-T6
## wget -O nanopc-t6-sdmmc-regulator.patch \
#  "https://lore.kernel.org/r/20240102024054.1030313-1-inindev@gmail.com/raw"
# Скачивание патчей медиа-декодера rkvdec
mkdir patches && cd patches
# ... ваши существующие wget ...

# ДОБАВИТЬ: патч отключения HDMI RX (создаём прямо здесь, в patches/)
cat > nanopc-t6-disable-hdmirx.patch << 'PATCH_EOF'
--- a/arch/arm64/boot/dts/rockchip/rk3588-nanopc-t6.dts
+++ b/arch/arm64/boot/dts/rockchip/rk3588-nanopc-t6.dts
@@ -1,3 +1,13 @@
+&hdmi_receiver {
+	status = "disabled";
+};
+
+&hdmi_receiver_cma {
+	status = "disabled";
+};
+
diff --git a/arch/arm64/boot/dts/rockchip/rk3588-nanopc-t6.dts b/arch/arm64/boot/dts/rockchip/rk3588-nanopc-t6.dts
index e69de29..a1b2c3d 100644
--- a/arch/arm64/boot/dts/rockchip/rk3588-nanopc-t6.dts
+++ b/arch/arm64/boot/dts/rockchip/rk3588-nanopc-t6.dts
@@ -0,0 +1,5 @@
+
+&gpu {
+	sram-supply = <&vdd_gpu_mem_s0>;
+};
diff --git a/arch/arm64/boot/dts/rockchip/rk3588-nanopc-t6.dtsi b/arch/arm64/boot/dts/rockchip/rk3588-nanopc-t6.dtsi
index e69de29..b2c3d4e 100644
--- a/arch/arm64/boot/dts/rockchip/rk3588-nanopc-t6.dtsi
+++ b/arch/arm64/boot/dts/rockchip/rk3588-nanopc-t6.dtsi
@@ -1,3 +1,13 @@
+
+&gpu {
+	mali-supply = <&vdd_gpu_s0>;
+	sram-supply = <&vdd_gpu_mem_s0>;
+	status = "okay";
+};
+
+&pd_gpu {
+	domain-supply = <&vdd_gpu_s0>;
+};
 /dts-v1/;
 #include "rk3588.dtsi"
 #include "rk3588-nanopc-t6.dtsi"
PATCH_EOF

cd "$BASE_DIR/source"

# Применение патчей
echo "=== Применение патчей ==="
for patch_file in "$BASE_DIR"/patches/*.patch; do
    echo "Применяется: $patch_file"
    patch -p1 --forward < "$patch_file" || true
done

cd "$BASE_DIR/source"

# Применение патчей стабильности rkvdec медиадекодера
#echo "=== Применение патчей ==="
#for patch_file in "$BASE_DIR"/patches/*.patch; do
#        echo "Применяется: $patch_file"
#        patch -p1 < "$patch_file"
#done

# Создаем файл настроек (Kconfig-фрагмент) для NanoPC-T6, RTL8822CE и зависимостей RTL8812AU
cat << 'EOF' > my-add.txt
# --- ОПТИМИЗАЦИЯ И СЕТЬ ДЛЯ NANOPC-T6 ---
CONFIG_ARCH_ROCKCHIP=y
CONFIG_ROCKCHIP_PM_DOMAINS=y
CONFIG_REGULATOR_RK808=y
CONFIG_R8169=m
CONFIG_REALTEK_PHY=m

# --- ПОДДЕРЖКА WI-FI И BLUETOOTH (RTL8822CE) ---
CONFIG_WIRELESS=y
CONFIG_CFG80211=m
CONFIG_MAC80211=m
CONFIG_WLAN=y
CONFIG_WLAN_VENDOR_REALTEK=y
CONFIG_RTW88=m
CONFIG_RTW88_CORE=m
CONFIG_RTW88_PCI=m
CONFIG_RTW88_8822c=m
CONFIG_RTW88_8822ce=m
CONFIG_BT=m
CONFIG_BT_HCIBTUSB=m
CONFIG_BT_RTL=m

# --- ДЛЯ ВНЕШНЕГО МОДУЛЯ RTL8812AU ---
CONFIG_USB_NET_DRIVERS=m
CONFIG_NET_UDP_TUNNEL=m
EOF

# Экспорт переменных кросс-компиляции
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

# Генерация базового конфига ядра ARM64 и накат нашего оптимизированного слоя
./scripts/kconfig/merge_config.sh arch/arm64/configs/defconfig my-add.txt

# Отключение тяжелой отладочной информации (экономия места и ОЗУ при сборке)
./scripts/config --set-val DEBUG_INFO_NONE y
./scripts/config --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
./scripts/config --disable DEBUG_INFO_DWARF4
./scripts/config --disable DEBUG_INFO_DWARF5

# Применение конфигурации
make olddefconfig

# Убираем суффикс архитектуры из версии ядра
sed -i 's/CONFIG_LOCALVERSION="-ARCH"/CONFIG_LOCALVERSION=""/' .config
 
# Безопасные флаги оптимизации под архитектуру ARMv8-A
export KCFLAGS="-march=armv8-a+crypto+crc -mtune=generic"

echo "=== Запуск компиляции deb-пакетов ==="
fakeroot make -j$(nproc) LOCALVERSION="-rockchip" deb-pkg

# Сохранение версии релиза
tmp_var=$(make LOCALVERSION="-rockchip" -s kernelrelease)
echo "tmp_var=$tmp_var" > "$START_DIR/tmp_var.txt"

# Выход из папки сборки в корень запуска
cd "$START_DIR"

# Перенос скомпилированных .deb пакетов ядра в папку запуска
cp "$BASE_DIR"/*.deb .

echo "=== СБОРКА ЯДРА ЗАВЕРШЕНА ==="
echo "Пакеты скопированы в: $START_DIR"

# Корректное размонтирование оперативной памяти
if [ $mem_size -gt 8 ]; then
	sudo umount "$linux_dir"
	sleep 2
fi

exit 0
