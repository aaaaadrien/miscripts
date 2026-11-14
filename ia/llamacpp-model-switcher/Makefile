# Makefile d'installation pour llamacpp-model-switcher.
#
# Usage :
#   sudo make install     # installe tout et démarre le service
#   sudo make acl         # ré-applique juste l'ACL (si le fichier .service
#                          # cible a été regénéré/réécrit entre temps)
#   sudo make uninstall   # retire le binaire, l'unité et la règle sudoers
#
# Variables surchargeables, ex: sudo make install LLAMACPP_SERVICE_FILE=/etc/systemd/system/autre.service

PREFIX               ?= /opt/llamacpp-model-switcher
BINDIR               := $(PREFIX)/bin
RUN_USER             ?= llamacpp
RUN_GROUP            ?= llamacpp
SYSTEMD_DIR          ?= /etc/systemd/system
SUDOERS_DIR          ?= /etc/sudoers.d
LLAMACPP_SERVICE_FILE ?= /etc/systemd/system/llamacpp.service

APP_NAME       := llamacpp-model-switcher
BIN_SRC        := $(APP_NAME)
SERVICE_SRC    := $(APP_NAME).service
SUDOERS_SRC    := $(APP_NAME).sudo

.PHONY: all install uninstall check-root user bindir sudoers acl systemd-unit enable disable restart status logs

all: install

check-root:
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "Erreur : ce Makefile doit être lancé en root (sudo make install)." >&2; \
		exit 1; \
	fi

install: check-root user bindir sudoers acl systemd-unit enable
	@echo ""
	@echo "Installation terminée. Interface web sur http://<ip-machine>:8089"
	@echo "Vérifiez avec : sudo make status"

user: check-root
	@if id $(RUN_USER) >/dev/null 2>&1; then \
		echo "Utilisateur $(RUN_USER) déjà présent."; \
	else \
		useradd --system --no-create-home --shell /usr/sbin/nologin $(RUN_USER); \
		echo "Utilisateur système $(RUN_USER) créé."; \
	fi

bindir: check-root
	install -d -m 0755 $(BINDIR)
	install -m 0755 $(BIN_SRC) $(BINDIR)/$(APP_NAME)

sudoers: check-root
	@command -v visudo >/dev/null 2>&1 || { echo "visudo introuvable." >&2; exit 1; }
	visudo -c -f $(SUDOERS_SRC)
	install -m 0440 -o root -g root $(SUDOERS_SRC) $(SUDOERS_DIR)/$(APP_NAME)
	@echo "Règle sudoers installée dans $(SUDOERS_DIR)/$(APP_NAME)"

acl: check-root
	@command -v setfacl >/dev/null 2>&1 || { \
		echo "setfacl introuvable : installez le paquet 'acl' (apt install acl)." >&2; exit 1; }
	@if [ ! -f "$(LLAMACPP_SERVICE_FILE)" ]; then \
		echo "Erreur : $(LLAMACPP_SERVICE_FILE) introuvable, créez-le d'abord." >&2; exit 1; \
	fi
	setfacl -m u:$(RUN_USER):rw- $(LLAMACPP_SERVICE_FILE)
	@echo "ACL appliquée : $(RUN_USER) peut lire/écrire $(LLAMACPP_SERVICE_FILE)"
	@getfacl --omit-header $(LLAMACPP_SERVICE_FILE) 2>/dev/null || true

systemd-unit: check-root
	install -m 0644 -o root -g root $(SERVICE_SRC) $(SYSTEMD_DIR)/$(SERVICE_SRC)
	systemctl daemon-reload

enable: check-root
	systemctl enable --now $(APP_NAME).service

disable: check-root
	-systemctl disable --now $(APP_NAME).service

restart: check-root
	systemctl restart $(APP_NAME).service

status:
	systemctl status $(APP_NAME).service --no-pager

logs:
	journalctl -u $(APP_NAME).service -f

uninstall: check-root disable
	rm -f $(SYSTEMD_DIR)/$(SERVICE_SRC)
	rm -f $(SUDOERS_DIR)/$(APP_NAME)
	rm -rf $(BINDIR)
	systemctl daemon-reload
	@echo ""
	@echo "Désinstallé. Non supprimés automatiquement (au cas où) :"
	@echo "  - l'ACL sur $(LLAMACPP_SERVICE_FILE)       -> setfacl -x u:$(RUN_USER) $(LLAMACPP_SERVICE_FILE)"
	@echo "  - l'utilisateur système $(RUN_USER)         -> userdel $(RUN_USER)"
	@echo "  - le dossier $(PREFIX) lui-même"
