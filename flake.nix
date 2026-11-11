{
  description = "HortusFox dev environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        php = pkgs.php83.withExtensions ({ enabled, all }:
          enabled ++ (with all; [
            pdo_mysql
            mbstring
            exif
            pcntl
            bcmath
            intl
            zip
            gd
          ]));
      in
      {
        packages = {
          hortusfox-web = pkgs.callPackage ./package.nix { };
          default = pkgs.callPackage ./package.nix { };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            php
            pkgs.php83Packages.composer
            pkgs.nodejs
            pkgs.mariadb
            pkgs.just
            pkgs.nix-output-monitor
          ];

          shellHook = ''
            echo "HortusFox dev shell"
            echo "  php:      $(php --version | head -n1)"
            echo "  composer: $(composer --version)"
            echo "  node:     $(node --version)"
            echo "  npm:      $(npm --version)"
            echo
            echo "First time setup:"
            echo "  composer install"
            echo "  npm install"
            echo "  cp .env.example .env   # then edit DB_* settings"
            echo "  npm run build          # or: npm run watch"
          '';
        };

        # `nix flake check` builds the package to catch breakage early, plus
        # boots both proxy-backend VM tests.
        checks = {
          build = pkgs.callPackage ./package.nix { };

          vm-test = import ./tests/vm-test.nix {
            inherit pkgs;
            nixosModule = self.nixosModules.default;
            proxyServer = "nginx";
          };

          vm-test-caddy = import ./tests/vm-test.nix {
            inherit pkgs;
            nixosModule = self.nixosModules.default;
            proxyServer = "caddy";
          };
        };
      }) // {
        # Not per-system: an overlay is keyed by name, not by system.
        overlays.default = final: prev: { hortusfox-web = final.callPackage ./package.nix { }; };

        # Not per-system: a module is keyed by name, not by system.
        nixosModules.default = import ./nixos-module;

        # Throwaway VM for manual testing (`just build-vm` / `just boot-vm`).
        # Not per-system: nixosConfigurations is keyed by config name, not system.
        nixosConfigurations.test = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./tests
            {
              # Throwaway VM, never upgraded in place -- tracks the flake's
              # own nixpkgs channel rather than a hand-pinned string that
              # could drift from it.
              system.stateVersion = nixpkgs.lib.trivial.release;
            }
          ];
        };
      };
}
