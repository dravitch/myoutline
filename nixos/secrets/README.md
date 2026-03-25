# Secrets — à créer manuellement sur le serveur

Ces fichiers ne sont PAS dans le dépôt git (voir .gitignore).
Ils doivent exister sur le serveur avant le premier `nixos-rebuild switch`.

## Créer les secrets

```bash
# En tant que root sur le serveur cible

mkdir -p /run/secrets
chmod 700 /run/secrets

# 1. Clé secrète Outline (session JWT interne)
openssl rand -hex 32 > /run/secrets/outline-secret-key
chmod 600 /run/secrets/outline-secret-key

# 2. Utils secret Outline
openssl rand -hex 32 > /run/secrets/outline-utils-secret
chmod 600 /run/secrets/outline-utils-secret

# 3. Client secret OIDC (copier depuis l'interface PocketID)
echo -n "LE_SECRET_OIDC_COPIE_DE_POCKETID" > /run/secrets/outline-oidc-secret
chmod 600 /run/secrets/outline-oidc-secret

# 4. Variables sensibles PocketID
cat > /run/secrets/pocketid-env <<EOF
JWT_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 /run/secrets/pocketid-env
```

## Ordre d'initialisation

1. Créer les secrets ci-dessus
2. `nixos-rebuild switch --flake .#outline-server`
3. Attendre que PostgreSQL et Redis soient up
4. Créer le client OIDC dans PocketID :
   - Naviguer sur https://pocketid.lab.local (admin au premier démarrage)
   - Créer un client OIDC :
     - **Name** : Outline
     - **Redirect URI** : `https://outline.lab.local/auth/oidc.callback`
     - **Scopes** : `openid profile email`
   - Copier le **Client ID** et le **Client Secret**
   - Mettre à jour `configuration.nix` avec le Client ID
   - Écrire le Client Secret dans `/run/secrets/outline-oidc-secret`
5. `nixos-rebuild switch --flake .#outline-server`

## Faire confiance au certificat Caddy (sur les clients)

```bash
# Récupérer le certificat CA local de Caddy
curl -sk http://<IP_SERVEUR>:2019/pki/ca/local/certificates

# Sur Linux client : copier dans /usr/local/share/ca-certificates/caddy-local.crt
# puis : update-ca-certificates

# Sur NixOS client :
# security.pki.certificates = [ (builtins.readFile ./caddy-root.crt) ];
```

## À terme : remplacer par sops-nix

Pour chiffrer les secrets dans git :
- https://github.com/Mic92/sops-nix
- Permet de versionner les secrets chiffrés avec age ou GPG
