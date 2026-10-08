#!/bin/sh
#
# Tries elpis-config's commands on the host, against a scratch copy of the
# image's files (ELPIS_ROOT), with BusyBox's shell and tools and the image's
# own elpis binary.  Needs a built image (make) and busybox on the host.
#
#   tests/elpis-config-test.sh
#
# Checks that every managed elpis.conf key can be set, that the result passes
# the resolver's own check, that nothing but those keys changes, that bad
# values are refused, and the network, hostname, NTP and password commands.

set -u
TOP=$(cd "$(dirname "$0")/.." && pwd)
T=$TOP/output/target
WORK=$TOP/tests/work/config-test
[ -x "$T/usr/sbin/elpis" ] || { echo "build the image first (make)" >&2; exit 1; }
command -v busybox >/dev/null || { echo "needs busybox on the host" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/root/etc/elpis" "$WORK/root/etc/network" "$WORK/root/usr/share/elpis"
for a in $(busybox --list); do ln -sf "$(command -v busybox)" "$WORK/bin/$a"; done

cc -std=c99 -D_POSIX_C_SOURCE=200112L -Wall -Wextra -Werror -O2 \
	-o "$WORK/elpis-ipcheck" "$TOP/package/elpis-config/src/elpis-ipcheck.c" || exit 1
cat > "$WORK/elpis" <<EOF
#!/bin/sh
exec "$T/lib/ld-musl-x86_64.so.1" --library-path "$T/lib:$T/usr/lib" "$T/usr/sbin/elpis" "\$@"
EOF
chmod +x "$WORK/elpis"

R=$WORK/root
cp "$T/etc/elpis/elpis.conf" "$R/etc/elpis/elpis.conf"
cp "$T/usr/share/elpis/elpis.conf" "$R/usr/share/elpis/elpis.conf"
cp "$T/etc/elpis/ntp.conf" "$R/etc/elpis/ntp.conf"
cp "$T/etc/network/interfaces" "$R/etc/network/interfaces"
printf 'elpis\n' > "$R/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\telpis\n' > "$R/etc/hosts"
printf 'root::10933:0:99999:7:::\nelpis:*:::::::\n' > "$R/etc/shadow"
ORIG=$WORK/elpis.conf.orig
cp "$R/etc/elpis/elpis.conf" "$ORIG"

export ELPIS_ROOT=$R ELPIS_BIN=$WORK/elpis ELPIS_IPCHECK=$WORK/elpis-ipcheck \
	ELPIS_LIB=$TOP/board/elpis/rootfs-overlay/usr/libexec/elpis/lib.sh
PATH=$WORK/bin:$PATH
CFG="busybox sh $TOP/package/elpis-config/src/elpis-config"

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }
expect_ok() { what=$1; shift; if out=$("$@" 2>&1); then ok "$what"; else bad "$what: $out"; fi; }
expect_no() { what=$1; shift; if out=$("$@" 2>&1); then bad "$what (was accepted)"; else ok "$what"; fi; }
conf() { $CFG get "$1"; }

echo "== elpis.conf"
expect_ok "listen: three addresses" $CFG set listen 10.0.2.50@53 '[2001:db8::53]@53' 127.0.0.1@53
[ "$(conf listen | tr '\n' ' ')" = "10.0.2.50@53 [2001:db8::53]@53 127.0.0.1@53 " ] && ok "listen reads back" || bad "listen reads back: $(conf listen | tr '\n' ' ')"
expect_ok "access-control: a list" $CFG set access-control '127.0.0.0/8 allow' '::1/128 allow' '192.168.1.0/24 allow' '10.9.9.9/32 refuse'
[ "$(conf access-control | wc -l)" = 4 ] && ok "access-control has 4 rules" || bad "access-control: $(conf access-control)"
expect_ok "dnssec no" $CFG set dnssec no
expect_ok "authoritative-dot no" $CFG set authoritative-dot no
grep -q '^authoritative-dot: no  *# no, or opportunistic$' "$R/etc/elpis/elpis.conf" && ok "its trailing comment is kept" || bad "trailing comment lost: $(grep '^authoritative-dot:' "$R/etc/elpis/elpis.conf")"
expect_ok "ecs yes" $CFG set ecs yes
expect_ok "identity no" $CFG set identity no
expect_ok "webgui yes" $CFG set webgui yes
expect_ok "webgui-password from stdin" sh -c "echo 'correct horse battery' | $CFG webgui-password"
case $(conf webgui-password) in '$pbkdf2-sha256$'*) ok "webgui-password is stored as a hash" ;; *) bad "webgui-password: $(conf webgui-password)" ;; esac
n=$(grep -n '^webgui-password:' "$R/etc/elpis/elpis.conf" | cut -d: -f1)
p=$(grep -n '^# webgui-password: choose-something' "$R/etc/elpis/elpis.conf" | cut -d: -f1)
[ -n "$n" ] && [ -n "$p" ] && [ "$n" = $((p + 1)) ] && ok "it went in after its commented example" || bad "webgui-password at line $n, example at $p"

lic=elpis1.AgEAAAABAAAAAGjQ-14AAAAAemnfXgtDZW50dXJ5IEx0ZA.uHJvXi0v
if out=$($CFG set licence "$lic" 2>&1); then
	ok "licence: a token is stored (the resolver checks it when it starts)"
	expect_ok "licence removed again" $CFG set licence
	[ -z "$(conf licence)" ] && ok "no licence line left" || bad "licence still there"
else
	ok "licence: the resolver refuses a token it cannot read ($out)"
fi

final=$WORK/elpis.conf.final
cp "$R/etc/elpis/elpis.conf" "$final"
if "$WORK/elpis" -t -c "$final" 2>&1 | grep -qE ' ERROR |configuration error'; then
	bad "the final elpis.conf has errors"
else
	ok "the final elpis.conf passes elpis -t with no errors"
fi
others=$(diff "$ORIG" "$final" | grep '^[<>]' | sed 's/^[<>] //' |
	grep -vE '^(listen|access-control|dnssec|authoritative-dot|ecs|identity|webgui|webgui-password|licence):')
[ -z "$others" ] && ok "nothing but the managed keys changed" || bad "other lines changed: $others"

echo "== bad values are refused, and nothing changes"
cp "$R/etc/elpis/elpis.conf" "$WORK/before"
expect_no "listen without a port" $CFG set listen 10.0.2.50
expect_no "listen with an IPv6 address outside brackets" $CFG set listen 2001:db8::1@53
expect_no "listen with nothing" $CFG set listen
expect_no "access-control with a bad action" $CFG set access-control '10.0.0.0/8 bogus'
expect_no "access-control without a prefix" $CFG set access-control 'example.com allow'
expect_no "dnssec maybe" $CFG set dnssec maybe
expect_no "a plain-text webgui-password" $CFG set webgui-password secret
expect_no "a key elpis-config does not manage" $CFG set cache-size 2G
expect_no "two values for a single key" $CFG set ecs yes no
cmp -s "$WORK/before" "$R/etc/elpis/elpis.conf" && ok "elpis.conf is unchanged after all that" || bad "a refused change was written"

echo "== network"
IF=$R/etc/network/interfaces
expect_ok "static IPv4 and IPv6" $CFG network --iface eth0 --ipv4 10.0.2.50/24 --gw4 10.0.2.2 --ipv6 2001:db8::53/64 --gw6 2001:db8::1
grep -q '^iface eth0 inet static' "$IF" && grep -q '^  address 10.0.2.50$' "$IF" && grep -q '^  netmask 255.255.255.0$' "$IF" &&
	grep -q '^  gateway 10.0.2.2$' "$IF" && grep -q '^iface eth0 inet6 static' "$IF" && grep -q '^  netmask 64$' "$IF" &&
	ok "interfaces has both stanzas" || bad "interfaces: $(cat "$IF")"
expect_ok "IPv6 back to automatic, IPv4 kept" $CFG network --ipv6 auto
grep -q '^  address 10.0.2.50$' "$IF" && ! grep -q inet6 "$IF" && ok "read back and rewritten" || bad "interfaces: $(cat "$IF")"
expect_ok "IPv4 back to DHCP" $CFG network --ipv4 dhcp
grep -q '^iface eth0 inet dhcp' "$IF" && ok "DHCP" || bad "interfaces: $(cat "$IF")"
expect_no "a bad IPv4 address" $CFG network --ipv4 10.0.2.300/24
expect_no "an IPv4 address without a length" $CFG network --ipv4 10.0.2.50
expect_no "an IPv6 gateway that is IPv4" $CFG network --ipv6 2001:db8::53/64 --gw6 10.0.2.2

echo "== hostname, NTP, root password"
expect_ok "hostname resolver-1" $CFG hostname resolver-1
[ "$(cat "$R/etc/hostname")" = resolver-1 ] && grep -q '^127.0.1.1	resolver-1$' "$R/etc/hosts" && ok "hostname and hosts updated" || bad "hostname: $(cat "$R/etc/hostname")"
expect_no "a hostname with a space" $CFG hostname 'bad name'
expect_no "a hostname ending in -" $CFG hostname bad-
expect_ok "NTP by address" $CFG ntp 162.159.200.1 2606:4700:f1::1
[ "$(grep -c '^server ' "$R/etc/elpis/ntp.conf")" = 2 ] && ok "ntp.conf has two servers" || bad "ntp.conf: $(cat "$R/etc/elpis/ntp.conf")"
expect_no "NTP by name" $CFG ntp time.cloudflare.com
expect_ok "root password from stdin" sh -c "echo 'longenough1' | $CFG root-password"
h=$(awk -F: '$1 == "root" { print $2 }' "$R/etc/shadow")
salt=$(echo "$h" | cut -d'$' -f3)
[ "$(printf 'longenough1\n' | busybox mkpasswd -P 0 -m sha512 -S "$salt")" = "$h" ] && ok "the stored hash matches the password" || bad "shadow: $h"
grep -q '^elpis:\*:' "$R/etc/shadow" && ok "other accounts untouched" || bad "shadow: $(cat "$R/etc/shadow")"
expect_no "a short root password" sh -c "echo short | $CFG root-password"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
