{ pkgs ? import <nixpkgs> {} }:

with pkgs;

let
  dependencies = import ./nix/dependencies.nix { inherit pkgs; };
in
(bundlerEnv {
  name = "iknow-view-models-shell";
  gemdir = ./nix/gem;
  gemConfig = defaultGemConfig;
  inherit (dependencies) ruby;
}).env
