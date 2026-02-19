{
  description = "DLNA server for Immich";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    zig.url = "github:mitchellh/zig-overlay";
    zig.inputs.nixpkgs.follows = "nixpkgs";
    zls.url = "github:zigtools/zls/0.15.1";
    zls.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, zig, zls, ... }: 
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      zigPkg = zig.packages.${system}."0.15.2";
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          zigPkg
          zls.packages.${system}.zls
          pkgs.libupnp
          pkgs.pkg-config
          pkgs.opencode
        ];
      };

      packages.${system}.immich-dlna = pkgs.stdenv.mkDerivation rec {
        pname = "immich-dlna";
        version = "0.1.0";

        src = ./src;

        nativeBuildInputs = [ zigPkg pkgs.pkg-config ];
        buildInputs = [ pkgs.libupnp ];

        buildPhase = ''
          zig build install -Drelease-safe -Dprod --prefix $out
        '';

        meta = with pkgs.lib; {
          description = "DLNA server for your Immich albums";
          license = licenses.mit;
          maintainers = [ { github = "arrocke"; } ];
        };
      };

      defaultPackage.${system} = self.packages.${system}.immich-dlna;

      nixosModules.default = { config, lib, pkgs, ... }:
      let
        cfg = config.services.immich-dlna;
      in {
        options = with lib; {
          services.immich-dlna = {
            enable = mkEnableOption "Enable the DLNA server for Immich";
            immichApiKeyFile = mkOption {
              type = types.path;
              description = "The path to a file that contains the API key for your Immich API";
            };
            immichUrl = mkOption {
              type = types.str;
              default = "http://localhost:2283";
              description = "The URL where your Immich server is located";
            };
            immichDirectory = mkOption {
              type = types.str;
              default = "/var/lib/immich";
              description = "The file path where your Immich server stores files";
            };
          };
        };

        config = lib.mkIf (cfg.enable && config.services.immich.enable) {
          systemd.services.immich-dlna = {
            description = "Immich DLNA Server";
            wantedBy = [ "multi-user.target" ];

            after = [ "immich-server.service" ];
            partOf = [ "immich-server.service" ];
            requires = [ "immich-server.service" ];

            serviceConfig = {
              User = "immich";
              Group = "immich";
              ExecStart = "${self.packages.${pkgs.system}.immich-dlna}/bin/immich-dlna";

              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              NoNewPrivileges = true;
              ReadWritePaths = [ cfg.immichDirectory ];

              Restart = "on-failure";
              RestartSec = 5;

              EnvironmentFile = [
                cfg.immichApiKeyFile 
              ];
              Environment = [
                "IMMICH_URL=${cfg.immichUrl}"
              ];
            };
          };
        };
      };
    };
}
