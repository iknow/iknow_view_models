{ nixpkgs ? import <nixpkgs> {} }:

with nixpkgs;

let
  viewmodelsDeps = import ./. { inherit nixpkgs; };
in

stdenv.mkDerivation ({
  name = "iknow-viewmodels-shell";
  buildInputs = [ viewmodelsDeps.viewmodelsBuildDeps ];
  shellHook = ''
    nix-store --add-root $BUNDLE_PATH/.nix-gem-deps --indirect --realise ${viewmodelsDeps.bundleConfig.allGemDepsEnv} > /dev/null
    nix-store --add-root .nix-deps --indirect --realise ${viewmodelsDeps.viewmodelsBuildDeps} > /dev/null

    echo "Setting gem path to $BUNDLE_PATH via bundle config"
    echo "See https://github.com/rails/spring/issues/339"
    bundle config --local path $BUNDLE_PATH
  '';
} // viewmodelsDeps.bundleConfig.envVars)
