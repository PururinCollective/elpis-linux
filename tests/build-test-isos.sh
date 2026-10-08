#!/bin/sh
#
# Builds the two ISOs the update test needs, with a throwaway signing key:
#
#   tests/work/base.iso     ./VERSION, with the test key built in
#   tests/work/update.iso   ./VERSION-update, signed with the test key
#
# The next plain "make" (without the key variables) builds an image without
# a key again.
#
#   tests/build-test-isos.sh
#   tests/elpis-test.py --iso tests/work/base.iso \
#       --update-iso tests/work/update.iso --key tests/work/keys/test.key

set -eu
cd "$(dirname "$0")/.."

KEYS=tests/work/keys
V=$(cat VERSION)
MINISIGN=output/host/bin/minisign
[ -x "$MINISIGN" ] || { echo "build once first (make), for $MINISIGN" >&2; exit 1; }

mkdir -p "$KEYS"
[ -f "$KEYS/test.key" ] || "$MINISIGN" -G -W -p "$KEYS/test.pub" -s "$KEYS/test.key"

build() {
	make UPDATE_PUBKEY="$KEYS/test.pub" SIGNING_KEY="$KEYS/test.key" ELPIS_LINUX_VERSION="$1"
	cp "output/images/elpis-$1-x86_64.iso" "tests/work/$2.iso"
	cp "output/images/elpis-$1-x86_64.iso.minisig" "tests/work/$2.iso.minisig"
}

build "$V" base
build "$V-update" update
ls -l tests/work/base.iso tests/work/update.iso
