{
  description = " Run a Shadertoy-compatible shader as an animated wallpaper on Wayland ";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    zig2nix = {
      url = "github:Cloudef/zig2nix/b2b6b1f58a88fdde434c47e19b398cdc47f7a2d1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    alejandra = {
      url = "github:kamadorueda/alejandra/4.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    zig2nix,
    nixpkgs,
    alejandra,
    ...
  }: let
    flake-utils = zig2nix.inputs.flake-utils;
  in (flake-utils.lib.eachDefaultSystem (system: let
    pkgs = nixpkgs.legacyPackages.${system};

    # zig2nix's versions with zig-0_15_2 require llvmPackages_21 which is not
    # yet in nixpkgs. Download the pre-built binary directly instead and wire
    # up the setup hook that zig2nix's package.nix expects on zig.hook.
    zig-0_15_2 = let
      sources = {
        x86_64-linux = {
          url = "https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz";
          hash = "sha256-AqonDxg9onbltZILHaxEpj8aSeVQUOveOuzJ64L5Mjk=";
        };
        aarch64-linux = {
          url = "https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz";
          # fill in if aarch64 is ever needed
          hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        };
      };
      src-meta = sources.${system} or (throw "No zig 0.15.2 binary available for ${system}");

      # Raw unpacked zig binary
      zig-bin = pkgs.stdenvNoCC.mkDerivation {
        pname = "zig";
        version = "0.15.2";
        src = pkgs.fetchurl {inherit (src-meta) url hash;};
        phases = ["unpackPhase" "installPhase"];
        installPhase = ''
          mkdir -p $out/{bin,lib}
          cp -r lib/* $out/lib
          install -Dm755 zig $out/bin/zig
          install -m644 LICENSE $out/LICENSE
        '';
      };

      # On Linux, wrap with bubblewrap so /usr/bin/env is reachable in the Nix
      # build sandbox (zig calls env internally for some operations).
      zig-drv =
        if pkgs.stdenvNoCC.isLinux
        then
          pkgs.writeShellScriptBin "zig" ''
            args=()
            for d in /*; do
              [[ -e "$d" ]] && args+=("--dev-bind" "$d" "$d")
            done
            exec ${pkgs.bubblewrap}/bin/bwrap "''${args[@]}" \
              --bind ${pkgs.coreutils} /usr \
              -- ${zig-bin}/bin/zig "$@"
          ''
        else zig-bin;

      # Replicate the setup-hook that zig2nix attaches to its zig packages.
      # package.nix accesses zig.hook so this must be present.
      hook-script = pkgs.writeText "zig-setup-hook.sh" ''
        # shellcheck shell=bash disable=SC2154,SC2086
        readonly zigDefaultFlagsArray=(@zig_default_flags@)

        function zigSetGlobalCacheDir {
          ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
          export ZIG_GLOBAL_CACHE_DIR
          ZIG_LOCAL_CACHE_DIR="$ZIG_GLOBAL_CACHE_DIR"
          export ZIG_LOCAL_CACHE_DIR
          TERM=dumb
          export TERM
        }

        function zigBuildPhase {
          runHook preBuild
          local flagsArray=(
            "''${zigDefaultFlagsArray[@]}"
            $zigBuildFlags "''${zigBuildFlagsArray[@]}"
          )
          echoCmd 'zig build flags' "''${flagsArray[@]}"
          zig build "''${flagsArray[@]}"
          runHook postBuild
        }

        function zigCheckPhase {
          runHook preCheck
          local flagsArray=(
            "''${zigDefaultFlagsArray[@]}"
            $zigCheckFlags "''${zigCheckFlagsArray[@]}"
          )
          echoCmd 'zig check flags' "''${flagsArray[@]}"
          zig build test "''${flagsArray[@]}"
          runHook postCheck
        }

        function zigInstallPhase {
          runHook preInstall
          local flagsArray=(
            "''${zigDefaultFlagsArray[@]}"
            $zigBuildFlags "''${zigBuildFlagsArray[@]}"
            $zigInstallFlags "''${zigInstallFlagsArray[@]}"
          )
          if [ -z "''${dontAddPrefix-}" ]; then
            flagsArray+=("''${prefixKey:---prefix}" "$prefix")
          fi
          echoCmd 'zig install flags' "''${flagsArray[@]}"
          zig build install "''${flagsArray[@]}"
          runHook postInstall
        }

        addEnvHooks "$hostOffset" zigSetGlobalCacheDir

        if [ -z "''${dontUseZigBuild-}" ] && [ -z "''${buildPhase-}" ]; then
          buildPhase=zigBuildPhase
        fi
        if [ -z "''${dontUseZigCheck-}" ] && [ -z "''${checkPhase-}" ]; then
          checkPhase=zigCheckPhase
        fi
        if [ -z "''${dontUseZigInstall-}" ] && [ -z "''${installPhase-}" ]; then
          installPhase=zigInstallPhase
        fi
      '';

      hook = pkgs.makeSetupHook {
        name = "zig-hook";
        propagatedBuildInputs = [zig-drv];
        substitutions.zig_default_flags = [];
        passthru.zig = zig-drv;
      } hook-script;
    in
      # Expose hook and version at the top level so zig2nix's package.nix
      # can find them (zig.hook, zig.version).
      zig-drv // {hook = hook; version = "0.15.2";};

    env = zig2nix.outputs.zig-env.${system} {
      zig = zig-0_15_2;
    };

    # Deps that need to be present when we run 'zig build'
    zigBuildDeps = with env.pkgs; [
      wayland-protocols
      wayland-scanner
    ];

    appDeps =
      zigBuildDeps
      ++ (with env.pkgs; [
        wayland
        libglvnd
      ]);
  in
    with env.pkgs.lib; rec {
      # Produces clean binaries meant to be ship'd outside of nix
      # nix build .#foreign
      packages.foreign = env.package {
        src = cleanSource ./.;

        # Packages required for compiling
        nativeBuildInputs = zigBuildDeps;

        # Packages required for linking
        buildInputs = with env.pkgs; [
          wayland
          libglvnd
        ];

        # We're linking against stuff like libwayland-client.so so we need the system
        # libc
        zigPreferMusl = false;
      };

      # nix build .
      packages.default = packages.foreign.override (attrs: {
        nativeBuildInputs = attrs.nativeBuildInputs;

        # Executables required for runtime
        # These packages will be added to the PATH
        zigWrapperBins = with env.pkgs; [];

        # Libraries required for runtime
        # These packages will be added to the LD_LIBRARY_PATH
        zigWrapperLibs = attrs.buildInputs or [];
      });

      # For bundling with nix bundle for running outside of nix
      # example: https://github.com/ralismark/nix-appimage
      apps.bundle = {
        type = "app";
        program = "${packages.foreign}/bin/papertoy";
      };

      # nix run .#build
      apps.build = env.app appDeps "zig build \"$@\"";

      # nix run .#zig2nix
      apps.zig2nix = env.app zigBuildDeps "zig2nix \"$@\"";

      # nix run .#format
      apps.format =
        env.app [
          alejandra.defaultPackage.${system}
        ] ''
          alejandra ./flake.nix
          zig fmt .
        '';

      # nix develop
      devShells.default = env.mkShell {
        # Packages required for compiling, linking and running
        # Libraries added here will be automatically added to the LD_LIBRARY_PATH and PKG_CONFIG_PATH
        nativeBuildInputs =
          []
          ++ packages.default.nativeBuildInputs
          ++ packages.default.buildInputs
          ++ packages.default.zigWrapperBins
          ++ packages.default.zigWrapperLibs;
      };

      checks.nix-format =
        pkgs.runCommand "nix-format" {
          nativeBuildInputs = [
            alejandra.defaultPackage.${system}
          ];
        } ''
          mkdir -p $out
          ${pkgs.lib.getExe alejandra.defaultPackage.${system}} --check ${./flake.nix}
        '';
      checks.zig-format =
        pkgs.runCommand "zig-format" {
          nativeBuildInputs = [
            env.zig
          ];
        } ''
          mkdir -p $out
          ${pkgs.lib.getExe env.zig} fmt --check ${./.}
        '';
    }));
}
