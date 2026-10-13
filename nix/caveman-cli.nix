{ stdenvNoCC
, fetchurl
, runCommand
, gnutar
, gzip
, makeWrapper
, bun
, jq
, lib
}:

assert stdenvNoCC.hostPlatform.system == "x86_64-linux";
let
  version = "4.0.1";
  binaryRelease = "bin-v${version}";

  npmSource = fetchurl {
    url = "https://registry.npmjs.org/@caveman-ai/cli/-/cli-${version}.tgz";
    hash = "sha256-eM2gHSCOtndHvMfAY4aSUqLTFsd4b+UE4/aVlA5ZNm8=";
  };

  releaseAsset = name: hash: fetchurl {
    url = "https://github.com/JuliusBrussee/caveman/releases/download/${binaryRelease}/${name}_linux_amd64";
    inherit hash;
  };

  runtimeAssets = {
    caveman-proxy = releaseAsset "caveman-proxy" "sha256-ix3A6buol6uox0ma/7djmY6apYKR3EuqbOqBi/GDnVk=";
    caveman-engine = releaseAsset "caveman-engine" "sha256-Sb/ojuQL4Sh5nFbnTTimTviYdZmI4k5XKZvcfaAULtc=";
    caveman-mcp = releaseAsset "caveman-mcp" "sha256-KfmBbFyXxonEQFK7meACIXjzdUIMNGRIQFQ+6/jI964=";
    cavemem = releaseAsset "cavemem" "sha256-lVbSnsqooPgA6exe8yRaArKA67RPBlLhPSjVfZxKG7Y=";
    caveman-browse = releaseAsset "caveman-browse" "sha256-OS2WMNXu6W5Vx2Orz6lzpX3nI7cTzdQ1LtYBpubQjAY=";
    caveman-shrink = releaseAsset "caveman-shrink" "sha256-KtRSxjgfFc9AEOb+WUdTtrnoLOLRBEPp7u9UdgvoSS4=";
  };

  runtime = runCommand "caveman-runtime-${binaryRelease}" { } ''
    mkdir -p "$out/bin"
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: src: "install -m 0555 ${src} \"$out/bin/${name}\"") runtimeAssets)}
  '';
in
stdenvNoCC.mkDerivation {
  pname = "caveman-cli";
  inherit version;
  dontUnpack = true;

  nativeBuildInputs = [ gnutar gzip makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/caveman-cli" "$out/bin"
    tar -xzf ${npmSource} -C "$out/share/caveman-cli" --strip-components=1
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: "ln -s ${runtime}/bin/${name} \"$out/bin/${name}\"") runtimeAssets)}
    makeWrapper ${bun}/bin/bun "$out/bin/caveman" \
      --add-flags "$out/share/caveman-cli/dist/index.js" \
      --set-default DO_NOT_TRACK 1 \
      --set-default CAVEMAN_PROXY_BIN ${runtime}/bin/caveman-proxy \
      --set-default CAVEMAN_ENGINE_BIN ${runtime}/bin/caveman-engine \
      --set-default CAVEMAN_MCP_BIN ${runtime}/bin/caveman-mcp \
      --set-default CAVEMEM_BIN ${runtime}/bin/cavemem \
      --set-default CAVEMAN_BROWSE_BIN ${runtime}/bin/caveman-browse \
      --set-default CAVEMAN_SHRINK_BIN ${runtime}/bin/caveman-shrink
    ln -s caveman "$out/bin/cave"
    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ jq ];
  installCheckPhase = ''
    runHook preInstallCheck
    set -o pipefail
    export CAVEMAN_HOME="$TMPDIR/caveman-home"
    "$out/bin/caveman" --version | jq -e --arg version "${version}" '.version == $version' >/dev/null
    "$out/bin/caveman" setup --json | jq -e '.ready == true and (.binaries | length == 6)' >/dev/null
    runHook postInstallCheck
  '';

  meta = {
    description = "Caveman CLI and its pinned local runtime binaries, using Bun";
    homepage = "https://github.com/JuliusBrussee/caveman";
    license = lib.licenses.asl20;
    mainProgram = "caveman";
    platforms = [ "x86_64-linux" ];
  };
}
