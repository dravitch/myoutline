#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — Outline + PocketID stack
# Version : 1.0.0
# Usage   : ./healthcheck.sh [--json] [--strict]
#
# Codes de retour :
#   0  → tout est sain
#   1  → au moins un service dégradé (warn)
#   2  → au moins un service critique en échec
#
# Options :
#   --json    sortie JSON (pour intégration CI/monitoring)
#   --strict  traite les warnings comme des erreurs (exit 2 si warn)
# =============================================================================
set -euo pipefail

HEALTHCHECK_VERSION="1.0.0"
SCRIPT_COMMIT=$(cd /etc/nixos 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# --- Couleurs (désactivées si pas de terminal) --------------------------------
if [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; BLUE=''; BOLD=''; RESET=''
fi

# --- Options ------------------------------------------------------------------
JSON_OUTPUT=false
STRICT=false
for arg in "$@"; do
  case "$arg" in
    --json)   JSON_OUTPUT=true ;;
    --strict) STRICT=true ;;
  esac
done

# --- État global --------------------------------------------------------------
EXIT_CODE=0
declare -A RESULTS   # nom → "ok|warn|fail"
declare -A MESSAGES  # nom → message lisible

record() {
  local name="$1" status="$2" msg="$3"
  RESULTS["$name"]="$status"
  MESSAGES["$name"]="$msg"
  case "$status" in
    fail) EXIT_CODE=2 ;;
    warn) [ "$EXIT_CODE" -lt 2 ] && EXIT_CODE=1
          $STRICT && EXIT_CODE=2 ;;
  esac
}

# --- Helpers ------------------------------------------------------------------
check_service() {
  local name="$1" unit="$2"
  local state
  state=$(systemctl is-active "$unit" 2>/dev/null || true)
  case "$state" in
    active)   record "$name" "ok"   "$unit est actif" ;;
    inactive) record "$name" "warn" "$unit est inactif (inactive)" ;;
    failed)   record "$name" "fail" "$unit a échoué (failed)" ;;
    *)        record "$name" "warn" "$unit état inconnu: $state" ;;
  esac
}

check_http() {
  local name="$1" url="$2" expected_code="${3:-200}"
  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
  if [ "$code" = "$expected_code" ]; then
    record "$name" "ok" "HTTP $code ← $url"
  elif [ "$code" = "000" ]; then
    record "$name" "fail" "Aucune réponse (timeout/refused) ← $url"
  else
    record "$name" "warn" "HTTP $code attendu $expected_code ← $url"
  fi
}

check_port() {
  local name="$1" host="$2" port="$3"
  if ${pkgs.netcat}/bin/nc -z -w2 "$host" "$port" 2>/dev/null ||
     bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
    record "$name" "ok" "Port $port ouvert sur $host"
  else
    record "$name" "fail" "Port $port fermé ou inaccessible sur $host"
  fi
}

check_file() {
  local name="$1" path="$2"
  if [ -s "$path" ]; then
    record "$name" "ok" "$path existe et non-vide"
  elif [ -e "$path" ]; then
    record "$name" "warn" "$path existe mais est vide"
  else
    record "$name" "fail" "$path absent"
  fi
}

check_postgres_db() {
  local name="$1" db="$2" user="$3"
  local result
  result=$(sudo -u postgres psql -tAc "SELECT 1" "$db" 2>/dev/null || echo "")
  if [ "$result" = "1" ]; then
    record "$name" "ok" "DB $db accessible (user $user)"
  else
    record "$name" "fail" "DB $db inaccessible"
  fi
}

check_postgres_table() {
  local name="$1" db="$2" table="$3"
  local result
  result=$(sudo -u postgres psql -tAc \
    "SELECT to_regclass('public.${table}');" "$db" 2>/dev/null || echo "")
  if [ -n "$result" ] && [ "$result" != "" ] && [ "$result" != "NULL" ]; then
    record "$name" "ok" "Table $table présente dans $db"
  else
    record "$name" "warn" "Table $table absente de $db (migrations peut-être pas encore tournées)"
  fi
}

# =============================================================================
# VÉRIFICATIONS
# =============================================================================

# --- Système ------------------------------------------------------------------
NIXOS_VERSION=$(nixos-version 2>/dev/null || echo "unknown")
CURRENT_SYSTEM=$(readlink -f /run/current-system 2>/dev/null || echo "unknown")
UPTIME=$(uptime -p 2>/dev/null || echo "unknown")

# DNS
if ping -c1 -W2 cache.nixos.org &>/dev/null; then
  record "dns_external" "ok" "Résolution DNS externe fonctionnelle"
else
  record "dns_external" "fail" "Résolution DNS externe échoue — nixos-rebuild impossible"
fi

if [ -f /etc/resolv.conf ]; then
  record "resolv_conf" "ok" "/etc/resolv.conf présent"
else
  record "resolv_conf" "fail" "/etc/resolv.conf absent — DNS cassé"
fi

# --- Services systemd ---------------------------------------------------------
check_service "systemd_resolved"  "systemd-resolved.service"
check_service "postgresql"        "postgresql.service"
check_service "redis_outline"     "redis-outline.service"
check_service "pocket_id"         "pocket-id.service"
check_service "outline"           "outline.service"
check_service "caddy"             "caddy.service"

# Services oneshot (doivent être "active (exited)")
check_service "generate_secrets"          "generate-secrets.service"
check_service "pocketid_register_client"  "pocketid-register-client.service"

# --- Secrets ------------------------------------------------------------------
check_file "secret_outline_key"    "/run/secrets/outline-secret-key"
check_file "secret_outline_utils"  "/run/secrets/outline-utils-secret"
check_file "secret_outline_oidc"   "/run/secrets/outline-oidc-secret"
check_file "secret_pocketid_env"   "/run/secrets/pocketid-env"

# --- PostgreSQL ---------------------------------------------------------------
check_postgres_db "pg_db_outline"  "outline"  "outline"
check_postgres_db "pg_db_pocketid" "pocketid" "pocketid"
check_postgres_table "pg_table_oidc_clients" "pocketid" "oidc_clients"
check_postgres_table "pg_table_outline_users" "outline" "users"

# Vérifier que le client OIDC "outline" est bien enregistré
OIDC_CLIENT=$(sudo -u postgres psql -tAc \
  "SELECT id FROM oidc_clients WHERE id='outline';" pocketid 2>/dev/null || echo "")
if [ "$OIDC_CLIENT" = "outline" ]; then
  record "oidc_client_outline" "ok" "Client OIDC 'outline' enregistré dans PocketID"
else
  record "oidc_client_outline" "warn" "Client OIDC 'outline' absent de pocketid.oidc_clients"
fi

# --- Répertoires de données ---------------------------------------------------
check_file "dir_outline_data"   "/var/lib/outline/data"
check_file "dir_pocketid_data"  "/var/lib/pocket-id"

# --- Ports locaux -------------------------------------------------------------
check_port "port_outline"   "127.0.0.1" "3001"
check_port "port_pocketid"  "127.0.0.1" "8080"

# --- HTTP (TLS interne Caddy, -k pour skip cert) ------------------------------
check_http "http_pocketid_login"  "https://pocketid.lab.local/login"  "200"
check_http "http_outline_health"  "https://outline.lab.local/_health"  "200"

# =============================================================================
# SORTIE
# =============================================================================

if $JSON_OUTPUT; then
  # --- JSON -------------------------------------------------------------------
  echo "{"
  echo "  \"version\": \"$HEALTHCHECK_VERSION\","
  echo "  \"commit\": \"$SCRIPT_COMMIT\","
  echo "  \"nixos_version\": \"$NIXOS_VERSION\","
  echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"exit_code\": $EXIT_CODE,"
  echo "  \"checks\": {"
  first=true
  for key in "${!RESULTS[@]}"; do
    $first || echo ","
    first=false
    printf '    "%s": {"status": "%s", "message": "%s"}' \
      "$key" "${RESULTS[$key]}" "${MESSAGES[$key]}"
  done
  echo ""
  echo "  }"
  echo "}"
else
  # --- Texte ------------------------------------------------------------------
  echo ""
  echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}  Healthcheck — Outline + PocketID  v${HEALTHCHECK_VERSION}${RESET}"
  echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"
  echo -e "  NixOS    : $NIXOS_VERSION"
  echo -e "  Commit   : $SCRIPT_COMMIT"
  echo -e "  Uptime   : $UPTIME"
  echo -e "  Date     : $(date)"
  echo ""

  # Regrouper par catégorie pour la lisibilité
  declare -A CATEGORIES=(
    ["DNS & réseau"]="dns_external resolv_conf"
    ["Services systemd"]="systemd_resolved postgresql redis_outline pocket_id outline caddy"
    ["Services oneshot"]="generate_secrets pocketid_register_client"
    ["Secrets"]="secret_outline_key secret_outline_utils secret_outline_oidc secret_pocketid_env"
    ["PostgreSQL"]="pg_db_outline pg_db_pocketid pg_table_oidc_clients pg_table_outline_users oidc_client_outline"
    ["Données"]="dir_outline_data dir_pocketid_data"
    ["Ports"]="port_outline port_pocketid"
    ["HTTP"]="http_pocketid_login http_outline_health"
  )

  for category in "DNS & réseau" "Services systemd" "Services oneshot" \
                  "Secrets" "PostgreSQL" "Données" "Ports" "HTTP"; do
    echo -e "${BLUE}── $category${RESET}"
    for key in ${CATEGORIES[$category]}; do
      status="${RESULTS[$key]:-unknown}"
      msg="${MESSAGES[$key]:-non vérifié}"
      case "$status" in
        ok)   echo -e "  ${GREEN}✔${RESET}  $key : $msg" ;;
        warn) echo -e "  ${YELLOW}⚠${RESET}  $key : $msg" ;;
        fail) echo -e "  ${RED}✘${RESET}  $key : $msg" ;;
        *)    echo -e "  ${YELLOW}?${RESET}  $key : $msg" ;;
      esac
    done
    echo ""
  done

  echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"
  case "$EXIT_CODE" in
    0) echo -e "${GREEN}${BOLD}  ✔  TOUT EST SAIN  (exit 0)${RESET}" ;;
    1) echo -e "${YELLOW}${BOLD}  ⚠  DÉGRADÉ — warnings présents  (exit 1)${RESET}" ;;
    2) echo -e "${RED}${BOLD}  ✘  CRITIQUE — au moins un service en échec  (exit 2)${RESET}" ;;
  esac
  echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"
  echo ""
fi

exit "$EXIT_CODE"
