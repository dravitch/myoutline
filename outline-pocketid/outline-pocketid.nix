# /etc/nixos/modules/outline-pocketid.nix
#
# Ce module gère tout ce que les modules NixOS officiels ne font pas :
#   1. Permissions des répertoires de données
#   2. Génération automatique de TOUS les secrets au premier boot
#   3. Enregistrement idempotent du client OIDC "outline" dans PocketID
#
# Zéro intervention manuelle après nixos-rebuild switch.
#
{ config, pkgs, lib, ... }:

let
  secretsDir = "/run/secrets";

  # Le module NixOS pocket-id crée l'utilisateur "pocket-id" (avec tiret),
  # pas "pocketid". On utilise ce nom partout pour être cohérent.
  pocketUser = "pocket-id";
  pocketDir  = "/var/lib/pocket-id";

  outlineUser    = "outline";
  outlineDataDir = "/var/lib/outline/data";

  psql = "${config.services.postgresql.package}/bin/psql";

in
{
  # ============================================================
  # 1. RÉPERTOIRES & PERMISSIONS
  # ============================================================
  # CORRECTION : pocket-id a besoin de 0755 (pas 0750) car le service
  # tourne avec PrivateUsers=true — l'UID dans le namespace privé doit
  # pouvoir entrer dans le répertoire.
  systemd.tmpfiles.rules = [
    "d ${pocketDir}      0755 ${pocketUser} ${pocketUser} -"
    "d ${outlineDataDir} 0750 ${outlineUser} ${outlineUser} -"
    "d ${secretsDir}     0700 root root -"
  ];

  # ============================================================
  # 2. GÉNÉRATION AUTOMATIQUE DES SECRETS
  # ============================================================
  # Tourne en root, génère tous les secrets si absents.
  # /run est un tmpfs → recréé à chaque boot, les secrets aussi.
  # Les services applicatifs dépendent de ce service.
  #
  # Secrets produits :
  #   outline-secret-key    → SECRET_KEY d'Outline        (owner: outline)
  #   outline-utils-secret  → UTILS_SECRET d'Outline      (owner: outline)
  #   outline-oidc-secret   → secret OIDC partagé         (owner: root, readable by postgres via script)
  #   pocketid-env          → JWT_SECRET pour PocketID    (owner: pocket-id)

  systemd.services.generate-secrets = {
    description     = "Génère les secrets Outline & PocketID si absents";
    wantedBy        = [ "multi-user.target" ];
    before          = [ "outline.service" "pocket-id.service" ];
    after           = [ "systemd-tmpfiles-setup.service" ];
    requires        = [ "systemd-tmpfiles-setup.service" ];

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      User            = "root";

      ExecStart = pkgs.writeShellScript "generate-secrets.sh" ''
        set -euo pipefail

        SECRETS="${secretsDir}"
        mkdir -p "$SECRETS"

        # Génère un secret hex-32, règle le owner
        gen_secret() {
          local file="$1"
          local owner="$2"
          if [ ! -s "$file" ]; then
            echo "[secrets] Génération de $file"
            ${pkgs.openssl}/bin/openssl rand -hex 32 > "$file"
            chown "$owner:$owner" "$file"
            chmod 600 "$file"
          fi
        }

        # Secrets Outline — lisibles par l'utilisateur outline
        gen_secret "$SECRETS/outline-secret-key"   "${outlineUser}"
        gen_secret "$SECRETS/outline-utils-secret" "${outlineUser}"

        # Secret OIDC — root only, lu par root dans pocketid-register-client
        gen_secret "$SECRETS/outline-oidc-secret" "root"

        # Env PocketID — lisible par pocket-id
        if [ ! -s "$SECRETS/pocketid-env" ]; then
          echo "[secrets] Génération de $SECRETS/pocketid-env"
          JWT_SECRET=$(${pkgs.openssl}/bin/openssl rand -hex 32)
          printf 'JWT_SECRET=%s\n' "$JWT_SECRET" > "$SECRETS/pocketid-env"
          chown "${pocketUser}:${pocketUser}" "$SECRETS/pocketid-env"
          chmod 600 "$SECRETS/pocketid-env"
        fi

        echo "[secrets] Tous les secrets sont en place."
      '';
    };
  };

  # ============================================================
  # 3. ENREGISTREMENT DU CLIENT OIDC "outline" DANS POCKETID
  # ============================================================
  # CORRECTION : le script tourne en deux étapes :
  #   - ExecStartPre (root) : lit le secret et l'écrit dans un fichier
  #     temporaire lisible par postgres
  #   - ExecStart (postgres) : exécute le SQL avec le secret lu du fichier temp
  #
  # Cela évite d'accorder à postgres l'accès à /run/secrets/.

  systemd.services.pocketid-register-client = {
    description = "Enregistre le client OIDC 'outline' dans PocketID";
    wantedBy    = [ "multi-user.target" ];
    after       = [
      "generate-secrets.service"
      "postgresql.service"
      "pocket-id.service"
    ];
    requires    = [
      "generate-secrets.service"
      "postgresql.service"
      "pocket-id.service"
    ];

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;

      # Étape 1 (root) : copie le secret dans un fichier temporaire accessible
      # par l'utilisateur postgres
      ExecStartPre = pkgs.writeShellScript "pocketid-copy-secret.sh" ''
        set -euo pipefail
        SECRET=$(cat "${secretsDir}/outline-oidc-secret")
        printf '%s' "$SECRET" > /run/pocketid-oidc-secret.tmp
        chown postgres:postgres /run/pocketid-oidc-secret.tmp
        chmod 400 /run/pocketid-oidc-secret.tmp
        echo "[pocketid] Secret OIDC copié pour postgres."
      '';

      # Étape 2 (postgres) : INSERT idempotent dans la DB PocketID
      ExecStart = pkgs.writeShellScript "pocketid-register-client.sh" ''
        set -euo pipefail

        OIDC_SECRET=$(cat /run/pocketid-oidc-secret.tmp)

        ${psql} -h 127.0.0.1 -U pocketid -d pocketid <<SQL
INSERT INTO oidc_clients (
  id,
  name,
  secret,
  redirect_uris,
  allowed_user_groups,
  is_public,
  pkce_enabled,
  created_at,
  updated_at
)
VALUES (
  'outline',
  'Outline Wiki',
  '$OIDC_SECRET',
  '{"https://outline.lab.local/auth/oidc.callback"}',
  '{}',
  false,
  false,
  NOW(),
  NOW()
)
ON CONFLICT (id) DO UPDATE
  SET secret        = EXCLUDED.secret,
      redirect_uris = EXCLUDED.redirect_uris,
      updated_at    = NOW();
SQL

        echo "[pocketid] Client OIDC 'outline' enregistré."
        rm -f /run/pocketid-oidc-secret.tmp
      '';

      User = "postgres";

      # ExecStartPre tourne en root (override pour cette étape uniquement)
      PermissionsStartOnly = true;
    };
  };

  # ============================================================
  # 4. ORDRE DE DÉMARRAGE
  # ============================================================
  # Outline démarre seulement après que le client OIDC est enregistré
  systemd.services.outline = {
    after   = [ "pocketid-register-client.service" ];
    requires = [ "pocketid-register-client.service" ];
  };
}
