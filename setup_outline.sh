#!/bin/bash
# setup_outline.sh
# Script d'installation Outline avec PocketID OAuth2
# Corrigé : heredoc, DNS, TLS (Caddy), callback URI
set -e

# ==========================================
# Variables de configuration
# ==========================================
SERVER_IP="192.168.100.205"        # IP du serveur Outline
OUTLINE_DOMAIN="outline.lab.local"
POCKETID_DOMAIN="pocketid.lab.local"
OUTLINE_BASE="/mnt/outline"
OUTLINE_DATA="${OUTLINE_BASE}/data"
OUTLINE_PGDATA="${OUTLINE_BASE}/pgdata"
OUTLINE_CERTS="${OUTLINE_BASE}/certs"
COMPOSE_FILE="${OUTLINE_BASE}/podman-compose.yml"
ENV_FILE="${OUTLINE_BASE}/outline.env"
CADDY_FILE="${OUTLINE_BASE}/Caddyfile"

# ==========================================
# Couleurs
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ==========================================
# Vérifications préalables
# ==========================================
[ "$EUID" -ne 0 ] && error "Ce script doit être exécuté en tant que root"

for cmd in openssl podman podman-compose; do
    command -v "$cmd" &>/dev/null || error "Commande manquante : $cmd"
done

# ==========================================
# Étape 1 : Répertoires
# ==========================================
info "Création des répertoires..."
mkdir -p "${OUTLINE_DATA}" "${OUTLINE_PGDATA}" "${OUTLINE_CERTS}"
chown -R 1000:1000 "${OUTLINE_DATA}"
chmod 755 "${OUTLINE_DATA}"
info "Répertoires créés"

# ==========================================
# Étape 2 : Certificat TLS auto-signé
# ==========================================
info "Génération du certificat TLS auto-signé..."
if [ ! -f "${OUTLINE_CERTS}/outline.crt" ]; then
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "${OUTLINE_CERTS}/outline.key" \
        -out "${OUTLINE_CERTS}/outline.crt" \
        -subj "/CN=${OUTLINE_DOMAIN}" \
        -addext "subjectAltName=DNS:${OUTLINE_DOMAIN},IP:${SERVER_IP}"
    chmod 600 "${OUTLINE_CERTS}/outline.key"
    info "Certificat généré : ${OUTLINE_CERTS}/outline.crt"
else
    info "Certificat existant conservé"
fi

# ==========================================
# Étape 3 : Secrets
# ==========================================
info "Génération des secrets..."
SECRET_KEY=$(openssl rand -hex 32)
UTILS_SECRET=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
info "Secrets générés"

# ==========================================
# Étape 4 : outline.env
# ==========================================
info "Création de outline.env..."
# NOTE: heredoc sans guillemets = variables expandées correctement
cat > "${ENV_FILE}" <<EOF
# outline.env — Généré le $(date)

# ==========================================
# Configuration de base
# ==========================================
NODE_ENV=production
APP_NAME=Outline
DEFAULT_LANGUAGE=fr_FR

# ==========================================
# Secrets (générés automatiquement)
# ==========================================
SECRET_KEY=${SECRET_KEY}
UTILS_SECRET=${UTILS_SECRET}

# ==========================================
# URLs et réseau
# ==========================================
URL=https://${OUTLINE_DOMAIN}
PORT=3001
# Outline écoute en HTTP, Caddy gère le TLS en amont
FORCE_HTTPS=false

# ==========================================
# Base de données PostgreSQL
# ==========================================
DATABASE_URL=postgres://outline:${POSTGRES_PASSWORD}@postgres:5432/outline
PGSSLMODE=disable

# ==========================================
# Redis
# ==========================================
REDIS_URL=redis://redis:6379

# ==========================================
# OAuth2 - PocketID
# URI de callback à enregistrer dans PocketID :
#   https://${OUTLINE_DOMAIN}/auth/oidc.callback
# ==========================================
OIDC_CLIENT_ID=REMPLACER_PAR_CLIENT_ID
OIDC_CLIENT_SECRET=REMPLACER_PAR_CLIENT_SECRET
OIDC_AUTH_URI=https://${POCKETID_DOMAIN}/authorize
OIDC_TOKEN_URI=https://${POCKETID_DOMAIN}/api/oidc/token
OIDC_USERINFO_URI=https://${POCKETID_DOMAIN}/api/oidc/userinfo
# email est plus fiable que preferred_username pour l'unicité
OIDC_USERNAME_CLAIM=email
OIDC_DISPLAY_NAME=PocketID
OIDC_SCOPES=openid profile email

# ==========================================
# Stockage de fichiers
# ==========================================
FILE_STORAGE=local
FILE_STORAGE_LOCAL_ROOT_DIR=/var/lib/outline/data
FILE_STORAGE_UPLOAD_MAX_SIZE=26214400
FILE_STORAGE_IMPORT_MAX_SIZE=1000000
FILE_STORAGE_WORKSPACE_IMPORT_MAX_SIZE=1000000
MAXIMUM_IMPORT_SIZE=5120000

# ==========================================
# Email (désactivé)
# ==========================================
EMAIL_ENABLED=false

# ==========================================
# Divers
# ==========================================
ENABLE_UPDATES=false
WEB_CONCURRENCY=1
# DEBUG=http,server:*
EOF
chmod 600 "${ENV_FILE}"
info "outline.env créé"

# ==========================================
# Étape 5 : .env pour podman-compose (PostgreSQL)
# ==========================================
# BUG CORRIGÉ : le fichier .env est lu par podman-compose pour substituer
# ${POSTGRES_PASSWORD} dans le compose, mais si le heredoc compose
# utilise <<'EOF', les variables ne sont PAS expandées à la génération.
# Solution : on hard-code le mot de passe dans le compose ET dans .env.
info "Création du .env PostgreSQL..."
cat > "${OUTLINE_BASE}/.env" <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
EOF
chmod 600 "${OUTLINE_BASE}/.env"

# ==========================================
# Étape 6 : Caddyfile (reverse proxy TLS)
# ==========================================
info "Création du Caddyfile..."
cat > "${CADDY_FILE}" <<EOF
{
    # Désactiver l'ACME auto (TLS local avec cert auto-signé)
    auto_https off
}

https://${OUTLINE_DOMAIN}:443 {
    tls /certs/outline.crt /certs/outline.key

    reverse_proxy outline:3001 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
EOF
info "Caddyfile créé"

# ==========================================
# Étape 7 : podman-compose.yml
# ==========================================
info "Création du podman-compose.yml..."
# BUG CORRIGÉ : <<'EOF' empêchait l'expansion de ${POSTGRES_PASSWORD}.
# On utilise <<EOF (sans guillemets) pour permettre l'expansion,
# et on escape les $ qui ne doivent PAS être expandés (aucun ici).
cat > "${COMPOSE_FILE}" <<EOF
# podman-compose.yml pour Outline — Généré le $(date)
services:

  caddy:
    image: docker.io/library/caddy:2-alpine
    container_name: outline-caddy
    restart: unless-stopped
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - "${CADDY_FILE}:/etc/caddy/Caddyfile:ro"
      - "${OUTLINE_CERTS}:/certs:ro"
    networks:
      - outline-net
    depends_on:
      - outline

  outline:
    image: docker.io/outlinewiki/outline:latest
    container_name: outline
    hostname: outline
    restart: unless-stopped
    env_file:
      - outline.env
    volumes:
      - "${OUTLINE_DATA}:/var/lib/outline/data"
    # Pas de ports exposés directement, Caddy gère le TLS
    networks:
      - outline-net
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  postgres:
    image: docker.io/library/postgres:14
    container_name: outline-postgres
    hostname: postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: outline
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: outline
    volumes:
      - "${OUTLINE_PGDATA}:/var/lib/postgresql/data"
    networks:
      - outline-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U outline"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  redis:
    image: docker.io/library/redis:7-alpine
    container_name: outline-redis
    hostname: redis
    restart: unless-stopped
    networks:
      - outline-net
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s

networks:
  outline-net:
    driver: bridge
EOF
info "podman-compose.yml créé"

# ==========================================
# Étape 8 : DNS local
# ==========================================
info "Configuration du DNS local..."
if ! grep -q "${OUTLINE_DOMAIN}" /etc/hosts; then
    echo "${SERVER_IP} ${OUTLINE_DOMAIN}" >> /etc/hosts
    info "Ajouté : ${SERVER_IP} ${OUTLINE_DOMAIN}"
else
    info "DNS déjà présent"
fi
# PocketID doit aussi être résolvable depuis les conteneurs
if ! grep -q "${POCKETID_DOMAIN}" /etc/hosts; then
    warn "Attention : ${POCKETID_DOMAIN} n'est pas dans /etc/hosts"
    warn "Ajoute manuellement : <IP_POCKETID> ${POCKETID_DOMAIN}"
fi

# ==========================================
# Étape 9 : Réseau Podman
# ==========================================
info "Vérification du réseau Podman..."
if ! podman network exists outline-net 2>/dev/null; then
    podman network create outline-net
    info "Réseau outline-net créé"
else
    info "Réseau outline-net existant"
fi

# ==========================================
# Résumé
# ==========================================
echo ""
echo "=========================================="
echo " Installation terminée"
echo "=========================================="
echo ""
echo "IMPORTANT — Avant de démarrer :"
echo ""
echo "1. Édite ${ENV_FILE} et remplace :"
echo "     OIDC_CLIENT_ID=REMPLACER_PAR_CLIENT_ID"
echo "     OIDC_CLIENT_SECRET=REMPLACER_PAR_CLIENT_SECRET"
echo ""
echo "2. Dans PocketID, enregistre ce client OIDC avec :"
echo "     Redirect URI : https://${OUTLINE_DOMAIN}/auth/oidc.callback"
echo "     Scopes requis : openid profile email"
echo ""
echo "3. Copie le certificat auto-signé sur les machines clientes :"
echo "     ${OUTLINE_CERTS}/outline.crt"
echo ""
echo "Démarrage :"
echo "  cd ${OUTLINE_BASE}"
echo "  podman-compose up -d postgres redis"
echo "  podman-compose run --rm outline yarn db:migrate"
echo "  podman-compose up -d"
echo ""
echo "Logs :"
echo "  podman logs -f outline"
echo "  podman logs -f outline-caddy"
echo ""
echo "Accès : https://${OUTLINE_DOMAIN}"
echo ""
