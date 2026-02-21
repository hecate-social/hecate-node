{
  description = "Hecate Node — NixOS configurations for bootable USB/ISO/SD images";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }:
    let
      # Helper to make a NixOS configuration for a given role and hardware
      mkSystem = { role, hardware ? "generic-x86", system ? "x86_64-linux", extraModules ? [ ] }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            (./configurations + "/${role}.nix")
            (./hardware + "/${hardware}.nix")
          ] ++ extraModules;
        };

      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      # ── NixOS Configurations ───────────────────────────────────────────
      # Use: nixos-rebuild switch --flake .#standalone
      nixosConfigurations = {
        standalone = mkSystem {
          role = "standalone";
          hardware = "generic-x86";
        };

        cluster = mkSystem {
          role = "cluster";
          hardware = "generic-x86";
        };

        inference = mkSystem {
          role = "inference";
          hardware = "generic-x86";
        };

        workstation = mkSystem {
          role = "workstation";
          hardware = "generic-x86";
        };

        # ── Beam cluster nodes (specific hardware) ─────────────────────
        beam00 = mkSystem {
          role = "cluster";
          hardware = "beam-node";
          extraModules = [{
            networking.hostName = "beam00";
            services.hecate.cluster = {
              cookie = "hecate_cluster_secret";
              peers = [ "beam01.lab" "beam02.lab" "beam03.lab" ];
            };
          }];
        };

        beam01 = mkSystem {
          role = "cluster";
          hardware = "beam-node";
          extraModules = [{
            networking.hostName = "beam01";
            services.hecate.cluster = {
              cookie = "hecate_cluster_secret";
              peers = [ "beam00.lab" "beam02.lab" "beam03.lab" ];
            };
            fileSystems."/bulk1" = {
              device = "/dev/disk/by-label/bulk1";
              fsType = "xfs";
              options = [ "nofail" "x-systemd.device-timeout=10" ];
            };
          }];
        };

        beam02 = mkSystem {
          role = "cluster";
          hardware = "beam-node";
          extraModules = [{
            networking.hostName = "beam02";
            services.hecate.cluster = {
              cookie = "hecate_cluster_secret";
              peers = [ "beam00.lab" "beam01.lab" "beam03.lab" ];
            };
            fileSystems."/bulk1" = {
              device = "/dev/disk/by-label/bulk1";
              fsType = "xfs";
              options = [ "nofail" "x-systemd.device-timeout=10" ];
            };
          }];
        };

        beam03 = mkSystem {
          role = "cluster";
          hardware = "beam-node";
          extraModules = [{
            networking.hostName = "beam03";
            services.hecate.cluster = {
              cookie = "hecate_cluster_secret";
              peers = [ "beam00.lab" "beam01.lab" "beam02.lab" ];
            };
            fileSystems."/bulk1" = {
              device = "/dev/disk/by-label/bulk1";
              fsType = "xfs";
              options = [ "nofail" "x-systemd.device-timeout=10" ];
            };
          }];
        };
      };

      # ── Packages ───────────────────────────────────────────────────────
      packages.x86_64-linux = {
        # Single unified ISO — firstboot wizard handles role selection
        # Use: nix build .#iso
        iso = let
          isoSystem = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              ./configurations/standalone.nix
              ./hardware/generic-x86.nix
              "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
              {
                isoImage.isoBaseName = "hecate-os";
                isoImage.volumeID = "HECATE_OS";
                boot.loader.efi.canTouchEfiVariables = nixpkgs.lib.mkForce false;

                # ISO ships with everything; firstboot wizard configures the role
                services.hecate.firstboot.enable = nixpkgs.lib.mkForce true;
                services.hecate.ollama.enable = nixpkgs.lib.mkForce true;
              }
            ];
          };
        in isoSystem.config.system.build.isoImage;

        default = self.packages.x86_64-linux.iso;

        hecate-reconciler = (pkgsFor "x86_64-linux").callPackage ./packages/hecate-reconciler.nix { };
        hecate-cli = (pkgsFor "x86_64-linux").callPackage ./packages/hecate-cli.nix { };
      };

      # ── Checks (NixOS VM tests) ────────────────────────────────────────
      # Use: nix flake check   or   nix build .#checks.x86_64-linux.boot-test
      checks.x86_64-linux =
        let
          pkgs = pkgsFor "x86_64-linux";
        in
        {
          boot-test = import ./tests/boot-test.nix { inherit pkgs; };
          plugin-test = import ./tests/plugin-test.nix { inherit pkgs; };
          firstboot-test = import ./tests/firstboot-test.nix { inherit pkgs; };
        };
    };
}
