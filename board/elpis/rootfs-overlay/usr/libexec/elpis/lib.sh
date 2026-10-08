# Shared by the elpis-* commands.  Sourced, never run; set PROG first.
#
# The ISO boots with the whole system in RAM.  What survives a reboot lives
# on a partition labelled ELPIS-DATA, mounted at /data:
#
#   /data/config/     copies of the files in /etc/elpis/keep.list
#   /data/system/     updates: one directory per version (bzImage, rootfs)
#   /data/grubenv     which update GRUB starts (see board/elpis/grub/grub.cfg.in)
#
# /run/elpis/state, written at boot by "elpis-storage boot", says how this
# boot went; see state_write below for its fields.

ELPIS_RUN=/run/elpis
ELPIS_STATE=$ELPIS_RUN/state
DATA=/data
CONFIG_STORE=$DATA/config
SYSTEM_DIR=$DATA/system
GRUBENV=$DATA/grubenv
KEEP_LIST=/etc/elpis/keep.list
KEEP_LIST_LOCAL=$CONFIG_STORE/keep.list.local
DATA_LABEL=ELPIS-DATA
EFI_LABEL=ELPISEFI

# The data partition starts 1 GiB into the disk when the disk is big enough,
# so that a later, larger ISO can be written over the front of it without
# reaching the settings.  It must have at least 256 MiB.
DATA_START_SECTORS=2097152
DATA_MIN_SECTORS=524288

say() {
	echo "$PROG: $*"
	logger -t "$PROG" -- "$*" 2>/dev/null
	return 0
}
warn() {
	echo "$PROG: $*" >&2
	logger -t "$PROG" -p user.warning -- "$*" 2>/dev/null
	return 0
}
die() {
	warn "$*"
	exit 1
}

# The value of a kernel command-line option, or 1 for a bare flag.
cmdline() {
	local w
	for w in $(cat /proc/cmdline); do
		case $w in
		"$1") echo 1; return 0 ;;
		"$1"=*) echo "${w#*=}"; return 0 ;;
		esac
	done
	return 1
}

# A field of /etc/elpis-release: the running system's identity.
release() {
	sed -n "s/^$1=//p" /etc/elpis-release
}

# ---- boot state ------------------------------------------------------------

state_load() {
	MODE=ram
	[ -r "$ELPIS_STATE" ] && . "$ELPIS_STATE"
	return 0
}

# state_write KEY=VALUE ...  -- replaces the whole state file.
state_write() {
	local kv
	mkdir -p "$ELPIS_RUN"
	for kv in "$@"; do
		printf "%s='%s'\n" "${kv%%=*}" "$(printf '%s' "${kv#*=}" | sed "s/'/'\\\\''/g")"
	done > "$ELPIS_STATE.new" && mv -f "$ELPIS_STATE.new" "$ELPIS_STATE"
}

data_mounted() {
	grep -q " $DATA " /proc/mounts
}

persistent() {
	state_load
	[ "$MODE" = persistent ] && data_mounted
}

# ---- disks -----------------------------------------------------------------

# sdb1 -> sdb, nvme0n1p3 -> nvme0n1, sdb -> sdb
disk_of() {
	local n=${1#/dev/}
	if [ -e "/sys/class/block/$n/partition" ]; then
		basename "$(readlink -f "/sys/class/block/$n/..")"
	else
		echo "$n"
	fi
}

# sdb 3 -> /dev/sdb3, nvme0n1 3 -> /dev/nvme0n1p3, mmcblk0 3 -> /dev/mmcblk0p3
part_dev() {
	case $1 in
	*[0-9]) echo "/dev/${1}p$2" ;;
	*) echo "/dev/$1$2" ;;
	esac
}

# A whole disk that can be written: not a CD, loop, device-mapper (Ventoy),
# RAID or RAM device, and not flagged read-only.
disk_writable() {
	case $1 in
	sr* | loop* | dm-* | md* | ram* | zram* | mtdblock* | nbd*) return 1 ;;
	esac
	[ -e "/sys/block/$1" ] || return 1
	[ "$(cat "/sys/block/$1/ro" 2>/dev/null)" = 0 ]
}

disk_sectors() {
	cat "/sys/block/$1/size"
}

# Partitions of the disk that are mounted (or swapped on), one per line.
disk_mounted_parts() {
	local d=$1
	awk -v d="/dev/$d" 'index($1, d) == 1 { print $1 }' /proc/mounts /proc/swaps 2>/dev/null |
		sort -u
}

blk_value() {
	blkid -c /dev/null -o value -s "$1" "$2" 2>/dev/null
}

# "start size" of partition N, from sfdisk's dump.
part_extent() {
	local p
	p=$(part_dev "$1" "$2")
	sfdisk -d "/dev/$1" 2>/dev/null |
		sed -n "s|^$p : *start= *\([0-9]*\), *size= *\([0-9]*\),.*|\1 \2|p"
}

# Is this disk laid out exactly as an Elpis ISO written to it leaves it, plus
# optionally the ELPIS-DATA partition Elpis added?
#
#   p1  the ISO (volume UUID $1)    p2  its EFI partition (type ef, ELPISEFI)
#   p3  ELPIS-DATA, or a partition Elpis made but did not get to format
#
# Anything else -- another partition, a GPT, a different ISO -- means the
# disk is somebody else's, and Elpis leaves it alone.
layout_ok() {
	local uuid=$1 d=$2 dump n p3
	dump=$(sfdisk -d "/dev/$d" 2>/dev/null) || return 1
	echo "$dump" | grep -q '^label: dos$' || return 1
	n=$(echo "$dump" | grep -c '^/dev/')
	[ "$n" = 2 ] || [ "$n" = 3 ] || return 1
	echo "$dump" | grep "^$(part_dev "$d" 1) :" >/dev/null || return 1
	echo "$dump" | grep "^$(part_dev "$d" 2) :" | grep -q 'type=ef' || return 1
	[ "$(blk_value UUID "$(part_dev "$d" 1)")" = "$uuid" ] || return 1
	[ "$(blk_value LABEL "$(part_dev "$d" 2)")" = "$EFI_LABEL" ] || return 1
	if [ "$n" = 3 ]; then
		p3=$(part_dev "$d" 3)
		echo "$dump" | grep "^$p3 :" | grep -q 'type=83' || return 1
		case $(blk_value LABEL "$p3")/$(blk_value TYPE "$p3") in
		"$DATA_LABEL"/ext4) ;;
		/) ;;		# made by Elpis, formatting interrupted
		*) return 1 ;;
		esac
	fi
	return 0
}

wait_for_block() {
	local i=0
	while [ ! -b "$1" ] && [ $i -lt 20 ]; do
		sleep 1
		i=$((i + 1))
	done
	[ -b "$1" ]
}

mkfs_data() {
	# A fixed, modest inode count keeps mkfs quick on a large disk, and
	# GRUB 2.12 reads every feature mke2fs turns on by default.
	mkfs.ext4 -q -F -L "$DATA_LABEL" -m 1 -N 32768 "$1"
}

# Add ELPIS-DATA as partition 3 of a disk whose layout_ok holds.
# Returns 0 when made, 2 when the disk is too small, 1 on failure.
create_data_part() {
	local d=$1 total p2 end2 start p3
	total=$(disk_sectors "$d")
	p2=$(part_extent "$d" 2)
	[ -n "$p2" ] || return 1
	end2=$(( ${p2% *} + ${p2#* } ))
	start=$(( (end2 + 2047) / 2048 * 2048 ))
	if [ $(( total - DATA_START_SECTORS )) -ge "$DATA_MIN_SECTORS" ] &&
	   [ "$start" -lt "$DATA_START_SECTORS" ]; then
		start=$DATA_START_SECTORS
	fi
	[ $(( total - start )) -ge "$DATA_MIN_SECTORS" ] || return 2

	# Never let sfdisk wipe signatures: the ISO itself starts at sector 0.
	echo "start=$start, type=83" |
		sfdisk --append --no-reread --wipe never --wipe-partitions never -q "/dev/$d" ||
		return 1
	p3=$(part_dev "$d" 3)
	partx -a -n 3 "/dev/$d" 2>/dev/null || [ -b "$p3" ] || blockdev --rereadpt "/dev/$d" 2>/dev/null
	wait_for_block "$p3" || return 1
	mkfs_data "$p3"
}

# Mount ELPIS-DATA at /data, checking it once if it will not mount.
mount_data() {
	mkdir -p "$DATA"
	mount -t ext4 -o noatime "$1" "$DATA" 2>/dev/null && return 0
	warn "$1 would not mount; checking it"
	e2fsck -p "$1" >/dev/null 2>&1
	mount -t ext4 -o noatime "$1" "$DATA"
}

# ---- GRUB's environment block ----------------------------------------------
# 1024 bytes: a header line, KEY=VALUE lines, '#' padding.  GRUB reads it with
# load_env and counts down "tries" in place with save_env.

grubenv_get() {
	[ -f "$GRUBENV" ] || return 0
	grep -v '^#' "$GRUBENV" | sed -n "s/^$1=//p" | head -n 1
}

# grubenv_set KEY=VALUE ...  (an empty VALUE removes KEY)
grubenv_set() {
	local tmp=$GRUBENV.new size kv
	{
		echo '# GRUB Environment Block'
		if [ -f "$GRUBENV" ]; then
			grep -v '^#' "$GRUBENV" | grep '=' | while IFS= read -r line; do
				for kv in "$@"; do
					[ "${kv%%=*}" = "${line%%=*}" ] && continue 2
				done
				echo "$line"
			done
		fi
		for kv in "$@"; do
			if [ -n "${kv#*=}" ]; then echo "$kv"; fi
		done
	} > "$tmp.body"
	size=$(wc -c < "$tmp.body")
	if [ "$size" -gt 1024 ]; then
		rm -f "$tmp.body"
		return 1
	fi
	{
		cat "$tmp.body"
		dd if=/dev/zero bs=1 count=$((1024 - size)) 2>/dev/null | tr '\0' '#'
	} > "$tmp" || return 1
	rm -f "$tmp.body"
	sync "$tmp" && mv -f "$tmp" "$GRUBENV" && sync
}

# ---- the keep list ---------------------------------------------------------

keep_paths() {
	cat "$KEEP_LIST" "$KEEP_LIST_LOCAL" 2>/dev/null |
		sed -e 's/#.*//' -e 's/[[:space:]]*$//' | grep '^/' | sort -u
}

# Copy PATH from the running system into the store under ROOT (default
# /data/config), replacing what was there; a PATH that no longer exists is
# removed from the store.
store_path() {
	local p=$1 root=${2:-$CONFIG_STORE} dst tmp
	dst=$root$p
	tmp=$dst.saving
	rm -rf "$tmp"
	if [ ! -e "$p" ]; then
		rm -rf "$dst"
		return 0
	fi
	mkdir -p "$(dirname "$dst")" || return 1
	cp -a "$p" "$tmp" || return 1
	sync "$tmp" 2>/dev/null
	rm -rf "$dst.old"
	if [ -e "$dst" ]; then mv -f "$dst" "$dst.old" || return 1; fi
	mv -f "$tmp" "$dst" || return 1
	rm -rf "$dst.old"
	return 0
}

# Put the stored copy of PATH back.  /etc/shadow is merged line by line, so an
# account the image adds later is not lost to an old saved copy.
restore_path() {
	local p=$1 src=$CONFIG_STORE$1
	[ -e "$src" ] || return 0
	case $p in
	/etc/shadow)
		awk -F: 'NR == FNR { s[$1] = $0; next }
			($1 in s) { print s[$1]; next }
			{ print }' "$src" /etc/shadow > /etc/shadow.new &&
			chmod 600 /etc/shadow.new && mv -f /etc/shadow.new /etc/shadow
		;;
	*)
		rm -rf "$p"
		mkdir -p "$(dirname "$p")"
		cp -a "$src" "$p"
		;;
	esac
}
