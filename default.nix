{ nixpkgs ? import <nixpkgs> {} }:

with nixpkgs;

let
  ruby = ruby_2_5;
  postgresql = postgresql100;

  mkBundleConfig = callPackage ./nix/mk-bundle-config.nix {};

  myGemConfig = {
   PG = {
     dirConfigLibs = {
       pg = postgresql;
     };
   };
    NOKOGIRI = {
      dirConfigLibs = {
        inherit zlib;
      };
      pkgConfigLibs = [
        libxml2 libxslt
      ];
      extraFlags = [ "--use-system-libraries" ];
    };
    SQLITE3 = {
      pkgConfigLibs = [
        sqlite
      ];
    };
  };

  bundleConfig = mkBundleConfig { gemConfig = myGemConfig; inherit ruby; };
in

rec {
  inherit bundleConfig;

  # nix-build -A bundleConfigFile -o .bundle/config
  # nix-build -A bashEnvFile -o env && source env
  inherit (bundleConfig) bundleConfigFile bashEnvFile;

 # nix-env -f . -iA viewmodelsBuildDeps
  viewmodelsBuildDeps = buildEnv {
    name = "viewmodels-content-deps";
    paths = [
      ruby

      # native gem components
      gcc gnumake

      # services we tend to use
      postgresql
    ] ++ bundleConfig.allGemDeps;

    extraOutputsToInstall = [ "lib" "dev" "doc" ];
  };
}
