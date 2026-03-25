#!/usr/bin/env bash
# install.sh — Bootstrap NixOS depuis une image minimale
# À exécuter en root sur la VM fraîchement installée
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && error "Exécuter en tant que root"

# ============================================================
# Étape 1 : Activer les flakes (si pas déjà fait)
# ============================================================
info "Activation des flakes Nix..."
mkdir -p /etc/nix
if ! grep -q "experimental-features" /etc/nix/nix.conf 2>/dev/null; then
    echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf
    info "Flakes activés"
else
    info "Flakes déjà activés"
fi

# ============================================================
# Étape 2 : Copier la configuration
# ============================================================
NIXOS_CONFIG_DIR="/etc/nixos"
info "Copie de la configuration dans ${NIXOS_CONFIG_DIR}..."

# Conserver le hardware-configuration.nix généré par nixos-generate-config
if [ ! -f "${NIXOS_CONFIG_DIR}/hardware-configuration.nix" ]; then
    warn "hardware-configuration.nix absent, génération..."
    nixos-generate-config --no-filesystems --root /
fi

# Copier les fichiers de config (sans écraser hardware-configuration.nix)
cp flake.nix        "${NIXOS_CONFIG_DIR}/"
cp configuration.nix "${NIXOS_CONFIG_DIR}/"
cp .gitignore       "${NIXOS_CONFIG_DIR}/"
mkdir -p "${NIXOS_CONFIG_DIR}/secrets"
cp secrets/README.md "${NIXOS_CONFIG_DIR}/secrets/"

info "Configuration copiée"

# ============================================================
# Étape 3 : Créer les secrets
# ============================================================
info "Création des secrets..."
mkdir -p /run/secrets
chmod 700 /run/secrets

if [ ! -f /run/secrets/outline-secret-key ]; then
    openssl rand -hex 32 > /run/secrets/outline-secret-key
    chmod 600 /run/secrets/outline-secret-key
    info "outline-secret-key généré"
fi

if [ ! -f /run/secrets/outline-utils-secret ]; then
    openssl rand -hex 32 > /run/secrets/outline-utils-secret
    chmod 600 /run/secrets/outline-utils-secret
    info "outline-utils-secret généré"
fi

if [ ! -f /run/secrets/pocketid-env ]; then
    echo "JWT_SECRET=$(openssl rand -hex 32)" > /run/secrets/pocketid-env
    chmod 600 /run/secrets/pocketid-env
    info "pocketid-env généré"
fi

if [ ! -f /run/secrets/outline-oidc-secret ]; then
    warn "outline-oidc-secret absent !"
    warn "Tu devras le créer APRÈS avoir configuré PocketID :"
    warn "  echo -n '<SECRET_POCKETID>' > /run/secrets/outline-oidc-secret"
    warn "  chmod 600 /run/secrets/outline-oidc-secret"
    warn "  nixos-rebuild switch --flake /etc/nixos#outline-server"
    # Placeholder pour permettre le premier build
    echo -n "PLACEHOLDER_REMPLACER_APRES_POCKETID" > /run/secrets/outline-oidc-secret
    chmod 600 /run/secrets/outline-oidc-secret
fi

# ============================================================
# Étape 4 : Premier nixos-rebuild
# ============================================================
info "Premier nixos-rebuild switch (peut prendre quelques minutes)..."
nixos-rebuild switch --flake "${NIXOS_CONFIG_DIR}#outline-server"

# ============================================================
# Résumé
# ============================================================
echo ""
echo "=========================================="
echo " Installation terminée !"
echo "=========================================="
echo ""
echo "Services démarrés :"
echo "  systemctl status outline"
echo "  systemctl status pocket-id"
echo "  systemctl status caddy"
echo "  systemctl status postgresql"
echo "  systemctl status redis-outline"
echo ""
echo "ÉTAPES SUIVANTES :"
echo ""
echo "1. Récupère le cert CA de Caddy pour tes clients :"
echo "   curl -sk http://127.0.0.1:2019/pki/ca/local/certificates"
echo ""
echo "2. Accède à PocketID (premier accès = création du compte admin) :"
echo "   https://pocketid.lab.local"
echo ""
echo "3. Dans PocketID, crée le client OIDC Outline :"
echo "   Redirect URI : https://outline.lab.local/auth/oidc.callback"
echo "   Scopes       : openid profile email"
echo ""
echo "4. Mets à jour le secret OIDC et relance :"
echo "   echo -n '<SECRET>' > /run/secrets/outline-oidc-secret"
echo "   nixos-rebuild switch --flake /etc/nixos#outline-server"
echo ""
echo "5. Accède à Outline :"
echo "   https://outline.lab.local"
echo ""
