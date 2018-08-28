{ lib, runCommand, makeWrapper, pkgconfig, buildEnv, writeText }:

let
  # in extconf.rb files you will see calls to dir_config("foo") which
  # translates into --with-foo-include= and --with-foo-dir= (and
  # possibly more). We implement this interface via an attribute set.
  giveLibToRuby = name: l:
    "--with-${name}-include=${lib.getDev l}/include --with-${name}-lib=${lib.getLib l}/lib";

  rbDirConfig = libs:
    lib.concatStringsSep " " (lib.mapAttrsToList giveLibToRuby libs);


  # Also in extconf.rb files you will see calls to pkg_config("foo")
  # which finds libraries from by calling a pkg-config binary. We
  # implement this interface by making a pkg-config binary with a
  # PKG_CONFIG_PATH that exposes only the specified libraries, and
  # passing it to --with-pkg-config=
  pkgConfigWithPkgs = pkgs:
    let
      dirs = lib.concatStringsSep ":" (
        map (x: "${lib.getDev x}/lib/pkgconfig:${lib.getDev x}/share/pkgconfig") pkgs);
    in

    runCommand "pkg-config-wrapper" {
      nativeBuildInputs = [ makeWrapper ];
    } ''
      makeWrapper ${pkgconfig}/bin/pkg-config $out/bin/pkg-config --set PKG_CONFIG_PATH ${dirs}
    '';

  rbPkgConfig = libs:
    "--with-pkg-config=${pkgConfigWithPkgs libs}/bin/pkg-config";

  getAllGemDeps = gemConfig:
    let
      gemDeps = (k: v:
         (v.pkgConfigLibs or []) ++ (lib.attrValues (v.dirConfigLibs or {}))
       );
    in
      lib.concatLists (lib.mapAttrsToList gemDeps gemConfig);

in

{ ruby, gemConfig }:

let
  allGemDeps = getAllGemDeps gemConfig;

  # Mostly used for its hash, but also as a gc root and
  # so you have the bins for the gem deps
  allGemDepsEnv = buildEnv {
    name = "all-gem-deps";
    paths = getAllGemDeps gemConfig ++ [ ruby ];
    extraOutputsToInstall = [ "lib" "dev" ];
  };

  depsHash = lib.substring (lib.stringLength builtins.storeDir + 1) 32
    (toString allGemDepsEnv);

  gemBuildAttrs = lib.mapAttrs' (gem: config: (
    let
      pkgConfigFlags = lib.optional (config ? pkgConfigLibs) (
        rbPkgConfig config.pkgConfigLibs
      );
      dirConfigFlags = lib.optional (config ? dirConfigLibs) (
        rbDirConfig config.dirConfigLibs
      );
      buildFlags = lib.concatStringsSep " " (
        pkgConfigFlags ++ dirConfigFlags ++ (config.extraFlags or [])
      );
    in lib.nameValuePair "BUNDLE_BUILD__${gem}" buildFlags
  )) gemConfig;

  gemPath = "tmp/gems/${depsHash}";

  bundlerAttrs = gemBuildAttrs // {
    BUNDLE_PATH = gemPath;
  };
in {
  inherit allGemDeps allGemDepsEnv depsHash gemPath;

  envVars = bundlerAttrs;

  bashEnvFile = writeText "bash-env" (lib.concatStrings
    (lib.mapAttrsToList (k: v: "export ${k}=\"${v}\"\n") bundlerAttrs));

  bundleConfigFile = writeText "bundle-config" (lib.concatStrings
    (lib.mapAttrsToList (k: v: "${k}: ${v}\n") bundlerAttrs));
}
