with import <nixpkgs> {};

(bundlerEnv {
  name = "iknow-view-models-shell";
  gemdir = ./nix/gem;

  gemConfig = (defaultGemConfig.override { postgresql = postgresql_11; });

  ruby = ruby_2_6.overrideAttrs (attrs: {
    patches = (attrs.patches or []) ++ [
      # RubyGems has a regression where you can no longer build certain gems
      # outside their directory. Until this is merged, patch from the pull
      # request.
      (fetchpatch {
        url = https://patch-diff.githubusercontent.com/raw/rubygems/rubygems/pull/2596.patch;
        sha256 = "0m1s5brd30bqcr8v99sczihm83g270philx83kkw5bpix462fdm3";
      })
    ];
  });
}).env
