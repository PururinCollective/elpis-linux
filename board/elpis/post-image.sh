#!/bin/sh
#
# post-image: assembles the hybrid ISO from the kernel, the root filesystem
# and GRUB.
#
#   p1  ISO 9660, read-only: GRUB, bzImage, rootfs.cpio.xz
#   p2  EFI system partition (FAT), appended
#
# The partition table is MBR only, no GPT, so that the appliance can append
# its ELPIS-DATA partition as p3 with a plain sfdisk --append.  BIOS starts
# GRUB from the El Torito image (CD) or boot_hybrid.img in the MBR (disk);
# UEFI starts BOOTX64.EFI from p2 (disk) or from the El Torito EFI entry,
# which points at the same partition (CD).

set -eu

BOARD=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$BOARD/../.." && pwd)
VERSION=${ELPIS_LINUX_VERSION:-$(cat "$TOP/VERSION")}
ARCH=x86_64
STAMP=$(cat "$BASE_DIR/elpis-build-stamp")
ISO_UUID=$(echo "$STAMP" | sed 's/^\(....\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)$/\1-\2-\3-\4-\5-\6-\7/')
ISO=$BINARIES_DIR/elpis-$VERSION-$ARCH.iso

die() { echo "post-image: $*" >&2; exit 1; }

GRUB_BUILD=
for d in "$BUILD_DIR"/grub2-*/; do [ -d "$d" ] && GRUB_BUILD=$d && break; done
[ -n "$GRUB_BUILD" ] || die "grub2 build directory not found"
GRUB_PC=${GRUB_BUILD}build-i386-pc/grub-core
GRUB_EFI=${GRUB_BUILD}build-x86_64-efi/grub-core
[ -f "$GRUB_PC/boot_hybrid.img" ] || die "missing $GRUB_PC/boot_hybrid.img"
[ -f "$GRUB_EFI/kernel.img" ] || die "missing x86_64-efi GRUB in $GRUB_EFI"

WORK=$BINARIES_DIR/iso
ROOT=$WORK/root
rm -rf "$WORK"
mkdir -p "$ROOT/boot/grub" "$ROOT/licenses"

fill() {
    sed -e "s/@ISO_UUID@/$ISO_UUID/g" -e "s/@VERSION@/$VERSION/g" "$1"
}

# ---- payload ---------------------------------------------------------------------
cp "$BINARIES_DIR/bzImage" "$BINARIES_DIR/rootfs.cpio.xz" "$ROOT/boot/"
cp "$TARGET_DIR/etc/elpis-release" "$ROOT/boot/elpis-release"
fill "$BOARD/grub/grub.cfg.in" > "$ROOT/boot/grub/grub.cfg"
cp "$TARGET_DIR/usr/share/licenses/elpis-resolver/LICENSE" "$ROOT/licenses/elpis-resolver.txt"

# ---- GRUB core images --------------------------------------------------------------
# Built here rather than by the grub2 package because the embedded config has
# to name this build's ISO UUID.  Every module is built in; the ISO carries no
# module directory.
fill "$BOARD/grub/embed.cfg" > "$WORK/embed.cfg"
MODS="iso9660 part_msdos ext2 fat search search_fs_uuid search_label
      configfile normal linux test loadenv regexp probe echo true sleep cat ls
      halt reboot serial terminal"
# shellcheck disable=SC2086  # MODS is a list
"$HOST_DIR/bin/grub-mkimage" -d "$GRUB_PC" -O i386-pc-eltorito \
    -o "$ROOT/boot/grub/bios.img" -p /boot/grub -c "$WORK/embed.cfg" \
    biosdisk $MODS
# shellcheck disable=SC2086
"$HOST_DIR/bin/grub-mkimage" -d "$GRUB_EFI" -O x86_64-efi \
    -o "$WORK/BOOTX64.EFI" -p /boot/grub -c "$WORK/embed.cfg" \
    efi_gop efi_uga $MODS

# ---- EFI system partition ------------------------------------------------------------
efi_kb=$(( $(stat -c %s "$WORK/BOOTX64.EFI") / 1024 + 256 ))
efi_kb=$(( (efi_kb + 63) / 64 * 64 ))
rm -f "$WORK/efiboot.img"
"$HOST_DIR/sbin/mkfs.vfat" -C -n ELPISEFI "$WORK/efiboot.img" "$efi_kb" >/dev/null
export MTOOLS_SKIP_CHECK=1
"$HOST_DIR/bin/mmd" -i "$WORK/efiboot.img" ::/EFI ::/EFI/BOOT
"$HOST_DIR/bin/mcopy" -i "$WORK/efiboot.img" "$WORK/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI

# ---- the ISO ----------------------------------------------------------------------------
rm -f "$ISO" "$ISO.sha256" "$ISO.minisig"
"$HOST_DIR/bin/xorriso" -as mkisofs \
    -quiet \
    -iso-level 3 -rational-rock -volid ELPIS \
    --modification-date="$STAMP" \
    -c boot/boot.cat \
    -b boot/grub/bios.img -no-emul-boot -boot-load-size 4 -boot-info-table \
    --grub2-boot-info --grub2-mbr "$GRUB_PC/boot_hybrid.img" --mbr-force-bootable \
    -partition_offset 16 \
    -append_partition 2 0xef "$WORK/efiboot.img" \
    -eltorito-alt-boot -e --interval:appended_partition_2:all:: -no-emul-boot \
    -o "$ISO" "$ROOT"

(cd "$BINARIES_DIR" && sha256sum "$(basename "$ISO")" > "$(basename "$ISO").sha256")

# ---- signature -------------------------------------------------------------------------------
# Needs a minisign key without a password (minisign -G -W), since nothing can
# type one here.
if [ -n "${ELPIS_SIGNING_KEY:-}" ]; then
    [ -f "$ELPIS_SIGNING_KEY" ] || die "ELPIS_SIGNING_KEY=$ELPIS_SIGNING_KEY not found"
    "$HOST_DIR/bin/minisign" -S -s "$ELPIS_SIGNING_KEY" -m "$ISO" \
        -t "elpis-linux $VERSION build $STAMP" </dev/null
fi

echo "post-image: $ISO"
echo "post-image: ISO UUID $ISO_UUID, $(stat -c %s "$ISO") bytes"
