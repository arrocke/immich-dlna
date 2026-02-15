{
  description = "Zig dev shell";

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
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          zig.packages.${system}."0.15.2"
          zls.packages.${system}.zls
          pkgs.libupnp
          pkgs.pkg-config
          pkgs.opencode
        ];
      };
    };
}
