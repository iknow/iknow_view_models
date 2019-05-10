with import <nixpkgs> {};

(bundlerEnv {
  name = "dev";
  gemdir = ./nix/gem;
}).env
