{ config, pkgs, lib, ... }:

# ============================================================
#  Variables centralisées — adapter à ton environnement
# ============================================================
let
  serverIp      = "192.168.100.205";
  outlineDomain = "outline.lab.local";
  pocketDomain  = "pocketid.lab.local";

  # Ports internes (pas exposés directement, Caddy proxifie)
  outlinePort   = 3001;
  pocketIdPort  = 8080;
in
{
  # ============================================================
  #  Licences non-libres
  # ============================================================
  # Outline est sous licence BSL 1.1 (non-libre au sens Nix).
  # On l'autorise explicitement plutôt qu'un allowUnfree global.
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "outline" ];

  # ============================================================
  #  Système de base
  # ============================================================
  system.stateVersion = "24.11";
  time.timeZone = "Europe/Paris";

  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";   # adapter selon ton disque VM
  };

  networking = {
    hostName = "outline-server";
    # DNS interne pour résoudre *.lab.local depuis la machine elle-même
    hosts = {
      "127.0.0.1" = [ outlineDomain pocketDomain ];
    };
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 80 443 ];
    };
  };

  # SSH pour l'administration
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    # Remplacer par ta clé publique
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA... ton-cle-publique"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  # Packages de base utiles
  environment.systemPackages = with pkgs; [
    vim curl wget htop git
  ];

  # ============================================================
  #  PostgreSQL
  # ============================================================
  # Utilise des unix sockets par défaut — plus rapide, pas de réseau
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;

    ensureDatabases = [ "outline" "pocketid" ];
    ensureUsers = [
      {
        name = "outline";
        ensureDBOwnership = true;
      }
      {
        name = "pocketid";
        ensureDBOwnership = true;
      }
    ];

    # PocketID a un bug connu avec les unix sockets (nixpkgs #434306)
    # On lui ouvre une connexion TCP localhost uniquement
    authentication = lib.mkAfter ''
      host  pocketid  pocketid  127.0.0.1/32  trust
    '';
    settings = {
      listen_addresses = "127.0.0.1";   # TCP uniquement sur loopback
    };
  };

  # ============================================================
  #  Redis (unix socket pour Outline)
  # ============================================================
  services.redis.servers."outline" = {
    enable = true;
    unixSocket = "/run/redis-outline/redis.sock";
    unixSocketPerm = 660;
    # Pas de port TCP exposé, uniquement unix socket
    port = 0;
  };

  # L'utilisateur outline doit pouvoir lire le socket Redis
  users.users.outline.extraGroups = [ "redis-outline" ];

  # ============================================================
  #  Secrets (via fichiers, jamais dans le nix store)
  # ============================================================
  # Ces fichiers doivent exister sur le système AVANT nixos-rebuild switch
  # Voir secrets/README.md pour les créer
  #
  #   /run/secrets/outline-secret-key     → openssl rand -hex 32
  #   /run/secrets/outline-utils-secret   → openssl rand -hex 32
  #   /run/secrets/outline-oidc-secret    → client secret PocketID
  #   /run/secrets/pocketid-jwt-secret    → openssl rand -hex 32
  #
  # Recommandé à terme : sops-nix ou agenix pour chiffrer les secrets
  # dans le dépôt git.

  # ============================================================
  #  Outline Wiki
  # ============================================================
  services.outline = {
    enable = true;
    publicUrl = "https://${outlineDomain}";
    port = outlinePort;
    forceHttps = false;   # Caddy gère le TLS en amont

    # PostgreSQL via unix socket (performant, pas de mot de passe requis)
    databaseUrl = "postgres:///outline?host=/run/postgresql";

    # Redis via unix socket
    redisUrl = "redis+socket:///run/redis-outline/redis.sock";

    # Secrets dans des fichiers (pas dans le nix store)
    secretKeyFile  = "/run/secrets/outline-secret-key";
    utilsSecretFile = "/run/secrets/outline-utils-secret";

    # Stockage local des fichiers
    storage = {
      storageType = "local";
      localRootDir = "/var/lib/outline/data";
    };

    # Authentification OIDC via PocketID
    oidcAuthentication = {
      authUrl     = "https://${pocketDomain}/authorize";
      tokenUrl    = "https://${pocketDomain}/api/oidc/token";
      userinfoUrl = "https://${pocketDomain}/api/oidc/userinfo";
      clientId    = "outline";
      # Le secret OIDC lu depuis un fichier, jamais en clair dans la config
      clientSecretFile = "/run/secrets/outline-oidc-secret";
      scopes      = [ "openid" "profile" "email" ];
      displayName = "PocketID";
      usernameClaim = "email";
    };

    defaultLanguage   = "fr_FR";
    enableUpdateCheck = false;
  };

  # ============================================================
  #  PocketID (provider OIDC)
  # ============================================================
  services.pocket-id = {
    enable = true;

    settings = {
      # URL publique de PocketID (utilisée dans les redirections OIDC)
      APP_URL = "https://${pocketDomain}";

      # PostgreSQL via TCP localhost (contournement bug unix socket)
      DB_PROVIDER = "postgres";
      DB_CONNECTION_STRING = "host=127.0.0.1 port=5432 user=pocketid dbname=pocketid sslmode=disable";

      # Port d'écoute interne
      PORT = toString pocketIdPort;

      # Secret JWT (lu depuis un fichier via EnvironmentFile dans le module)
      # Note : selon la version du module, utiliser soit settings soit
      # un EnvironmentFile séparé (voir ci-dessous si nécessaire)
    };

    # Fichier contenant les variables sensibles (JWT_SECRET, etc.)
    # Le module pocket-id supporte un environmentFile
    environmentFile = "/run/secrets/pocketid-env";
  };

  # ============================================================
  #  Caddy — reverse proxy avec TLS interne
  # ============================================================
  # "tls internal" = Caddy génère sa propre CA locale et signe les certs.
  # Il faut faire confiance à la CA Caddy sur les clients :
  #   curl http://<serveur>:2019/pki/ca/local/certificates → télécharge le cert
  #   Ou : /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
  services.caddy = {
    enable = true;

    # Expose le port d'administration Caddy sur loopback uniquement
    globalConfig = ''
      admin 127.0.0.1:2019
    '';

    virtualHosts."https://${outlineDomain}" = {
      extraConfig = ''
        tls internal

        reverse_proxy localhost:${toString outlinePort} {
          header_up Host {host}
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      '';
    };

    virtualHosts."https://${pocketDomain}" = {
      extraConfig = ''
        tls internal

        reverse_proxy localhost:${toString pocketIdPort} {
          header_up Host {host}
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      '';
    };
  };

  # Ouvrir le port Caddy admin sur loopback (déjà filtré par firewall)
  # Pour récupérer le certificat CA local :
  # curl -s http://127.0.0.1:2019/pki/ca/local/certificates | head -1
}
