{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "shikigami-workspace-deadline";
  version = "1";
  src = ../shikigami-workers/cbits/workspace-deadline.c;
  dontUnpack = true;
  buildCommand = ''
    mkdir -p "$out/bin"
    $CC -O2 -Wall -Wextra -Werror "$src" -o "$out/bin/shikigami-workspace-deadline"
  '';
  meta.platforms = [ "aarch64-linux" "x86_64-linux" "aarch64-darwin" ];
}
