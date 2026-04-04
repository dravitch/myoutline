# /etc/nixos/configuration.nix
{ config, pkgs, lib, ... }:

# ============================================================
#  Variables centralisées — adapter à ton environnement
# ============================================================
let
  serverIp      = "192.168.100.205";
  outlineDomain = "outline.lab.local";
  pocketDomain  = "pocketid.lab.local";

  outlinePort  = 3001;
  pocketIdPort = 8080;
in
{
  # ============================================================
  #  Licences non-libres
  # ============================================================
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "outline" ];

  # ============================================================
  #  Système de base
  # ============================================================
  system.stateVersion = "25.11";
  time.timeZone = "America/Montreal";

  # Boot — Proxmox EFI
  # Si BIOS legacy : boot.loader.grub = { enable = true; device = "/dev/sda"; };
  boot.loader.systemd-boot.enable      = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.grub.enable              = lib.mkForce false;

  # ============================================================
  #  Réseau
  # ============================================================
  networking = {
    hostName    = "outline-server";
    nameservers = [ "192.168.100.1" "1.1.1.1" "8.8.8.8" ];

    hosts = {
      "127.0.0.1"   = [ "localhost" outlineDomain pocketDomain ];
      "${serverIp}" = [ "outline-server" ];
    };

    firewall = {
      enable          = true;
      allowedTCPPorts = [ 22 80 443 ];
    };

    interfaces.ens18.ipv4.addresses = [
      { address = serverIp; prefixLength = 24; }
    ];

    defaultGateway = "192.168.100.1";
  };

  # CORRECTION : options renommées dans nixos-unstable
  # (anciens noms : dnssec, llmnr, fallbackDns — désormais sous settings.Resolve)
  services.resolved = {
    enable = true;
    settings.Resolve = {
      DNSSEC      = "false";
      LLMNR       = "false";
      FallbackDNS = "1.1.1.1 8.8.8.8";
    };
  };

  # /etc est en lecture seule sur NixOS — on crée resolv.conf dans /run
  # via un activation script qui tourne à chaque switch, persistant entre reboots
  # tant que /run/resolv survit (tmpfs vidé au reboot → recréé à l'activation).
  system.activationScripts.resolv-conf = {
    text = ''
      mkdir -p /run/resolv
      printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /run/resolv/resolv.conf
      chmod 644 /run/resolv/resolv.conf
      ln -sf /run/resolv/resolv.conf /etc/resolv.conf
    '';
    # Doit tourner avant que nix essaie de télécharger quoi que ce soit
    deps = [];
  };

  # ============================================================
  #  SSH
  # ============================================================
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  # ============================================================
  #  Utilisateurs
  # ============================================================
  users.users.admin = {
    isNormalUser = true;
    extraGroups  = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK+Aosi3Ftvgu4sf4nBj727iLM5WJC0NrH8YExB/MPJm outline"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICv/97ctyM4Kqe0JyUtSXtStCbZ8zC1PrzLmWseX5qcb pulseos-access"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  # Le module outline crée l'user "outline" — on ajoute juste le groupe redis
  users.users.outline = {
    extraGroups = [ "redis-outline" ];
  };

  environment.systemPackages = with pkgs; [
    vim curl wget htop git openssl jq
  ];

  # ============================================================
  #  PostgreSQL
  # ============================================================
  services.postgresql = {
    enable  = true;
    package = pkgs.postgresql_16;

    ensureDatabases = [ "outline" "pocketid" ];
    ensureUsers = [
      { name = "outline";  ensureDBOwnership = true; }
      { name = "pocketid"; ensureDBOwnership = true; }
    ];

    # PocketID v2 ne supporte pas les unix sockets (nixpkgs #434306)
    authentication = lib.mkAfter ''
      host  pocketid  pocketid  127.0.0.1/32  trust
    '';
  };

  # ============================================================
  #  Redis
  # ============================================================
  services.redis.servers."outline" = {
    enable         = true;
    unixSocket     = "/run/redis-outline/redis.sock";
    unixSocketPerm = 660;
    port           = 0;
  };

  # ============================================================
  #  Outline Wiki
  # ============================================================
  services.outline = {
    enable     = true;
    publicUrl  = "https://${outlineDomain}";
    port       = outlinePort;
    forceHttps = false;

    databaseUrl     = "postgres:///outline?host=/run/postgresql";
    redisUrl        = "redis+socket:///run/redis-outline/redis.sock";

    secretKeyFile   = "/run/secrets/outline-secret-key";
    utilsSecretFile = "/run/secrets/outline-utils-secret";

    storage = {
      storageType  = "local";
      localRootDir = "/var/lib/outline/data";
    };

    oidcAuthentication = {
      authUrl          = "https://${pocketDomain}/authorize";
      tokenUrl         = "https://${pocketDomain}/api/oidc/token";
      userinfoUrl      = "https://${pocketDomain}/api/oidc/userinfo";
      clientId         = "outline";
      clientSecretFile = "/run/secrets/outline-oidc-secret";
      scopes           = [ "openid" "profile" "email" ];
      displayName      = "PocketID";
      usernameClaim    = "email";
    };

    defaultLanguage   = "fr_FR";
    enableUpdateCheck = false;
  };

  # ============================================================
  #  PocketID (provider OIDC)
  # ============================================================
  # CORRECTION : DB_PROVIDER déprécié en v2 → DATABASE_URL directe
  services."pocket-id" = {
    enable = true;

    settings = {
      APP_URL      = "https://${pocketDomain}";
      PORT         = toString pocketIdPort;
      DATABASE_URL = "postgres://pocketid@127.0.0.1:5432/pocketid?sslmode=disable";
    };

    environmentFile = "/run/secrets/pocketid-env";
  };

  # ============================================================
  #  Caddy — reverse proxy TLS interne
  # ============================================================
  # Pour distribuer le CA root Caddy aux clients du réseau :
  #   scp admin@192.168.100.205:/var/lib/caddy/.local/share/caddy/pki/\
  #       authorities/local/root.crt ./caddy-local-ca.crt
  # Puis sur le client NixOS :
  #   security.pki.certificateFiles = [ ./caddy-local-ca.crt ];
  services.caddy = {
    enable = true;

    globalConfig = ''
      admin 127.0.0.1:2019
    '';

    virtualHosts."https://${outlineDomain}" = {
      extraConfig = ''
        tls internal

        reverse_proxy localhost:${toString outlinePort} {
          header_up Host              {host}
          header_up X-Real-IP         {remote_host}
          header_up X-Forwarded-For   {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      '';
    };

    virtualHosts."https://${pocketDomain}" = {
      extraConfig = ''
        tls internal

        reverse_proxy localhost:${toString pocketIdPort} {
          header_up Host              {host}
          header_up X-Real-IP         {remote_host}
          header_up X-Forwarded-For   {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      '';
    };
  };
}
