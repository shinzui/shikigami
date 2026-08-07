# flake.module.nix — project-specific flake-parts customizations.
#
# seihou does NOT manage this file: it is never regenerated or overwritten by
# `seihou run` or module migrations, so changes here survive template upgrades
# without conflict. See flake.module.nix.example for the full option reference.
#
# NOTE: Nix flakes only see git-tracked files, so this file must be `git add`ed
# for flake.nix's `builtins.pathExists ./flake.module.nix` import to pick it up.
{ inputs, ... }:
{
  perSystem = { pkgs, config, ... }: {
    # librdkafka: the C library hw-kafka-client / kafka-effectful link against
    # (EP-3 --republish-topic and EP-4's activity.v1 stream consumer).
    haskellProject.extraDevPackages = [ pkgs.rdkafka ];
  };
}
