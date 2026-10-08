#!/bin/sh
#
# post-build: runs after the packages and the overlay are in $TARGET_DIR and
# before the root filesystem is packed.  $1 is the target directory.

set -eu

TARGET=$1
BOARD=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$BOARD/../.." && pwd)
VERSION=${ELPIS_LINUX_VERSION:-$(cat "$TOP/VERSION")}
ARCH=x86_64

die() { echo "post-build: $*" >&2; exit 1; }

# One stamp per build, shared with post-image.sh: it is BUILD_ID here and the
# ISO's volume UUID there (16 digits, YYYYMMDDhhmmsscc, as ISO 9660 dates are).
EPOCH=$(date -u +%s)
STAMP=$(date -u -d "@$EPOCH" +%Y%m%d%H%M%S)00
echo "$STAMP" > "$BASE_DIR/elpis-build-stamp"
ISO_UUID=$(echo "$STAMP" | sed 's/^\(....\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)$/\1-\2-\3-\4-\5-\6-\7/')

# The resolver package leaves its version here.
. "$TARGET/usr/share/elpis/resolver-version"

# ---- release identity --------------------------------------------------------
cat > "$TARGET/etc/elpis-release" <<EOF
VERSION=$VERSION
BUILD_ID=$STAMP
BUILD_EPOCH=$EPOCH
ISO_UUID=$ISO_UUID
ARCH=$ARCH
RESOLVER_VERSION=$RESOLVER_VERSION
RESOLVER_BUILD=$RESOLVER_BUILD
EOF

cat > "$TARGET/usr/lib/os-release" <<EOF
NAME="Elpis Linux"
ID=elpis
VERSION="$VERSION"
VERSION_ID=$VERSION
BUILD_ID=$STAMP
PRETTY_NAME="Elpis Linux $VERSION (resolver $RESOLVER_VERSION)"
HOME_URL="https://github.com/PururinCollective/elpis-linux"
EOF

# ---- the appliance's resolver defaults ----------------------------------------
# Derived from the resolver's own reference config, so every other setting
# and comment stays as upstream ships it.  This is the image's "shipped"
# copy: /etc/elpis/elpis.conf starts as it, and after an update a saved
# config is merged against it (tools/conf-merge.sh).
UP=$TARGET/usr/share/elpis/elpis.conf.upstream
CONF=$TARGET/usr/share/elpis/elpis.conf
[ -f "$UP" ] || die "missing $UP"
{
    echo "# elpis.conf -- Elpis Linux appliance defaults"
    echo "#"
    echo "# The resolver's reference config with four changes: it answers on"
    echo "# port 53 on every address, logs to syslog (read it with logread), and"
    echo "# drops root for the elpis account once the port is bound."
    echo "# Save changes with elpis-save, or they are gone at the next reboot."
    echo "#"
    sed -e 's/^listen: 127\.0\.0\.1@5335$/listen: 0.0.0.0@53/' \
        -e 's/^listen: \[::1\]@5335$/listen: [::]@53/' \
        -e 's/^log-destination: stderr/log-destination: syslog/' \
        -e 's/^# user: elpis$/user: elpis/' \
        -e 's/^# group: elpis$/group: elpis/' \
        "$UP"
} > "$CONF"
for want in 'listen: 0.0.0.0@53' 'listen: \[::\]@53' 'log-destination: syslog' \
            'user: elpis' 'group: elpis'; do
    grep -q "^$want" "$CONF" || die "could not set '$want' in elpis.conf (did upstream change?)"
done
if grep -q '^listen: .*@5335' "$CONF"; then
    die "loopback listen lines left in elpis.conf"
fi
install -D -m 0644 "$CONF" "$TARGET/etc/elpis/elpis.conf"
install -D -m 0644 "$CONF" "$TARGET/etc/elpis/elpis.conf.shipped"

# ---- update signing key --------------------------------------------------------
rm -f "$TARGET/etc/elpis/update.pub"
if [ -n "${ELPIS_UPDATE_PUBKEY:-}" ]; then
    [ -f "$ELPIS_UPDATE_PUBKEY" ] || die "ELPIS_UPDATE_PUBKEY=$ELPIS_UPDATE_PUBKEY not found"
    install -m 0644 "$ELPIS_UPDATE_PUBKEY" "$TARGET/etc/elpis/update.pub"
fi

# ---- name resolution for the appliance itself -----------------------------------
# The box asks its own resolver.  DHCP still runs, but the DNS servers it
# offers go to a side file instead of resolv.conf.
rm -f "$TARGET/etc/resolv.conf"
echo "nameserver 127.0.0.1" > "$TARGET/etc/resolv.conf"
UDHCPC=$TARGET/usr/share/udhcpc/default.script
if [ -f "$UDHCPC" ]; then
    sed -i 's|^RESOLV_CONF=.*|RESOLV_CONF="/run/resolv.conf.dhcp"|' "$UDHCPC"
    grep -q '^RESOLV_CONF="/run/resolv.conf.dhcp"' "$UDHCPC" || die "could not redirect udhcpc's resolv.conf"
fi

# ---- nothing boots from the root filesystem itself --------------------------------
# The kernel and GRUB go on the ISO; copies installed here would only take RAM.
rm -rf "$TARGET/boot"
