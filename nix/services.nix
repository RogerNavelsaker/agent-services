{ pkgs, self }:

let
  lib = pkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;
  revision = if self ? dirtyRev then self.dirtyRev else self.rev or "unknown";

  assets = {
    "x86_64-linux" = {
      engram = {
        file = "engram_3.4.0_linux_amd64.tar.gz";
        hash = "sha256-cV/aYlVW5G1l3bRSa7f4ij/uUznKPETORMxlLxf6V/E=";
      };
      cavemanProxy = {
        file = "caveman-proxy_linux_amd64";
        hash = "sha256-RENtaXBa2ZaFY8GBzRHTltauXuzNjb8ij2Il2S363LE=";
      };
      cavemanMcp = {
        file = "caveman-mcp_linux_amd64";
        hash = "sha256-JDOeZF2mb7NYDj2UEHQ0mYRXSCOPAdDcgJczD8sPm94=";
      };
    };
    "aarch64-linux" = {
      engram = {
        file = "engram_3.4.0_linux_arm64.tar.gz";
        hash = "sha256-MwnpwLu1OdGD/Vqp+aE816oOgewlErW+3vuLK901s+U=";
      };
      cavemanProxy = {
        file = "caveman-proxy_linux_arm64";
        hash = "sha256-WogZeZNNUYIsz56hPFGXaf6hjFLAYeFOa9DZ+VDOdg8=";
      };
      cavemanMcp = {
        file = "caveman-mcp_linux_arm64";
        hash = "sha256-+0m5lu7lopemdKBnl5kx2aKNWcvnNb4rkQTnUZ73BCo=";
      };
    };
  };
  selectedAssets = assets.${system} or (throw "agent service images do not support ${system}");
  engramVersion = "3.4.0";
  cavemanVersion = "bin-v2.1.0";
  headroomVersion = "0.40.0+pr4014";
  headroomRevision = "3c418f6f0b190ad1060413c0eadd77f20ab3cf46";
  stateOwner = "10001:10001";

  releaseAsset =
    { file, hash }:
    pkgs.fetchurl {
      url = "https://github.com/Gentleman-Programming/engram/releases/download/v${engramVersion}/${file}";
      inherit hash;
    };
  engramArchive = releaseAsset selectedAssets.engram;

  engram =
    pkgs.runCommand "engram-${engramVersion}"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
        ];
      }
      ''
        mkdir -p "$out/bin"
        tar -xzf ${engramArchive} -C "$out/bin" engram
        chmod 0555 "$out/bin/engram"
      '';

  cavemanAsset =
    { file, hash }:
    pkgs.fetchurl {
      url = "https://github.com/JuliusBrussee/caveman/releases/download/${cavemanVersion}/${file}";
      inherit hash;
    };
  cavemanProxyBinary = cavemanAsset selectedAssets.cavemanProxy;
  cavemanMcpBinary = cavemanAsset selectedAssets.cavemanMcp;
  caveman = pkgs.runCommand "caveman-${cavemanVersion}" { } ''
    mkdir -p "$out/bin"
    install -m 0555 ${cavemanProxyBinary} "$out/bin/caveman-proxy"
    install -m 0555 ${cavemanMcpBinary} "$out/bin/caveman-mcp"
  '';

  headroomSrc = pkgs.fetchFromGitHub {
    owner = "headroomlabs-ai";
    repo = "headroom";
    rev = headroomRevision;
    hash = "sha256-OSfbEyGIXxceIwE0DqKI/ZIKC8M8iJd/vNnfqZ+x9Fc=";
  };
  python = pkgs.python313;
  py = python.pkgs;
  headroom = py.buildPythonApplication (finalAttrs: {
    pname = "headroom-ai";
    version = "0.40.0";
    pyproject = true;
    src = headroomSrc;

    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) pname src version;
      hash = "sha256-8Y8FyX1LxLO7dHNDaMK8NAiRjZkNU0bsM4P+HbMvReI=";
    };

    nativeBuildInputs = [
      pkgs.rustPlatform.cargoSetupHook
      pkgs.rustPlatform.maturinBuildHook
    ];
    dependencies = with py; [
      tiktoken
      pydantic
      litellm
      click
      rich
      opentelemetry-api
      ast-grep-cli
      pyyaml
      tomli
      tomlkit
      truststore
      fastapi
      uvicorn
      orjson
      httpx
      h2
      openai
      mcp
      magika
      zstandard
      websockets
      onnxruntime
      transformers
      watchdog
      sqlite-vec
    ];
    makeWrapperArgs = [
      "--prefix"
      "PYTHONPATH"
      ":"
      "${placeholder "out"}/${python.sitePackages}:${py.makePythonPath finalAttrs.propagatedBuildInputs}"
    ];
    postInstall = ''
      cat > "$out/bin/headroom-child-python-check" <<'PY'
      #!${python}/bin/python
      import subprocess
      import sys
      subprocess.run([sys.executable, "-c", "import h2; import headroom.cli"], check=True)
      PY
      chmod +x "$out/bin/headroom-child-python-check"
    '';
    postFixup = ''
      env -u PYTHONPATH "$out/bin/headroom-child-python-check"
      rm "$out/bin/headroom-child-python-check"
    '';
    nativeCheckInputs = [ py.pytestCheckHook ];
    pytestFlags = [ "${../tests/test_headroom_caveman_safeguard.py}" ];
    pythonImportsCheck = [
      "headroom.config"
      "headroom.transforms.content_router"
    ];

    meta = {
      description = "Headroom proxy pinned to PR #4014 for exact Caveman retrieval recovery";
      homepage = "https://github.com/headroomlabs-ai/headroom";
      license = lib.licenses.asl20;
      mainProgram = "headroom";
    };
  });

  serviceImage =
    {
      name,
      title,
      description,
      version,
      package,
      entrypoint,
      command ? [ ],
      ports ? { },
      volumes ? {
        "/data" = { };
      },
      env ? [ ],
      extraPath ? [ ],
    }:
    pkgs.dockerTools.buildLayeredImage {
      inherit name;
      tag = "latest";
      maxLayers = 16;
      contents = [
        pkgs.cacert
        pkgs.tzdata
        pkgs.dockerTools.fakeNss
        package
      ];
      fakeRootCommands = ''
        mkdir -p ./tmp ${lib.concatStringsSep " " (map (volume: ".${volume}") (lib.attrNames volumes))}
        chown -R ${stateOwner} ${
          lib.concatStringsSep " " (map (volume: ".${volume}") (lib.attrNames volumes))
        }
        chmod 0700 ${lib.concatStringsSep " " (map (volume: ".${volume}") (lib.attrNames volumes))}
        chmod 1777 ./tmp
      '';
      config = {
        Labels = {
          "org.opencontainers.image.title" = title;
          "org.opencontainers.image.description" = description;
          "org.opencontainers.image.source" = "https://github.com/RogerNavelsaker/agent-services";
          "org.opencontainers.image.version" = version;
          "org.opencontainers.image.revision" = revision;
        };
        User = stateOwner;
        Entrypoint = [ entrypoint ];
        Cmd = command;
        Env = [
          "PATH=${lib.makeBinPath ([ package ] ++ extraPath)}"
          "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          "HOME=/data"
          "TMPDIR=/tmp"
          "TZ=UTC"
        ]
        ++ env;
        WorkingDir = "/data";
        Volumes = volumes;
        ExposedPorts = ports;
      };
    };
in
{
  packages = {
    inherit engram headroom caveman;
  };
  images = {
    engram-image = serviceImage {
      name = "agent-services-engram";
      title = "Engram Cloud";
      description = "Engram Cloud server using an external PostgreSQL database";
      version = engramVersion;
      package = engram;
      entrypoint = "${engram}/bin/engram";
      command = [
        "cloud"
        "serve"
      ];
      ports = {
        "7437/tcp" = { };
      };
      env = [
        "ENGRAM_CLOUD_HOST=0.0.0.0"
        "ENGRAM_PORT=7437"
      ];
    };
    headroom-image = serviceImage {
      name = "agent-services-headroom";
      title = "Headroom Proxy";
      description = "Headroom proxy pinned to the Caveman retrieval safeguard in PR #4014";
      version = headroomVersion;
      package = headroom;
      entrypoint = "${headroom}/bin/headroom";
      command = [
        "proxy"
        "--host"
        "0.0.0.0"
        "--port"
        "8787"
      ];
      ports = {
        "8787/tcp" = { };
      };
      volumes = {
        "/data" = { };
        "/config" = { };
      };
      env = [
        "HEADROOM_WORKSPACE_DIR=/data"
        "HEADROOM_CONFIG_DIR=/config"
        "HEADROOM_BEACON=off"
      ];
      extraPath = [ py.ast-grep-cli ];
    };
    caveman-image = serviceImage {
      name = "agent-services-caveman";
      title = "Caveman Proxy";
      description = "Caveman proxy and MCP binaries with a shared persistent recovery store";
      version = cavemanVersion;
      package = caveman;
      entrypoint = "${caveman}/bin/caveman-proxy";
      ports = {
        "8787/tcp" = { };
      };
      env = [
        "CAVEMAN_HOME=/data"
        "CAVEMAN_CCR_DB=/data/ccr.db"
        "CAVEMAN_LISTEN=0.0.0.0:8787"
      ];
    };
  };
}
