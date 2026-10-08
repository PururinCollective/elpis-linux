################################################################################
#
# elpis-config
#
################################################################################

ELPIS_CONFIG_VERSION = $(shell cat $(BR2_EXTERNAL_ELPIS_PATH)/VERSION)
ELPIS_CONFIG_SITE = $(BR2_EXTERNAL_ELPIS_PATH)/package/elpis-config/src
ELPIS_CONFIG_SITE_METHOD = local
ELPIS_CONFIG_DEPENDENCIES = elpis-resolver

# Installed after dropbear, so that its S50dropbear replaces dropbear's own.
ifeq ($(BR2_PACKAGE_DROPBEAR),y)
ELPIS_CONFIG_DEPENDENCIES += dropbear
endif

define ELPIS_CONFIG_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -std=c99 \
		-D_POSIX_C_SOURCE=200112L -Wall -Wextra \
		-o $(@D)/elpis-ipcheck $(@D)/elpis-ipcheck.c
endef

define ELPIS_CONFIG_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/elpis-config $(TARGET_DIR)/usr/sbin/elpis-config
	$(INSTALL) -D -m 0755 $(@D)/elpis-ipcheck \
		$(TARGET_DIR)/usr/libexec/elpis/elpis-ipcheck
	$(INSTALL) -D -m 0644 $(@D)/ssh.conf $(TARGET_DIR)/etc/elpis/ssh.conf
endef

# SSH is off until elpis-config turns it on, and its host keys live in a real
# /etc/dropbear that elpis-save keeps, not in a link to /var/run.
ifeq ($(BR2_PACKAGE_DROPBEAR),y)
define ELPIS_CONFIG_INSTALL_DROPBEAR
	$(INSTALL) -D -m 0755 $(@D)/S50dropbear $(TARGET_DIR)/etc/init.d/S50dropbear
	if [ -L $(TARGET_DIR)/etc/dropbear ]; then rm -f $(TARGET_DIR)/etc/dropbear; fi
	mkdir -p $(TARGET_DIR)/etc/dropbear
	chmod 0700 $(TARGET_DIR)/etc/dropbear
endef
ELPIS_CONFIG_POST_INSTALL_TARGET_HOOKS += ELPIS_CONFIG_INSTALL_DROPBEAR
endif

$(eval $(generic-package))
