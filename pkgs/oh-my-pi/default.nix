# oh-my-pi — can1357/oh-my-pi (binary `omp`).
#
# Fork of pi-mono with hash-anchored edits, LSP, optimized tool harness,
# Python+browser+subagents extras. Coexists with `pi` (different binary name).
#
# Upstream ships a single self-contained Bun standalone ELF binary per
# platform, fetched directly from the GitHub release.
#
# Bumping:
#   1. find current version:  curl -s https://api.github.com/repos/can1357/oh-my-pi/releases/latest | jq -r .tag_name
#   2. update `version` below.
#   3. update `hash`:
#        H=$(nix-prefetch-url https://github.com/can1357/oh-my-pi/releases/download/<VER>/omp-linux-x64)
#        nix hash convert --to sri --hash-algo sha256 "$H"
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "oh-my-pi";
  version = "v18.4.4";

  src = fetchurl {
    url = "https://github.com/can1357/oh-my-pi/releases/download/${finalAttrs.version}/omp-linux-x64";
    hash = "sha256-JMgw/OsL1ohL9b8seit0B7wj+v5lXpJMaV75vjCORvM=";
  };

  # Self-contained Bun standalone binary — only needs the dynamic linker.
  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall

    install -Dm 755 $src $out/bin/omp

    runHook postInstall
  '';

  meta = {
    description = "AI coding agent for the terminal (oh-my-pi fork of pi-mono)";
    homepage = "https://github.com/can1357/oh-my-pi";
    changelog = "https://github.com/can1357/oh-my-pi/releases/tag/${finalAttrs.version}";
    license = lib.licenses.mit;
    mainProgram = "omp";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = with lib.sourceTypes; [binaryNativeCode];
  };
})
