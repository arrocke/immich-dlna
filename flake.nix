{
  description = "Immich DLNA - Sync Immich albums to DLNA-accessible directories";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    {
      nixosModules.default = { config, lib, pkgs, ... }: 
        let
          cfg = config.services.immich-dlna;
          
          # Build the package using the system's pkgs
          immich-dlna = pkgs.writeScriptBin "immich-dlna" ''
            #!${pkgs.bash}/bin/bash
            export PATH=${pkgs.lib.makeBinPath [
              pkgs.jq
              pkgs.curl
              pkgs.coreutils
              pkgs.gnused
              pkgs.gnugrep
              pkgs.findutils
            ]}:$PATH
            exec ${pkgs.bash}/bin/bash ${./sync-immich-albums.sh} "$@"
          '';
        in
        {
          options.services.immich-dlna = {
            enable = lib.mkEnableOption "Immich DLNA sync service";

            package = lib.mkOption {
              type = lib.types.package;
              default = immich-dlna;
              defaultText = lib.literalExpression "pkgs.writeScriptBin (from flake)";
              description = "Package providing the immich-dlna script";
            };

            immich = {
              apiKeyFile = lib.mkOption {
                type = lib.types.path;
                description = "File containing IMMICH_API_KEY";
                example = "/run/secrets/immich-api-key";
              };

              host = lib.mkOption {
                type = lib.types.str;
                default = "localhost";
                description = "Immich server host";
                example = "immich.example.com";
              };

              port = lib.mkOption {
                type = lib.types.port;
                default = 2283;
                description = "Immich server port";
              };
            };

            albums = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "List of album IDs to sync";
              example = [ "album-id-1" "album-id-2" ];
            };

            dlnaDirectory = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/immich-dlna";
              description = "Directory where DLNA album folders will be created";
            };

            interval = lib.mkOption {
              type = lib.types.str;
              default = "hourly";
              description = "How often to sync albums (systemd timer format)";
              example = "daily";
            };
          };

          config = lib.mkIf cfg.enable {
            systemd.services.immich-dlna = {
              description = "Immich DLNA album sync";
              after = [ "network.target" ];
              
              serviceConfig = {
                Type = "oneshot";
                User = "immich";
                Group = "immich";

                # Load API key securely
                EnvironmentFile = cfg.immich.apiKeyFile;

                Environment = [
                  "IMMICH_URL=http://${cfg.immich.host}:${toString cfg.immich.port}"
                ];

                ExecStart = ''
                  ${cfg.package}/bin/immich-dlna \
                    --albums ${lib.concatStringsSep "," cfg.albums} \
                    --root ${cfg.dlnaDirectory}
                '';

                # Security hardening
                NoNewPrivileges = true;
                PrivateTmp = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                ReadWritePaths = [ cfg.dlnaDirectory ];
              };
            };

            systemd.timers.immich-dlna = {
              description = "Timer for Immich DLNA album sync";
              wantedBy = [ "timers.target" ];

              timerConfig = {
                OnCalendar = cfg.interval;
                Persistent = true;
                RandomizedDelaySec = "5m";
              };
            };

            # Create the immich user if it doesn't exist
            users.users.immich = lib.mkIf (!config.users.users ? immich) {
              isSystemUser = true;
              group = "immich";
              description = "Immich DLNA service user";
            };

            users.groups.immich = lib.mkIf (!config.users.groups ? immich) {};

            # Ensure the DLNA directory exists
            systemd.tmpfiles.rules = [
              "d ${cfg.dlnaDirectory} 0755 immich immich -"
            ];
          };
        };
    };
}
