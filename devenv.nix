{ pkgs, ... }:

{
  packages = with pkgs; [
    git
    curl
    jq
    ripgrep
  ] ++ lib.optionals (stdenv.hostPlatform.system == "x86_64-linux") [
    (callPackage ./nix/caveman-cli.nix { })
  ];
}
