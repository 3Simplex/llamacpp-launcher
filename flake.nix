{
  description = "Llamacpp Launcher Perk Card - Full v14 Features";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    llamacpp-flake.url = "path:/home/claytonw/src/flakes/llamacpp-flake";
  };

  outputs = { self, nixpkgs, llamacpp-flake }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      
      launcher = pkgs.writeShellApplication {
        name = "llama-launcher";
        runtimeInputs =[ 
          pkgs.jq 
          pkgs.curl 
          pkgs.procps 
          pkgs.util-linux 
          pkgs.libsecret
          pkgs.bc 
          pkgs.kdePackages.konsole
          pkgs.python312Packages.gguf
          llamacpp-flake.packages.${system}.default
        ];
        text = builtins.readFile ./launcher.sh;
      };

      upgrade = pkgs.writeShellApplication {
        name = "llamacpp-upgrade";
        runtimeInputs = [ pkgs.git pkgs.nix ];
        text = builtins.readFile ./upgrade.sh;
      };

    in {
      packages.${system}.default = pkgs.symlinkJoin {
        name = "llamacpp-toolkit";
        paths = [ launcher upgrade ];
      };
    };
}
