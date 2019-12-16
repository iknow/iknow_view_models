with import <nixpkgs> {};

(bundlerEnv {
  name = "iknow-view-models-shell";
  gemdir = ./nix/gem;

  gemConfig = (defaultGemConfig.override { postgresql = postgresql_11; });

  ruby = ruby_2_6;
}).env
