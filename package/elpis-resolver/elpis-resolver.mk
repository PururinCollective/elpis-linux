################################################################################
#
# elpis-resolver
#
################################################################################

ELPIS_RESOLVER_VERSION = 2.4.5
ELPIS_RESOLVER_SITE = $(call github,PururinCollective,elpis-resolver,$(ELPIS_RESOLVER_VERSION))
ELPIS_RESOLVER_LICENSE = GPL-2.0
ELPIS_RESOLVER_LICENSE_FILES = LICENSE

# The resolver stamps where it was built from into its identity probe and
# status page, and its Makefile asks git for that.  Buildroot builds it from a
# tarball inside this repository, where git would find elpis-linux's history
# and report it as the resolver's.  So it is given here instead: the release
# tag for a release build, or, for a local checkout (OVERRIDE_SRCDIR), what
# that checkout's own Makefile would have said.
ELPIS_RESOLVER_GITREV = $(if $(ELPIS_RESOLVER_OVERRIDE_SRCDIR),$(shell \
	$(BR2_EXTERNAL_ELPIS_PATH)/package/elpis-resolver/gitrev.sh \
	$(ELPIS_RESOLVER_OVERRIDE_SRCDIR)),$(ELPIS_RESOLVER_VERSION))

ELPIS_RESOLVER_LICENCE_ISSUER = $(call qstrip,$(BR2_PACKAGE_ELPIS_RESOLVER_LICENCE_ISSUER))

ELPIS_RESOLVER_MAKE_OPTS = \
	CC="$(TARGET_CC)" \
	UNAME_M="$(BR2_ARCH)" \
	SYSCONFDIR=/etc \
	GITREV="$(ELPIS_RESOLVER_GITREV)" \
	$(if $(ELPIS_RESOLVER_LICENCE_ISSUER),LICENCE_ISSUER="$(ELPIS_RESOLVER_LICENCE_ISSUER)")

define ELPIS_RESOLVER_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) $(ELPIS_RESOLVER_MAKE_OPTS)
endef

# elpis.conf.upstream is the resolver's own reference config; the board's
# post-build script derives the appliance's defaults from it.
define ELPIS_RESOLVER_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/bin/elpis $(TARGET_DIR)/usr/sbin/elpis
	$(INSTALL) -D -m 0644 $(@D)/elpis.conf \
		$(TARGET_DIR)/usr/share/elpis/elpis.conf.upstream
	$(INSTALL) -D -m 0755 $(@D)/tools/conf-merge.sh \
		$(TARGET_DIR)/usr/libexec/elpis/conf-merge.sh
	$(INSTALL) -D -m 0644 $(@D)/LICENSE \
		$(TARGET_DIR)/usr/share/licenses/elpis-resolver/LICENSE
	printf 'RESOLVER_VERSION=%s\nRESOLVER_BUILD=%s\n' \
		"$$(sed -n 's/^VERSION *:= *//p' $(@D)/Makefile)" \
		"$(ELPIS_RESOLVER_GITREV)" \
		> $(TARGET_DIR)/usr/share/elpis/resolver-version
endef

define ELPIS_RESOLVER_USERS
	elpis -1 elpis -1 * - - - Elpis resolver
endef

$(eval $(generic-package))
