{
  pkgs,
  system,
  version,
}:

let
  # Helper function to download npm packages
  fetchNpmPackage =
    {
      pname,
      version,
      hash,
      os ? null,
      cpu ? null,
    }:
    pkgs.fetchurl {
      url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
      inherit hash;
    };

  # Map system to npm package architecture
  getOpencodeArchForSystem =
    system:
    let
      platformMap = {
        "aarch64-darwin" = {
          os = "darwin";
          cpu = "arm64";
        };
        "x86_64-darwin" = {
          os = "darwin";
          cpu = "x64";
        };
        "aarch64-linux" = {
          os = "linux";
          cpu = "arm64";
        };
        "x86_64-linux" = {
          os = "linux";
          cpu = "x64";
        };
      };
    in
    platformMap.${system} or (throw "Unsupported system: ${system}");

  # Get system-specific parameters
  systemInfo = getOpencodeArchForSystem system;
  platformPackageName = "opencode-${systemInfo.os}-${systemInfo.cpu}";

  # Define the hashes for each platform package
  packageHashes = {
    "opencode-ai" = "sha256-4PgVVSRCiQf5g0jpIvz298WRqeKVRxKNo61xYbkFX6g=";
    "opencode-darwin-arm64" = "sha256-dR7l12VJjw6x5n+BoNJkFuMkPrUDzTwDdBziPwLkuhg=";
    "opencode-darwin-x64" = "sha256-nXXq87OVugjl22NOyIkDM+/pypKHdpAiuO1MWTQdnVE=";
    "opencode-linux-arm64" = "sha256-sOlkwe9pC3dYt4RPA1TFWSI6ZT3I4uqR2AJZ8YX7vsI=";
    "opencode-linux-x64" = "sha256-6K4y48MPbV6/9BN/97hE/zjFytkXI10GJLdZ/IcF6DU=";
  };

  # Create the base package first
  basePackage = pkgs.stdenv.mkDerivation {
    pname = "opencode-base";
    inherit version;

    # Source tarballs
    src = fetchNpmPackage {
      pname = "opencode-ai";
      inherit version;
      hash = packageHashes."opencode-ai";
    };

    # Platform-specific binary
    platformSrc = fetchNpmPackage {
      pname = platformPackageName;
      inherit version;
      hash =
        packageHashes.${platformPackageName} or (throw "Hash for ${platformPackageName} not defined");
    };

    # Dependencies
    nativeBuildInputs = with pkgs; [
      autoPatchelfHook
    ];

    buildInputs = with pkgs; [
      stdenv.cc.cc.lib
      glibc
      zlib
      openssl
    ];

    # Unpack the sources
    unpackPhase = ''
      tar -xzf $src
      mkdir -p platform
      tar -xzf $platformSrc -C platform
    '';

    # Installation
    installPhase = ''
      # Create directories
      mkdir -p $out/lib/node_modules/opencode-ai
      mkdir -p $out/lib/node_modules/${platformPackageName}

      # Copy main package
      cp -r package/* $out/lib/node_modules/opencode-ai/

      # Copy platform-specific package
      cp -r platform/package/* $out/lib/node_modules/${platformPackageName}/

      # Make the binary executable
      chmod +x $out/lib/node_modules/${platformPackageName}/bin/opencode
    '';

    # Fix dynamic linking after installation
    fixupPhase = ''
      runHook preFixup

      # autoPatchelfHook will automatically patch the binary
      if [ -f "$out/lib/node_modules/${platformPackageName}/bin/opencode" ]; then
        echo "Found OpenCode binary, autoPatchelfHook will patch it"
      else
        echo "ERROR: OpenCode binary not found at expected location"
        exit 1
      fi

      runHook postFixup
    '';

    meta = with pkgs.lib; {
      description = "OpenCode base package (internal)";
      platforms = [ system ];
    };
  };

in
# Use different approaches for Linux vs Darwin
if pkgs.stdenv.isLinux then
  # Linux: Use FHS environment for NixOS compatibility
  pkgs.buildFHSEnv {
    name = "opencode";
    
    targetPkgs = pkgs: with pkgs; [
      basePackage
      stdenv.cc.cc.lib
      glibc
      zlib
      openssl
      curl
      cacert
      # Additional libraries that might be needed at runtime
      libgcc
      ncurses
      xz
    ];

    # Set up the runtime environment
    profile = ''
      export OPENCODE_ROOT="${basePackage}"
      export PATH="${basePackage}/lib/node_modules/${platformPackageName}/bin:$PATH"
    '';

    # Create a wrapper script that launches OpenCode
    runScript = pkgs.writeScript "opencode-wrapper" ''
      #!/bin/bash
      exec "${basePackage}/lib/node_modules/${platformPackageName}/bin/opencode" "$@"
    '';

    meta = with pkgs.lib; {
      description = "A powerful terminal-based AI assistant for developers";
      homepage = "https://github.com/sst/opencode";
      license = licenses.mit;
      platforms = [ system ];
      maintainers = [ "aodhan.hayter@gmail.com" ];
      changelog = "https://github.com/sst/opencode/releases";
      longDescription = ''
        OpenCode is an open-source AI developer tool created by SST (Serverless Stack).
        It acts as a terminal-based assistant that helps with coding tasks, debugging,
        and project management directly in your terminal.
      '';
    };
  }
else
  # Darwin: Use regular derivation with makeWrapper
  pkgs.stdenv.mkDerivation {
    pname = "opencode";
    inherit version;

    # Source tarballs
    src = fetchNpmPackage {
      pname = "opencode-ai";
      inherit version;
      hash = packageHashes."opencode-ai";
    };

    # Platform-specific binary
    platformSrc = fetchNpmPackage {
      pname = platformPackageName;
      inherit version;
      hash =
        packageHashes.${platformPackageName} or (throw "Hash for ${platformPackageName} not defined");
    };

    # Dependencies
    nativeBuildInputs = with pkgs; [
      makeWrapper
    ];

    # Environment variables
    passthru.exePath = "/bin/opencode";

    # Unpack the sources
    unpackPhase = ''
      tar -xzf $src
      mkdir -p platform
      tar -xzf $platformSrc -C platform
    '';

    # Installation
    installPhase = ''
      # Create directories
      mkdir -p $out/bin
      mkdir -p $out/lib/node_modules/opencode-ai
      mkdir -p $out/lib/node_modules/${platformPackageName}

      # Copy main package
      cp -r package/* $out/lib/node_modules/opencode-ai/

      # Copy platform-specific package
      cp -r platform/package/* $out/lib/node_modules/${platformPackageName}/

      # Make the binary executable
      chmod +x $out/lib/node_modules/${platformPackageName}/bin/opencode

      # Create symlink for the binary
      ln -s $out/lib/node_modules/${platformPackageName}/bin/opencode $out/bin/opencode
    '';

    meta = with pkgs.lib; {
      description = "A powerful terminal-based AI assistant for developers";
      homepage = "https://github.com/sst/opencode";
      license = licenses.mit;
      platforms = [ system ];
      maintainers = [ "aodhan.hayter@gmail.com" ];
      changelog = "https://github.com/sst/opencode/releases";
      longDescription = ''
        OpenCode is an open-source AI developer tool created by SST (Serverless Stack).
        It acts as a terminal-based assistant that helps with coding tasks, debugging,
        and project management directly in your terminal.
      '';
    };
  }
