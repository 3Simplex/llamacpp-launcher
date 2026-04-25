{
  description = "Llamacpp Launcher Perk Card - Full v14 Features";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      launcher = pkgs.writeShellApplication {
        name = "llamacpp-launcher";
        checkPhase = "";
        runtimeInputs = [
          pkgs.jq
          pkgs.curl
          pkgs.procps
          pkgs.util-linux
          pkgs.libsecret
          pkgs.bc
          pkgs.kdePackages.konsole
          pkgs.python312Packages.gguf
        ];
        text = builtins.readFile ./launcher.sh;
      };

      store = pkgs.writeShellApplication {
        name = "llamacpp-store";
        checkPhase = "";
        runtimeInputs = [
          pkgs.git
          pkgs.nix
          pkgs.jq
          pkgs.curl
        ];
        text = builtins.readFile ./store.sh;
      };

    in {
      packages.${system}.default = pkgs.symlinkJoin {
        name = "llamacpp-launcher";
        paths = [ launcher store ];
      };

      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/llamacpp-launcher";
      };

      apps.${system}.store = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/llamacpp-store";
      };
    };
}
