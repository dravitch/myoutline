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
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;

    ensureDatabases = [ "outline" "pocketid" ];
    ensureUsers = [
      { name = "outline";  ensureDBOwnership = true; }
      { name = "pocketid"; ensureDBOwnership = true; }
    ];

    # TCP localhost pour outline (container) et pocketid (bug unix socket)
    authentication = lib.mkAfter ''
      host  outline   outline   127.0.0.1/32  trust
      host  pocketid  pocketid  127.0.0.1/32  trust
    '';
  };

  # ============================================================
  #  Redis — TCP + unix socket (container outline accède via TCP)
  # ============================================================
  services.redis.servers."outline" = {
    enable = true;
    unixSocket     = "/run/redis-outline/redis.sock";
    unixSocketPerm = 660;
    port = 6379;
    bind = "127.0.0.1";
  };

  # ============================================================
  #  Répertoire de données Outline
  #  UID 1001 = utilisateur dans l'image Docker officielle outlinewiki/outline
  # ============================================================
  systemd.tmpfiles.rules = [
    "d /var/lib/outline/data 0750 root root -"
    "Z /var/lib/outline/data 0750 1001 1001 -"
  ];

  # ============================================================
  #  Outline — image Docker officielle (évite la compilation depuis les sources)
  #
  #  Secrets dans /run/secrets/outline-env (jamais dans le nix store) :
  #    SECRET_KEY=<openssl rand -hex 32>
  #    UTILS_SECRET=<openssl rand -hex 32>
  #    OIDC_CLIENT_SECRET=<secret depuis PocketID>
  # ============================================================
  virtualisation.oci-containers = {
    backend = "podman";

    containers.outline = {
      image     = "docker.io/outlinewiki/outline:latest";
      autoStart = true;

      # Partage le réseau hôte → accès direct à postgresql/redis sur 127.0.0.1
      extraOptions = [ "--network=host" ];

      # Variables sensibles dans un fichier (SECRET_KEY, UTILS_SECRET, OIDC_CLIENT_SECRET)
      environmentFiles = [ "/run/secrets/outline-env" ];

      environment = {
        DATABASE_URL             = "postgres://outline@127.0.0.1/outline";
        REDIS_URL                = "redis://127.0.0.1:6379";
        URL                      = "https://${outlineDomain}";
        PORT                     = toString outlinePort;
        FORCE_HTTPS              = "false";
        OIDC_CLIENT_ID           = "outline";
        OIDC_AUTH_URI            = "https://${pocketDomain}/authorize";
        OIDC_TOKEN_URI           = "https://${pocketDomain}/api/oidc/token";
        OIDC_USERINFO_URI        = "https://${pocketDomain}/api/oidc/userinfo";
        OIDC_DISPLAY_NAME        = "PocketID";
        OIDC_SCOPES              = "openid profile email";
        OIDC_USERNAME_CLAIM      = "email";
        DEFAULT_LANGUAGE         = "fr_FR";
        ENABLE_UPDATES           = "false";
        FILE_STORAGE             = "local";
        FILE_STORAGE_LOCAL_ROOT_DIR = "/var/lib/outline/data";
        NODE_ENV                 = "production";
      };

      volumes = [ "/var/lib/outline/data:/var/lib/outline/data" ];
    };
  };

  # ============================================================
  #  PocketID (provider OIDC)
  # ============================================================
  services.pocket-id = {
    enable = true;

    settings = {
      APP_URL              = "https://${pocketDomain}";
      DB_PROVIDER          = "postgres";
      DB_CONNECTION_STRING = "host=127.0.0.1 port=5432 user=pocketid dbname=pocketid sslmode=disable";
      PORT                 = toString pocketIdPort;
    };

    # Fichier contenant JWT_SECRET
    environmentFile = "/run/secrets/pocketid-env";
  };

  # ============================================================
  #  Caddy — reverse proxy avec TLS interne
  # ============================================================
  services.caddy = {
    enable = true;

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
}
