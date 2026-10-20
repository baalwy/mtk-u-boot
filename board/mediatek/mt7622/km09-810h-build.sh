#!/bin/sh
# ---------------------------------------------------------------------------
# Mercury KM09-810H (MediaTek MT7622) bootloader build script
#
# All builds happen IN-TREE (this repo) or in a persistent TF-A checkout.
# No /tmp directories are used so that every artifact survives reboots.
#
# Hardware facts (verified from the stock NAND dump in
# /home/baalwy/km09-810h/, see extracted/manifest.txt):
#   - SoC: MT7622, boot medium: SPI-NAND (Macronix MX35LF1GE4AB, 2k+64)
#   - RAM: 512 MiB @ 0x40000000 (DDR topology 1x vs 2x chip NOT confirmed,
#     therefore both 1ddr (DDR3_FLYBY=0) and 2ddr (DDR3_FLYBY=1) are built)
#   - LAN switch: MT7530 @ MDIO 0x1f, CPU port = port@5 (GMAC5) wired to
#     GMAC1 (phy-mode rgmii). Confirmed by stock bootloader strings:
#     "GMAC1 Force link status enable !!" / "MT7530 Reset Completed!!"
#     and by the vendor DTB: mac@1 rgmii <- switch@1f port@5 label "cpu".
#   - GMAC0 is the WAN port behind an Aquantia 2500base-x PHY (not used
#     by U-Boot here).
#   - Stock flash layout (logical offsets):
#       Preloader 0x000000 (BL2 goes here, write bl2.img NOT bl2.bin)
#       ATF       0x080000 (FIP goes here, spans ATF+Bootloader, 768 KiB)
#       Bootloader 0x0C0000 (old LK U-Boot; overwritten by the FIP)
#       Config    0x140000, Factory 0x1C0000  (keep! never touch)
#   - Bad-block handling: stock BMT v2 at last block, NOT NMBM. Do not
#     enable CONFIG_ENABLE_NAND_NMBM on this board.
#
# Usage:
#   ./board/mediatek/mt7622/km09-810h-build.sh [uboot|ram|snand|all]
#
# Environment overrides:
#   TFA_DIR   (default: $HOME/arm-trusted-firmware, branch mtksoc)
#   OUT_DIR   (default: $HOME/km09-810h/bootloader-build)
#   CROSS     (default: aarch64-linux-gnu-)
# ---------------------------------------------------------------------------
set -e

UBOOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
TFA_DIR="${TFA_DIR:-$HOME/arm-trusted-firmware}"
OUT_DIR="${OUT_DIR:-$HOME/km09-810h/bootloader-build}"
CROSS="${CROSS:-aarch64-linux-gnu-}"
DEFCONFIG="mt7622_mercury_km09_810h_defconfig"
STAGE="${1:-all}"

NPROC="$(nproc)"
MANIFEST="$OUT_DIR/manifest-build.txt"

mkdir -p "$OUT_DIR"

log_manifest() {
	echo "$(date -Is) $*" >> "$MANIFEST"
}

build_uboot() {
	echo "==> Building U-Boot in-tree: $UBOOT_DIR"
	cd "$UBOOT_DIR"
	make "$DEFCONFIG"
	make CROSS_COMPILE="$CROSS" -j"$NPROC"
	cp -f u-boot.bin "$OUT_DIR/u-boot-km09-810h.bin"
	cp -f u-boot.dtb "$OUT_DIR/u-boot-km09-810h.dtb"
	log_manifest "u-boot: $(git log -1 --format='%h') + board files, sha256=$(sha256sum "$OUT_DIR/u-boot-km09-810h.bin" | cut -d' ' -f1)"
}

# RAM/UART download mode: bl2.bin is loaded by mtk_uartboot over UART,
# then it pulls the FIP (BL31 + U-Boot BL33) also via UART. Nothing is
# written to NAND. This is the SAFE bring-up test path.
build_ram() {
	echo "==> Building TF-A RAM/UART variants (1ddr + 2ddr)"
	for v in "1ddr:0" "2ddr:1"; do
		name="${v%%:*}"; flyby="${v##*:}"
		cd "$TFA_DIR"
		make -f Makefile PLAT=mt7622 BOOT_DEVICE=ram RAM_BOOT_UART_DL=1 \
			DDR3_FLYBY="$flyby" \
			BL33="$UBOOT_DIR/u-boot.bin" \
			CROSS_COMPILE="$CROSS" \
			BUILD_BASE="$TFA_DIR/build-km09-ram-$name" all fip > "$OUT_DIR/build-ram-$name.log" 2>&1
		cp -f "$TFA_DIR/build-km09-ram-$name/mt7622/release/bl2.bin" "$OUT_DIR/bl2-ram-uart-$name.bin"
		cp -f "$TFA_DIR/build-km09-ram-$name/mt7622/release/fip.bin" "$OUT_DIR/fip-ram-uart-$name.bin"
		log_manifest "bl2-ram-uart-$name: $(sha256sum "$OUT_DIR/bl2-ram-uart-$name.bin" | cut -d' ' -f1)"
		log_manifest "fip-ram-uart-$name: $(sha256sum "$OUT_DIR/fip-ram-uart-$name.bin" | cut -d' ' -f1)"
	done
	echo "    Test with:"
	echo "    $HOME/spacelink-WR6000K/recovery/mtk_uartboot -s /dev/ttyUSB0 \\"
	echo "        -p $OUT_DIR/bl2-ram-uart-1ddr.bin \\"
	echo "        -f $OUT_DIR/fip-ram-uart-1ddr.bin"
	echo "    (power-cycle the router right after 'Handshake...' appears)"
}

# SPI-NAND production images: BL2 must be the .img variant (BootROM NFI
# header + BRLYT). BL2 reads the FIP from logical offset 0x80000.
build_snand() {
	echo "==> Building TF-A SPI-NAND variants (1ddr + 2ddr)"
	for v in "1ddr:0" "2ddr:1"; do
		name="${v%%:*}"; flyby="${v##*:}"
		cd "$TFA_DIR"
		make -f Makefile PLAT=mt7622 BOOT_DEVICE=snand NAND_TYPE=2k+64 \
			NMBM=0 UBI=0 DDR3_FLYBY="$flyby" \
			OVERRIDE_FIP_BASE=0x80000 OVERRIDE_FIP_SIZE=0xc0000 \
			BL33="$UBOOT_DIR/u-boot.bin" \
			CROSS_COMPILE="$CROSS" \
			BUILD_BASE="$TFA_DIR/build-km09-snand-$name" all fip > "$OUT_DIR/build-snand-$name.log" 2>&1
		cp -f "$TFA_DIR/build-km09-snand-$name/mt7622/release/bl2.bin" "$OUT_DIR/bl2-snand-2k64-$name.bin"
		cp -f "$TFA_DIR/build-km09-snand-$name/mt7622/release/bl2.img" "$OUT_DIR/bl2-snand-2k64-$name.img"
		cp -f "$TFA_DIR/build-km09-snand-$name/mt7622/release/fip.bin" "$OUT_DIR/fip-snand-$name.bin"
		log_manifest "bl2-snand-2k64-$name.img: $(sha256sum "$OUT_DIR/bl2-snand-2k64-$name.img" | cut -d' ' -f1)"
		log_manifest "fip-snand-$name: $(sha256sum "$OUT_DIR/fip-snand-$name.bin" | cut -d' ' -f1)"
	done
	cat <<'EOF'
    Writing to NAND (only AFTER the RAM/UART test succeeded with the
    matching DDR variant!):

      # from a working U-Boot (RAM test or stock bootmenu TFTP):
      tftp 0x46000000 bl2-snand-2k64-1ddr.img
      mtd erase Preloader && mtd write Preloader 0x46000000 $filesize
      tftp 0x46000000 fip-snand-1ddr.bin
      mtd erase ATF && mtd erase Bootloader
      mtd write ATF 0x46000000 $filesize
      # FIP spans ATF+Bootloader partitions by design (0x80000..0x140000)

    NEVER write bl2.bin to NAND - use bl2.img (has BootROM NFI header).
    NEVER touch Config / Factory partitions.
EOF
}

case "$STAGE" in
	uboot)  build_uboot ;;
	ram)    build_ram ;;
	snand)  build_snand ;;
	all)    build_uboot; build_ram; build_snand ;;
	*)	    echo "usage: $0 [uboot|ram|snand|all]"; exit 1 ;;
esac

echo "==> Done. Artifacts in $OUT_DIR (see manifest-build.txt)"
