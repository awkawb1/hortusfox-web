{ lib, php, ... }:

# buildComposerProject installs the project to
#   $out/share/php/<pname>/  (with vendor/ populated)
php.buildComposerProject (finalAttrs: {
  pname = "hortusfox-web";
  version = "6.5";

  # Only git-tracked files -- a bare `./.` path would vendor whatever
  # happens to sit in the working tree (vendor/, node_modules/, .env, a
  # locally-built public/js/app.js) straight into the store. gitTracked
  # mirrors what a flake's own `self` gives you, without needing `self`
  # threaded through from flake.nix (so this file works called standalone
  # too, e.g. `nix-build package.nix`).
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.gitTracked ./.;
  };

  # composer.lock is committed, so a fixed vendorHash works.
  vendorHash = "sha256-b9t5S12TJoiup7fkQ4bo2xH+CvEt6MqOrQxQ/gJ4Deg=";

  # No console entrypoint to expose on PATH; we call `php asatru` ourselves.
  composerNoDev = true;

  composerStrictValidation = false;

  meta = with lib; {
    description = "Self-hosted collaborative plant management system";
    homepage = "https://github.com/danielbrendel/hortusfox-web";
    license = licenses.mit;
    platforms = platforms.linux;
  };
})
