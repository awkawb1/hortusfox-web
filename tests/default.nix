{ pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../nixos-module
  ];

  # `nix flake check` builds config.system.build.toplevel (a fully bootable
  # system), even though this config is only ever meant to be built as
  # `.config.system.build.vm` (see justfile). These satisfy its assertions
  # without affecting the VM build itself.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  boot.loader.grub.devices = [ "/dev/vda" ];

  # Required by services.hortusfox-web's forceSSL+enableACME nginx vhost.
  security.acme = {
    acceptTerms = true;
    defaults.email = "test@example.invalid";
  };

  users.users.root.initialPassword = "toor";

  services.hortusfox-web = {
    enable = true;
    proxy.server = "nginx";
    # No real domain/internet-reachable cert here, so serve plain HTTP --
    # otherwise forceSSL+enableACME breaks the VM (see justfile's hostfwd
    # to test over http://localhost:8080/).
    proxy.ssl = false;
    # Matches justfile's hostfwd (host 127.0.0.1:8080 -> guest 80), so
    # login/session redirects land back on the forwarded port instead of
    # the guest's own (unforwarded) port 80.
    port = 8080;
    adminAccount.passwordFile = ./hortusfox_web_test_password;
    secretFile = ./test.env;
    settings.APP_DEBUG = true;
  };

  networking.firewall.enable = false;

  services.resolved.enable = true;
}
