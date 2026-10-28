{
  description = "A NixOS flake for multiple hosts";

  inputs = {
    # Default to the nixos-unstable branch
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # Latest stable branch of nixpkgs, used for version rollback
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-26.05";
    # Pinned nixpkgs for jdk24 (removed from nixpkgs 2025-10-04 after Oracle EOL)
    nixpkgs-jdk24.url = "github:nixos/nixpkgs/bce5fe2bb998488d8e7e7856315f90496723793c";
    # FROZEN pin for the whole Android toolchain (studio + SDK/NDK/emulator
    # zips, ~5 GiB of fetchurl). androidenv re-pins Google's zip versions on
    # every nixpkgs change, so a moving branch input redownloads everything
    # at each `nix flake update`. Bump deliberately (like nixpkgs-jdk24):
    # update the rev below, rebuild, let the zips re-fetch once.
    # Current rev = nixos-26.05 @ 1e8bc658 (2026-09-21), i.e. what
    # pkgs-stable resolved to when this pin was added.
    nixpkgs-android.url = "github:nixos/nixpkgs/1e8bc658fc985ef27ccd66d107d767b32bb7ef98";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # niri: scrollable-tiling Wayland compositor + Nix-native config
    # https://github.com/sodiboo/niri-flake
    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # noctalia v5: Quickshell-successor desktop shell/bar
    # NOTE: intentionally NOT following nixpkgs so the noctalia.cachix.org
    # binary cache stays usable (it builds against its own unstable pin).
    # https://github.com/noctalia-dev/noctalia
    noctalia.url = "github:noctalia-dev/noctalia";
    nix-vscode-extensions = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # agenix: age-encrypted secrets, decrypted at activation into /run/agenix
    # (system) and $XDG_RUNTIME_DIR/agenix (home-manager).
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Ovis (herdr-web-ui): browser/phone client for herdr. Pinned to a release
    # tag (upstream main can be ahead of the latest release). Update = bump
    # the tag, `nix flake update herdr-web-ui`, then just switch.
    herdr-web-ui = {
      url = "github:devswha/herdr-web-ui/v0.4.12";
      flake = false;
    };
    # herdr-sidebar (alexarthurs): VS Code-style sidebar (explorer + source
    # control) for herdr, pinned to a release tag whose x86_64-linux-musl
    # binary the overlay below fetches. Update = bump the tag, the release
    # URL/hash in the overlay, then `nix flake update herdr-sidebar`.
    herdr-sidebar = {
      url = "github:alexarthurs/herdr-sidebar/v0.15.1";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-stable,
    nixpkgs-android,
    nixpkgs-jdk24,
    home-manager,
    ...
  } @ inputs: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    pkgs-stable = import nixpkgs-stable {
      inherit system;
      config.allowUnfree = true;
      config.android_sdk.accept_license = true;
    };
    pkgs-android = import nixpkgs-android {
      inherit system;
      config.allowUnfree = true;
      config.android_sdk.accept_license = true;
    };
    pkgs-jdk24 = import nixpkgs-jdk24 {
      inherit system;
    };

    # herdr-sidebar (alexarthurs): assemble the plugin tree (manifest + scripts
    # from the flake-pinned checkout) with the official x86_64-linux-musl
    # release binary (SHA-256 from the release's SHA256SUMS asset) at the
    # target/release/ path its herdr-plugin.toml pane/action commands expect.
    herdr-sidebar-overlay = final: prev: {
      herdr-sidebar = final.runCommand "herdr-sidebar" {} ''
        mkdir -p $out/target/release
        cp -a "${inputs.herdr-sidebar}/plugins/herdr-sidebar/." $out/
        chmod -R u+w $out
        install -Dm 755 ${final.fetchurl {
          url = "https://github.com/alexarthurs/herdr-sidebar/releases/download/v0.15.1/herdr-sidebar-x86_64-unknown-linux-musl";
          hash = "sha256-12YXsEbGnCFpAbqwqicv4XdKuASUb+oFIHvC2JKPZLo=";
        }} $out/target/release/herdr-sidebar
      '';
    };

    # Local overlay: self-built packages (oh-my-pi) plus version overrides.
    # bun 1.4.4 (upstream 2026-10, https://github.com/oven-sh/bun/releases/tag/bun-v1.4.4):
    # nixpkgs nixos-unstable still ships 1.4.2, so version-override the sources
    # the same way nixpkgs' bun/package.nix defines them (per-platform fetchurl
    # into `sources`); version feeds both the URL and passthru. Hashes verified
    # against the release tags' GitHub asset digests.
    # Keep the wrapProgram prefix: makes dlopen() of prebuilt glibc N-API addons
    # work (e.g. @duckdb/node-bindings needs libstdc++.so.6/libgcc_s.so.1): this
    # bun is a Nix-patched ELF, so it never uses nix-ld's NIX_LD_* shim, and a
    # runtime dlopen() only consults LD_LIBRARY_PATH/RUNPATH.
    # Drop this override once nixpkgs lands >= 1.4.4.
    self-overlay = final: prev: {
      oh-my-pi = final.callPackage ./pkgs/oh-my-pi/default.nix {};

      bun = let
        version = "1.4.4";
        sources = {
          "x86_64-linux" = prev.fetchurl {
            url = "https://github.com/oven-sh/bun/releases/download/bun-v${version}/bun-linux-x64-baseline.zip";
            hash = "sha256-4ERutVmVdy65iUvrrppr42jZhai5Jx7hJEhvmUbu3XY=";
          };
          # aarch64-linux is in nixpkgs' meta.platforms; keep the attr coherent
          "aarch64-linux" = prev.fetchurl {
            url = "https://github.com/oven-sh/bun/releases/download/bun-v${version}/bun-linux-aarch64.zip";
            hash = "sha256-uqa7NvUdblhWHgK76oJQOKnfRU9nPW13bou/hvjHhQ4=";
          };
        };
      in
        prev.bun.overrideAttrs (_old: {
          inherit version;
          src = sources.${prev.stdenv.hostPlatform.system}
            or _old.src; # darwin: keep nixpkgs' own source (systems not covered by sources)
          postFixup =
            (_old.postFixup or "")
            + ''
              wrapProgram $out/bin/bun \
                --prefix LD_LIBRARY_PATH : "${final.stdenv.cc.cc.lib}/lib"
            '';
        });
      # # ferdium 7.2.2 (upstream 2026-08-23): nixpkgs @ c27cdad still ships 7.1.2.
      # # Same .deb repack as nixpkgs' mkFranzDerivation — drop once nixpkgs >= 7.2.2.
      # ferdium = prev.ferdium.overrideAttrs (old: rec {
      #   version = "7.2.2";
      #   src = final.fetchurl {
      #     url = "https://github.com/ferdium/ferdium-app/releases/download/v${version}/Ferdium-linux-${version}-amd64.deb";
      #     hash = "sha256-zTJWVv7CHEH3Tg1bDqpxB+Kiraoli1jTvQ9hXn3MOWA=";
      #   };
      # });
    };

    mkCommon = {
      hostname,
      extraModules,
    }:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit inputs hostname;
          inherit pkgs-stable pkgs-android pkgs-jdk24;
        };
        modules =
          [
            ./configuration.nix
            inputs.agenix.nixosModules.age
            inputs.niri.nixosModules.niri
            {
              nixpkgs.overlays = [
                inputs.nix-vscode-extensions.overlays.default
                # niri-flake @ 9ee3e13b asserts libdisplay-info_0_2.version ==
                # "0.2.0" (flake.nix:103) and lets callPackage auto-fill it from
                # pkgs. nixpkgs-unstable (2026-08-04, rev 2fcb964) turned
                # libdisplay-info_0_2 into a throw alias ("has been removed as
                # it was unused in Nixpkgs"), so callPackage forces the throw
                # and the build dies at the assert. Restore the real 0.2.0 from
                # pkgs-stable (nixos-26.05, rev fcb8fcd6 — before the removal)
                # so niri's callPackage finds a buildable package. Drop this
                # overlay once niri-flake publishes a commit that drops the
                # 0.2.0 assert / uses libdisplay-info (0.4.x) directly.
                (final: prev: {
                  libdisplay-info_0_2 = pkgs-stable.libdisplay-info_0_2;
                })
                # Exposes pkgs.niri-stable / pkgs.niri-unstable.
                inputs.niri.overlays.niri
                herdr-sidebar-overlay
                self-overlay
              ];
            }

            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "backup";
              home-manager.extraSpecialArgs = {
                inherit inputs hostname self pkgs-stable pkgs-android pkgs-jdk24;
              };
              home-manager.sharedModules = [
                inputs.agenix.homeManagerModules.age
              ];
              home-manager.users.age2pierre = import ./home.nix;
            }
          ]
          ++ extraModules;
      };
  in {
    nixosConfigurations = {
      tuxedo = mkCommon {
        hostname = "tuxedo";
        extraModules = [
          ./tuxedo-hardware-configuration.nix
          {
            hardware.tuxedo-drivers.enable = true;
            boot.kernelParams = ["mt7921_common.disable_clc=1"];
            systemd.tmpfiles.rules = [
              "w /sys/devices/platform/tuxedo_keyboard/fn_lock - - - - 1"
            ];
          }
        ];
      };
    };
  };
}
