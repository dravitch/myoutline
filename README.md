# Outline + PocketID sur NixOS

Stack wiki auto-hébergée, 100% native NixOS, sans Docker ni Podman.

## Architecture

```
Internet / LAN
      │
   [Caddy]  ← TLS interne (CA locale auto-générée)
   /     \
[Outline] [PocketID]
   │            │
[Redis]   [PostgreSQL]
(unix socket)  (unix socket / TCP loopback)
```

| Composant  | Module NixOS              | Note |
|------------|---------------------------|------|
| Outline    | `services.outline`        | BSL 1.1, allowUnfree requis |
| PocketID   | `services.pocket-id`      | nixpkgs-unstable |
| PostgreSQL | `services.postgresql`     | unix socket pour Outline, TCP loopback pour PocketID |
| Redis      | `services.redis.servers`  | unix socket |
| Caddy      | `services.caddy`          | `tls internal` — CA locale |

## Prérequis

- NixOS (image minimale récente)
- `experimental-features = nix-command flakes` dans `/etc/nix/nix.conf`
- Accès root

## Installation

```bash
# 1. Cloner le dépôt sur le serveur cible
git clone <repo> && cd myoutline/nixos

# 2. Adapter la configuration à ton environnement
#    Éditer les variables en haut de configuration.nix :
#      serverIp, outlineDomain, pocketDomain
#    Remplacer la clé SSH (users.users.admin.openssh.authorizedKeys)
#    Vérifier le disque de boot (boot.loader.grub.device)

# 3. Lancer l'installation
sudo ./install.sh
```

Le script :
1. Active les flakes si nécessaire
2. Copie la config dans `/etc/nixos/`
3. Génère les secrets (`/run/secrets/`)
4. Lance `nixos-rebuild switch`

## Initialisation de PocketID (à faire une seule fois)

1. Récupère le certificat CA de Caddy et fais-lui confiance sur tes clients :
   ```bash
   curl -sk http://<IP_SERVEUR>:2019/pki/ca/local/certificates > caddy-root.crt
   # Linux : copier dans /usr/local/share/ca-certificates/ puis update-ca-certificates
   # NixOS client : security.pki.certificateFiles = [ ./caddy-root.crt ];
   ```

2. Accède à PocketID (premier accès = création du compte admin) :
   ```
   https://pocketid.lab.local
   ```

3. Crée le client OIDC pour Outline :
   - **Name** : Outline
   - **Redirect URI** : `https://outline.lab.local/auth/oidc.callback`
   - **Scopes** : `openid profile email`
   - Note le **Client ID** et le **Client Secret**

4. Mets à jour le secret OIDC sur le serveur :
   ```bash
   echo -n '<CLIENT_SECRET>' > /run/secrets/outline-oidc-secret
   chmod 600 /run/secrets/outline-oidc-secret
   nixos-rebuild switch --flake /etc/nixos#outline-server
   ```

5. Mets à jour le Client ID dans `configuration.nix` :
   ```nix
   oidcAuthentication.clientId = "<CLIENT_ID>";
   ```

## Gestion des secrets

Les secrets vivent dans `/run/secrets/` (tmpfs, perdus au reboot).

| Fichier | Contenu |
|---------|---------|
| `outline-secret-key` | Clé JWT session Outline (32 bytes hex) |
| `outline-utils-secret` | Utils secret Outline (32 bytes hex) |
| `outline-oidc-secret` | Client secret OIDC PocketID |
| `pocketid-env` | `JWT_SECRET=...` pour PocketID |

> **Note** : `/run/secrets/` est un tmpfs — les secrets sont régénérés
> au reboot **sauf** `outline-oidc-secret` que tu copies depuis PocketID.
> Pour persister, place les fichiers dans `/var/lib/secrets/` et adapte
> les chemins dans `configuration.nix`.

### Évolution recommandée : sops-nix

Pour versionner les secrets chiffrés dans git :
```bash
nix-shell -p sops age
# Voir https://github.com/Mic92/sops-nix
```

## Commandes utiles

```bash
# État des services
systemctl status outline pocket-id caddy postgresql redis-outline

# Logs
journalctl -u outline -f
journalctl -u pocket-id -f
journalctl -u caddy -f

# Rebuild après modification de configuration.nix
nixos-rebuild switch --flake /etc/nixos#outline-server

# Rebuild avec trace d'erreur complète
nixos-rebuild switch --flake /etc/nixos#outline-server --show-trace
```

## Structure du dépôt

```
nixos/
├── flake.nix           # Entrée du flake, pointe sur nixpkgs-unstable
├── configuration.nix   # Configuration principale (tous les services)
├── install.sh          # Script de bootstrap sur VM fraîche
├── .gitignore
└── secrets/
    └── README.md       # Instructions de création des secrets
```

## Problèmes connus

| Problème | Cause | Solution |
|----------|-------|----------|
| `outline` refusé (unfree) | Licence BSL 1.1 | `nixpkgs.config.allowUnfreePredicate` dans configuration.nix ✓ |
| PocketID ne se connecte pas à PostgreSQL via unix socket | Bug nixpkgs #434306 | PostgreSQL écoute aussi en TCP loopback pour PocketID ✓ |
| `tls internal` non reconnu par les clients | CA Caddy non importée | Récupérer `/pki/ca/local/certificates` depuis l'API Caddy |
