/*
 * elpis-ipcheck -- the address checks elpis-config needs and shell is bad at.
 *
 *   elpis-ipcheck addr   4|6|any ADDR       ADDR is an address
 *   elpis-ipcheck prefix 4|6|any ADDR/LEN   ADDR/LEN is an address and a
 *                                           prefix length that fits it
 *   elpis-ipcheck family ADDR[/LEN]         print 4 or 6
 *   elpis-ipcheck netmask LEN               print the IPv4 netmask, 0-32
 *
 * Exit status 0 when it holds, 1 when it does not, 2 for bad usage.
 */

#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int family_of(const char *s)
{
	unsigned char buf[16];
	if (inet_pton(AF_INET, s, buf) == 1)
		return 4;
	if (inet_pton(AF_INET6, s, buf) == 1)
		return 6;
	return 0;
}

static int want_matches(const char *want, int fam)
{
	if (!strcmp(want, "any"))
		return fam != 0;
	if (!strcmp(want, "4"))
		return fam == 4;
	if (!strcmp(want, "6"))
		return fam == 6;
	return 0;
}

/* Split "ADDR/LEN"; returns the family, or 0 when it is not one. */
static int split_prefix(const char *s, char *addr, size_t n, long *len)
{
	const char *slash = strchr(s, '/');
	char *end;
	int fam;

	if (!slash || (size_t)(slash - s) >= n || slash[1] == '\0')
		return 0;
	memcpy(addr, s, (size_t)(slash - s));
	addr[slash - s] = '\0';
	fam = family_of(addr);
	*len = strtol(slash + 1, &end, 10);
	if (*end != '\0' || *len < 0 || *len > (fam == 4 ? 32 : 128))
		return 0;
	return fam;
}

int main(int argc, char **argv)
{
	char addr[INET6_ADDRSTRLEN + 1];
	long len;

	if (argc == 4 && !strcmp(argv[1], "addr"))
		return want_matches(argv[2], family_of(argv[3])) ? 0 : 1;

	if (argc == 4 && !strcmp(argv[1], "prefix"))
		return want_matches(argv[2], split_prefix(argv[3], addr, sizeof addr, &len)) ? 0 : 1;

	if (argc == 3 && !strcmp(argv[1], "family")) {
		int fam = strchr(argv[2], '/') ?
			split_prefix(argv[2], addr, sizeof addr, &len) : family_of(argv[2]);
		if (!fam)
			return 1;
		printf("%d\n", fam);
		return 0;
	}

	if (argc == 3 && !strcmp(argv[1], "netmask")) {
		char *end;
		unsigned long mask;
		len = strtol(argv[2], &end, 10);
		if (*end != '\0' || end == argv[2] || len < 0 || len > 32)
			return 1;
		mask = len ? 0xffffffffUL << (32 - len) : 0;
		printf("%lu.%lu.%lu.%lu\n", (mask >> 24) & 255, (mask >> 16) & 255,
		       (mask >> 8) & 255, mask & 255);
		return 0;
	}

	fprintf(stderr,
		"usage: elpis-ipcheck addr 4|6|any ADDR\n"
		"       elpis-ipcheck prefix 4|6|any ADDR/LEN\n"
		"       elpis-ipcheck family ADDR[/LEN]\n"
		"       elpis-ipcheck netmask LEN\n");
	return 2;
}
