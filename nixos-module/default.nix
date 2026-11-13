{ config, lib, pkgs, ... }:

let
  cfg = config.services."hortusfox-web";

  # The app's own canonical URL (used for login/session redirects and cron
  # requests) must track proxy.ssl, or a plain-HTTP deployment (proxy.ssl =
  # false, e.g. the test VM) redirects users to an https:// URL nothing is
  # listening on.
  scheme = if cfg.proxy.ssl then "https" else "http";
  portSuffix = if cfg.port == null then "" else ":${toString cfg.port}";
  appUrl = "${scheme}://${cfg.domain}${portSuffix}";

  # PHP with the extensions HortusFox needs, matching this repo's own
  # dockerfile (pdo_mysql, mbstring, exif, pcntl, bcmath, intl, zip, gd).
  phpPackage = cfg.phpPackage.withExtensions ({ enabled, all }:
    enabled ++ (with all; [ pdo_mysql mbstring exif pcntl bcmath intl zip gd ]));

  package = cfg.package;
  appRoot = "${package}/share/php/hortusfox-web";

  runDir = "/run/hortusfox/www";     # ephemeral symlink tree (tmpfs)
  stateDir = "/var/lib/hortusfox";   # persistent writable data

  # The app's CronjobsController requires a `?cronpw=` query param matching
  # AppModel.cronjob_pw (see the admin-seed INSERT below) -- cache that
  # value here, readable only by cfg.user, so the cron units below can read
  # it back at request time without ever going through Nix (cronjob_pw is
  # DB-generated at install time, not a Nix-level secret).
  cronPwFile = "${stateDir}/.cronjob-pw";

  # Writable subdirs that must survive reboots. app/migrations matters more
  # than it looks: it holds verhist.json (gitignored, never shipped in the
  # package -- see upstream's own dockerfile, which VOLUMEs this exact
  # directory for the same reason), which `php asatru migrate:upgrade`
  # uses to know which version-specific upgrade steps it's already run.
  # Without persisting it, every boot starts from an empty history, and
  # MigrationUpgrade (app/commands/MigrationUpgrade.php) defaults the
  # "previous version" to the *current* version whenever history is empty
  # -- collapsing the upgrade range to nothing and silently skipping every
  # intermediate version's schema changes (e.g. AppModel.date_format/
  # time_format, added in the 6.2 step) forever, with no error anywhere.
  writableDirs = [
    "cache" "app/logs" "app/migrations"
    "public/img" "public/attachments" "public/backup" "public/themes"
  ];

  # systemd-tmpfiles "age" overrides for specific writableDirs (default: "-",
  # never auto-cleaned). public/backup is HortusFox's own export/auto-backup
  # destination, named with a fully predictable `hf_backup_<timestamp>.zip`
  # pattern (see BackupModule/BackupController upstream) and -- since it
  # lives under public/, served as a real static file by nginx/caddy before
  # ever reaching the app's own auth-gated routes -- effectively downloadable
  # by anyone who knows or guesses that timestamp, indefinitely, since
  # upstream never deletes it (the auto-backup cron only does so when an
  # external backup_path is also configured in the admin panel; the manual
  # "Export" flow never does). We can't fix upstream's public-webroot
  # placement or predictable naming from here, but pruning anything older
  # than backupMaxAge bounds how long a given export stays fetchable, via
  # systemd's own periodic systemd-tmpfiles-clean.timer.
  writableDirAges = {
    "public/backup" = if cfg.backupMaxAge == null then "-" else cfg.backupMaxAge;
  };

  # Intermediate parent dirs of the above (e.g. "app", "public") that need
  # their own explicit tmpfiles rule too: systemd-tmpfiles auto-vivifies a
  # missing parent when processing a nested `d` line, but does so with
  # default (root:root 0755) ownership and does NOT reliably go on to
  # create the requested leaf itself -- so a nested writableDirs entry
  # whose parent has no rule of its own silently never gets created.
  writableDirParents = lib.unique (builtins.filter (p: p != null) (map
    (d:
      let parts = lib.splitString "/" d;
      in if builtins.length parts > 1 then lib.concatStringsSep "/" (lib.init parts) else null)
    writableDirs));

  # Escape a value for interpolation into a single-quoted SQL string literal
  # (used for the admin-seed INSERT below). Doubling backslashes first, then
  # quotes, matches MySQL/MariaDB's default (backslash-escapes-active)
  # string literal rules -- without this, an ordinary value like "O'Brien"
  # breaks the INSERT's SQL syntax outright (failing hortusfox-setup on
  # first boot, since the script runs under `set -euo pipefail`), and a
  # crafted value could inject arbitrary SQL.
  sqlEscape = s: lib.replaceStrings [ "\\" "'" ] [ "\\\\" "''" ] s;

  # Render one KEY=VALUE .env line. Booleans/ints/floats are left bare so
  # Asatru's datatype auto-detection picks them up as such rather than string.
  mkEnvLine = name: value:
    let
      rendered =
        if builtins.isBool value then (if value then "true" else "false")
        else if builtins.isInt value then toString value
        else if builtins.isFloat value then toString value
        else ''"${toString value}"'';
    in
    "${name}=${rendered}";

  # Base .env content; `settings` can override or extend any of this. Beyond
  # our own curated options (domain/timezone/db/smtp), this also seeds every
  # other key from upstream's .env.example that app code reads directly from
  # $_ENV without an isset() guard -- e.g. APP_BASEDIR, omitted here before,
  # produced a "PHP Warning: Undefined array key" on every single request.
  envVars = {
    APP_NAME = "HortusFox";
    APP_VERSION = package.version or "unknown";
    APP_AUTHOR = "Daniel Brendel";
    APP_CONTACT = "dbrendel1988@gmail.com";
    APP_DEBUG = false;
    APP_BASEDIR = "";
    APP_LANG = cfg.language;
    APP_WORKSPACE = cfg.workspace;
    APP_OVERDUETASK_HOURS = 10;
    APP_CRONJOB_MAILLIMIT = 5;
    APP_GITHUB_URL = "https://github.com/danielbrendel/hortusfox-web";
    APP_SERVICE_URL = "https://www.hortusfox.com";
    APP_GITHUB_SPONSOR = "https://github.com/sponsors/danielbrendel";
    APP_DONATION_KOFI = "https://ko-fi.com/danielbrendel";
    APP_URL = appUrl;
    APP_TIMEZONE = cfg.timezone;

    SESSION_ENABLE = true;
    SESSION_DURATION = 32532000;
    # SESSION_NAME deliberately omitted: the app only uses it behind an
    # isset() guard, so "unset" (fall back to PHP's own default) is safe.

    PHOTO_RESIZE_FACTOR_DEFAULT = 1.0;
    PHOTO_RESIZE_FACTOR_1 = 0.5;
    PHOTO_RESIZE_FACTOR_2 = 0.4;
    PHOTO_RESIZE_FACTOR_3 = 0.4;
    PHOTO_RESIZE_FACTOR_4 = 0.3;
    PHOTO_RESIZE_FACTOR_5 = 0.2;

    DB_ENABLE = true;
    DB_DRIVER = "mysql";
    DB_HOST = "localhost";
    DB_PORT = 3306;
    DB_DATABASE = cfg.database.name;
    DB_USER = cfg.user;
    DB_PASSWORD = "";
    DB_CHARSET = "utf8mb4";

    SMTP_AUTH = true;
    SMTP_FROMNAME = cfg.smtp.fromName;
    SMTP_FROMADDRESS = cfg.smtp.fromAddress;
    SMTP_HOST = cfg.smtp.host;
    SMTP_PORT = cfg.smtp.port;
    SMTP_USERNAME = cfg.smtp.username;
    SMTP_ENCRYPTION = cfg.smtp.encryption;

    LOG_ENABLE = true;
  } // cfg.settings;

  envFile = pkgs.writeText "hortusfox.env" (
    lib.concatStringsSep "\n" (lib.mapAttrsToList mkEnvLine envVars) + "\n"
  );

  # Cron jobs curl the app's own loopback address rather than its
  # externally-reachable appUrl, on the port nginx/caddy actually listen on
  # (80, or 443 when proxy.ssl -- never cfg.port, which per its own option
  # doc doesn't change that). Otherwise cron would depend on the host being
  # able to route back to its own public domain (hairpin NAT, not
  # guaranteed) and, whenever cfg.port is set to an externally-forwarded
  # port nginx/caddy don't themselves listen on (e.g. the QEMU test VM's
  # hostfwd), would curl a port nothing is listening on at all. curl's
  # --resolve pins the connection to 127.0.0.1 while keeping the
  # Host header/SNI as cfg.domain, so vhost routing and cert validation
  # still work normally.
  cronPort = if cfg.proxy.ssl then 443 else 80;
  cronUrl = path: "${scheme}://${cfg.domain}:${toString cronPort}${path}";

  # The actual ExecStart for each cron unit: read the cached cronjob_pw
  # (written by hortusfox-setup) and append it as the `?cronpw=` query param
  # CronjobsController requires, or every cron request gets a bare 403.
  # -X POST is required too, separately from the auth check: every route
  # under app/config/routes.php's "Cronjob Controller" section is
  # registered POST-only, and a GET against a route the router has no GET
  # entry for returns the app's own 404 page -- silent/easy to miss since
  # it looks like routing failure, not an auth failure, even though the
  # cronpw itself was already correct.
  # A wrapper script rather than a plain curl invocation because systemd's
  # ExecStart doesn't run through a shell, so it can't itself do the
  # `$(cat ...)` substitution.
  cronScript = name: job: pkgs.writeShellScript "hortusfox-cron-${name}" ''
    set -euo pipefail
    cronpw="$(${pkgs.coreutils}/bin/cat "${cronPwFile}")"
    exec ${pkgs.curl}/bin/curl -fsS --max-time 300 -X POST \
      --resolve ${cfg.domain}:${toString cronPort}:127.0.0.1 \
      "${cronUrl job.path}?cronpw=$cronpw"
  '';

  # Baseline systemd sandboxing shared by this module's own units
  # (hortusfox-setup and the cron jobs; phpfpm-hortusfox gets its own,
  # layered on top of what services.phpfpm already sets). Deliberately
  # conservative: no MemoryDenyWriteExecute (PHP/Zend may want executable
  # heap for opcache) and no SystemCallFilter (broad surface, easy to break
  # something subtle in migrations/mysql/zip handling) -- this is a first
  # pass at blast-radius reduction, not maximal hardening. RestrictAddress-
  # Families keeps AF_INET/AF_INET6 (SMTP, cron's loopback curl) alongside
  # AF_UNIX (the mysql socket). Deliberately no UMask override: this
  # module's whole design (see the "world-readable 0755" notes elsewhere)
  # depends on hortusfox-setup's and phpfpm's default umask producing
  # world-readable files/dirs (0755/0644) for nginx/caddy, a different
  # user, to traverse and serve statically -- a tighter umask (e.g. 0027)
  # silently reintroduces the exact "Permission denied" static-asset bug
  # that was already fixed once, since a later `chmod u+w` only adds the
  # owner-write bit back and can't restore group/other bits umask stripped
  # at creation time.
  commonHardening = {
    NoNewPrivileges = true;
    ProtectHome = true;
    PrivateTmp = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    RestrictNamespaces = true;
    LockPersonality = true;
    RemoveIPC = true;
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
  };

  # curl'd cron endpoints -> (name, path, calendar spec)
  cronjobs = {
    "tasks-overdue"    = { path = "/cronjob/tasks/overdue";    when = "*-*-* 06,18:00:00"; };
    "tasks-tomorrow"   = { path = "/cronjob/tasks/tomorrow";   when = "*-*-* 06,18:00:00"; };
    "tasks-recurring"  = { path = "/cronjob/tasks/recurring";  when = "hourly"; };
    "calendar-reminder"= { path = "/cronjob/calendar/reminder";when = "*-*-* 07:00:00"; };
    "backup-auto"      = { path = "/cronjob/backup/auto";      when = "*-*-* 03:00:00"; };
  };
in {
  options.services."hortusfox-web" = {
    enable = lib.mkEnableOption "HortusFox plant management system";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "localhost";
      example = "plants.example.com";
      description = "FQDN served over HTTPS (used for the nginx vhost + ACME).";
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      example = 8080;
      description = ''
        Port to append to the app's own canonical URL (APP_URL, used for
        login/session redirects and cron requests). Leave unset for a normal
        deployment reachable on the standard 80/443. Set this when the proxy
        is only reachable through a non-standard or forwarded port -- e.g.
        the QEMU test VM's hostfwd (see justfile) -- otherwise redirects
        drop the port and land somewhere unreachable. This does not change
        what port nginx/caddy actually listen on.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../package.nix { };
      description = "HortusFox package to deploy.";
    };

    proxy.server = lib.mkOption {
      type = lib.types.enum [ "nginx" "caddy" ];
      default = "nginx";
      description = "Reverse proxy/webserver to front phpfpm.";
    };

    proxy.ssl = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to force HTTPS and request an ACME certificate for the
        vhost. Disable for local/test deployments that have no real domain
        or internet access to reach Let's Encrypt.
      '';
    };

    phpPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.php83;
      description = "Base PHP used to build the phpfpm environment.";
    };

    user = lib.mkOption { type = lib.types.str; default = "hortusfox"; };
    group = lib.mkOption { type = lib.types.str; default = "hortusfox"; };

    timezone = lib.mkOption { type = lib.types.str; default = "UTC"; };

    language = lib.mkOption {
      type = lib.types.str;
      default = "en";
      example = "de";
      description = ''
        UI language (APP_LANG). Must match one of the language codes
        upstream ships translation files for under lang/.
      '';
    };

    workspace = lib.mkOption {
      type = lib.types.str;
      default = "My workspace";
      example = "Greenhouse";
      description = "Workspace name shown in the UI (APP_WORKSPACE).";
    };

    database.name = lib.mkOption { type = lib.types.str; default = "hortusfox"; };

    secretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/agenix/hortusfox.env";
      description = ''
        File with secret KEY=VALUE lines (APP_KEY, SMTP_PASSWORD, API keys,
        ...) appended verbatim to the generated .env at runtime. Keep it out
        of the Nix store in production (e.g. agenix/sops-nix); a store path
        is fine for throwaway test configs. Read by hortusfox-setup, which
        runs as cfg.user rather than root -- if you point this at an
        agenix/sops-nix secret, make sure its owner/group is set to
        cfg.user/cfg.group (or make it world-readable), or the service fails
        with a permission error.
      '';
    };

    backupMaxAge = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1d";
      example = "7d";
      description = ''
        How long HortusFox's own export/auto-backup zips (written to
        public/backup, using systemd-tmpfiles "age" syntax, e.g. "1d",
        "12h") are kept before being auto-deleted. HortusFox names these
        files with a fully predictable hf_backup_<timestamp>.zip pattern and
        serves them from the public webroot without ever cleaning them up
        itself, so anyone who knows or guesses the timestamp can download a
        full data export indefinitely otherwise. Set to null to disable
        cleanup entirely (not recommended for internet-facing deployments).
      '';
    };

    adminAccount.passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File containing the initial admin account's password (plaintext,
        no trailing newline needed). HortusFox has no CLI/seed hook of its
        own for this -- its only "create user" flow lives in the admin
        panel, which itself requires already being logged in as an admin,
        and `migrate:fresh` creates no user rows at all. Without this set,
        a fresh deployment has no way to log in at all. Only used on first
        boot (guarded by the same stateDir/.installed marker as
        migrate:fresh); changing it afterwards has no effect on an
        existing account. Read by hortusfox-setup, which runs as cfg.user
        rather than root -- as with secretFile, make sure this file's
        owner/group lets cfg.user read it.

        Seeds a user (name set via adminAccount.username, email via
        adminAccount.email), bcrypt-hashed via
        `password_hash(..., PASSWORD_BCRYPT)` (matching UserModel's own
        hashing) and inserted directly into the UserModel table with the
        admin flag set, bypassing the app's normal two-step
        create-then-promote admin-panel flow.
      '';
    };

    adminAccount.username = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      example = "Jane Doe";
      description = ''
        Name for the seeded admin account (see adminAccount.passwordFile) --
        the UserModel table's "name" column. HortusFox logs in by email, not
        this field, so it's purely a display name shown in the app's UI.
      '';
    };

    adminAccount.email = lib.mkOption {
      type = lib.types.str;
      default = "admin@${cfg.domain}";
      example = "you@realmail.com";
      description = ''
        Email address for the seeded admin account (see
        adminAccount.passwordFile). Defaults to admin@<domain>, but that's
        just a guess -- it's not necessarily a mailbox anyone can actually
        receive mail at, and HortusFox's own "Restore password" flow emails
        this address. Set it to a real address you control if you intend to
        use password reset.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [ lib.types.str lib.types.int lib.types.bool ]);
      default = { };
      example = { APP_DEBUG = true; APP_OVERDUETASK_HOURS = 6; };
      description = ''
        Extra/overriding .env entries, merged over the generated defaults.
        Note that the `php asatru` CLI (used here for migrations) only runs
        when APP_DEBUG is true, so migrations silently no-op unless that's
        set here or in secretFile.
      '';
    };

    smtp = {
      host = lib.mkOption { type = lib.types.str; default = ""; };
      port = lib.mkOption { type = lib.types.port; default = 587; };
      username = lib.mkOption { type = lib.types.str; default = ""; };
      fromName = lib.mkOption { type = lib.types.str; default = "HortusFox"; };
      fromAddress = lib.mkOption { type = lib.types.str; default = "hortusfox@localhost"; };
      encryption = lib.mkOption { type = lib.types.enum [ "tls" "ssl" "" ]; default = "tls"; };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(cfg.proxy.ssl && cfg.domain == "localhost");
        message = ''
          services.hortusfox-web: proxy.ssl = true (the default) requests an
          ACME certificate for services.hortusfox-web.domain, but domain is
          left at its own default of "localhost" -- Let's Encrypt can never
          issue a certificate for that, so this would only fail at runtime.
          Set domain to a real, publicly resolvable FQDN, or set
          proxy.ssl = false for a local/test deployment.
        '';
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = stateDir;
    };
    users.groups.${cfg.group} = { };

    # --- Database: unix-socket auth, no password needed ------------------
    services.mysql = {
      enable = true;
      package = pkgs.mariadb_114;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [{
        name = cfg.user;
        ensurePermissions = { "${cfg.database.name}.*" = "ALL PRIVILEGES"; };
      }];
    };

    # --- Persistent writable dirs ---------------------------------------
    # World-readable (0755), same reasoning as RuntimeDirectoryMode above:
    # some of these (public/*) are nginx's webroot, and nginx (a different
    # user) needs to traverse them directly. Nothing secret lives at the
    # directory level -- .env (the one real secret under stateDir) is a
    # separate file installed at mode 600, unaffected by this.
    systemd.tmpfiles.rules =
      [ "d ${stateDir} 0755 ${cfg.user} ${cfg.group} - -" ]
      ++ map (d: "d ${stateDir}/${d} 0755 ${cfg.user} ${cfg.group} - -") writableDirParents
      ++ map (d: "d ${stateDir}/${d} 0755 ${cfg.user} ${cfg.group} ${writableDirAges.${d} or "-"} -") writableDirs;

    # Kept as one attrset: hortusfox-setup/phpfpm-hortusfox plus the
    # cron-generated services all live under systemd.services, and a
    # separate full reassignment (as the cron block used to be) would
    # conflict with these partial-path definitions.
    systemd.services = {
      hortusfox-setup = {
        description = "Prepare HortusFox runtime tree and run migrations";
        after = [ "mysql.service" "network.target" ];
        requires = [ "mysql.service" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = commonHardening // {
          Type = "oneshot";
          RemainAfterExit = true;
          User = cfg.user;
          Group = cfg.group;
          StateDirectory = "hortusfox";
          # World-readable: nginx (a different user) needs to stat/read
          # everything under here to serve `public/` directly. Nothing
          # secret lives in this tree -- .env is a symlink to stateDir/.env,
          # which stays mode 600 regardless of this.
          RuntimeDirectory = "hortusfox";
          RuntimeDirectoryMode = "0755";
          # Whole filesystem read-only except /dev, /proc, /sys and the
          # StateDirectory/RuntimeDirectory declared above, which systemd
          # auto-exempts -- everything this script writes to (stateDir,
          # runDir) is covered by those, so no extra ReadWritePaths needed.
          ProtectSystem = "strict";
        };

        path = [ phpPackage config.services.mysql.package pkgs.coreutils pkgs.gnused ];

        script = ''
          set -euo pipefail

          # 1. Mirror the read-only store package into a writable-structured
          #    tree with a real (non-symlinked) copy of every file. This
          #    duplicates the app into tmpfs on every boot -- NOT `cp -rs`
          #    (per-file symlinks back into the store): PHP resolves
          #    __DIR__/__FILE__ through symlinks to their real target, so
          #    any symlinked file here would see itself as living in the
          #    read-only store rather than under runDir, breaking the
          #    app's own self-relative path lookups (its .env discovery
          #    included). `cp` carries the store's read-only directory
          #    mode (555) onto the new directories, so reopen them for
          #    writing -- only directories, since we never need to touch
          #    the copied files' own permissions.
          rm -rf "${runDir}"
          mkdir -p "${runDir}"
          cp -r "${appRoot}/." "${runDir}/"
          find "${runDir}" -type d -exec chmod u+w {} +

          # 2. Swap the writable subdirs for persistent state dirs. Some of
          #    these (public/img, public/themes) ship real default assets
          #    (backgrounds, the default theme) in the package, not just
          #    user-generated content -- seed the persistent copy from the
          #    package on every boot, without ever clobbering what's
          #    already there, before replacing the dir with a symlink to
          #    it. Harmless no-op for dirs that ship nothing but the app's
          #    own .gitignore.
          ${lib.concatMapStringsSep "\n" (d: ''
            mkdir -p "${stateDir}/${d}"
            cp -rn "${appRoot}/${d}/." "${stateDir}/${d}/" || true
            find "${stateDir}/${d}" -type d -exec chmod u+w {} +
            rm -rf "${runDir}/${d}"
            ln -sfn "${stateDir}/${d}" "${runDir}/${d}"
          '') writableDirs}

          # 3. Render .env: static body + secrets from secretFile (if any),
          #    appended verbatim.
          install -m600 /dev/null "${stateDir}/.env"
          cat ${envFile} > "${stateDir}/.env"
          ${lib.optionalString (cfg.secretFile != null) ''
            {
              echo ""
              cat "${cfg.secretFile}"
            } >> "${stateDir}/.env"
          ''}
          ln -sfn "${stateDir}/.env" "${runDir}/.env"

          # 4. Migrate. First boot builds the schema (destructive fresh); later
          #    boots only upgrade. The marker guards you from nuking your data.
          cd "${runDir}"
          if [ ! -e "${stateDir}/.installed" ]; then
            php asatru migrate:fresh

            # 5. Seed the AppModel settings row. migrate:fresh only creates
            #    the (empty) table -- upstream's own web installer is what
            #    inserts the single settings row that app()/AppModel's own
            #    admin-panel features (the Environment tab's Language/
            #    Timezone fields, SMTP toggle, etc.) read and write, and we
            #    bypass that installer entirely. Without this row,
            #    AppModel::updateSet()'s `UPDATE AppModel SET ...` -- no
            #    WHERE clause, since it's a de-facto single-row table --
            #    matches zero rows, so every "Save" in the admin Environment
            #    tab reports success but silently changes nothing. This
            #    includes Language/Timezone: those live here, not in .env
            #    (.env's APP_LANG is only a fallback used when this row is
            #    missing, and APP_TIMEZONE only sets PHP's global default
            #    timezone -- see AppHelper.php/bootstrap.php upstream,
            #    neither is what the admin UI's fields actually edit). It
            #    also means app_mail_config() -- called at the top of every
            #    single request/cronjob -- was overwriting $_ENV['SMTP_*']
            #    with NULLs read from this nonexistent row on every request,
            #    silently breaking outbound mail regardless of smtp.*/
            #    secretFile; seeding smtp_* here fixes that too. smtp_password
            #    is deliberately left NULL: it's secret-only (see
            #    secretFile), not a plain Nix option, and leaving it NULL is
            #    no regression versus the previous (rowless) behavior either
            #    way. cronjob_pw is generated the same way AppModel's own
            #    generateCronjobToken() does. Every other column either has
            #    no corresponding Nix option yet or just mirrors the
            #    migration's own column default, same as upstream's
            #    installer does.
            cronjob_pw="$(php -r 'echo md5(random_bytes(55) . date("Y-m-d H:i:s"));')"
            # Cache it for the cron units (see cronScript above) -- this is
            # the only place that ever learns the value in plaintext outside
            # the DB itself.
            printf '%s' "$cronjob_pw" > "${cronPwFile}"
            chmod 600 "${cronPwFile}"
            mariadb "${cfg.database.name}" -e "INSERT INTO AppModel (id, workspace, language, timezone, scroller, chat_enable, chat_timelimit, chat_showusers, chat_indicator, chat_system, history_enable, history_name, enable_media_share, cronjob_pw, overlay_alpha, smtp_enable_auth, smtp_fromname, smtp_fromaddress, smtp_host, smtp_port, smtp_username, smtp_password, smtp_encryption, pwa_enable, owm_enable, owm_api_key, owm_latitude, owm_longitude, owm_unittype, owm_cache) VALUES (NULL, '${sqlEscape envVars.APP_WORKSPACE}', '${sqlEscape cfg.language}', '${sqlEscape cfg.timezone}', 1, 1, 5, 1, 1, 1, 1, 'History', 0, '$cronjob_pw', NULL, 1, '${sqlEscape cfg.smtp.fromName}', '${sqlEscape cfg.smtp.fromAddress}', '${sqlEscape cfg.smtp.host}', ${toString cfg.smtp.port}, '${sqlEscape cfg.smtp.username}', NULL, '${sqlEscape cfg.smtp.encryption}', 0, 0, NULL, NULL, NULL, 'default', 300);"

            # 6. Seed the initial admin account. migrate:fresh creates no
            #    user rows at all, and the app's only "create user" flow
            #    lives behind the admin panel -- without this, a fresh
            #    deployment has no way to log in, ever. Insert directly
            #    (name/email hardcoded, bypassing the app's normal
            #    create-then-promote-to-admin two-step flow) rather than
            #    going through any app-level API, since none exists yet at
            #    this point.
            ${lib.optionalString (cfg.adminAccount.passwordFile != null) ''
              admin_hash="$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$(cat "${cfg.adminAccount.passwordFile}")")"
              mariadb "${cfg.database.name}" -e "INSERT INTO UserModel (name, email, password, admin) VALUES ('${sqlEscape cfg.adminAccount.username}', '${sqlEscape cfg.adminAccount.email}', '$admin_hash', 1);"
            ''}

            touch "${stateDir}/.installed"
          else
            php asatru migrate:upgrade || true
          fi

          # Seed default plant attributes (last_watered, last_repotted, ...)
          # and calendar classes (water, repot, fertilise, ...) on every boot,
          # not just first boot -- docker-entrypoint.sh does the same.
          # migrate:fresh only creates these tables' schema, empty; without
          # this, every plant_attr('last_watered')/etc. check in the app
          # (app/helper/AppHelper.php) throws on the missing row and is
          # silently swallowed to `false`, hiding the "Set watered"/"Set
          # repotted"/"Set fertilised" bulk-action buttons (and the
          # individual attribute fields on plant detail pages) everywhere,
          # with no error surfaced anywhere. Both commands are themselves
          # idempotent no-ops once the respective table already has rows
          # (see AttributesCommand/CalendarClsCommand), so this is safe and
          # cheap to run unconditionally on every boot, and self-heals an
          # existing deployment that was missing this.
          php asatru plants:attributes
          php asatru calendar:classes

          # Backfill for deployments that installed before cronjob_pw was
          # cached to disk (it's always been DB-only until now): pull the
          # value AppModel already has back out, rather than regenerating
          # one that wouldn't match it.
          if [ ! -s "${cronPwFile}" ]; then
            mariadb -N "${cfg.database.name}" -e "SELECT cronjob_pw FROM AppModel LIMIT 1" > "${cronPwFile}"
            chmod 600 "${cronPwFile}"
          fi
        '';
      };

      phpfpm-hortusfox = {
        after = [ "hortusfox-setup.service" ];
        requires = [ "hortusfox-setup.service" ];
        # services.phpfpm already sets a reasonable baseline (PrivateTmp,
        # ProtectHome, ProtectSystem = "full", RestrictAddressFamilies).
        # Tighten ProtectSystem to "strict" (whole filesystem read-only
        # except /dev, /proc, /sys and explicit exceptions) -- stateDir is
        # the only path phpfpm actually needs to write to, since every
        # writable subdir under runDir is a symlink resolving there; runDir
        # itself (the app code) only needs to be read, which ProtectSystem
        # doesn't restrict. mkForce is needed since services.phpfpm sets
        # ProtectSystem = "full" as a plain (non-mkDefault) assignment.
        serviceConfig.ProtectSystem = lib.mkForce "strict";
        serviceConfig.ReadWritePaths = [ stateDir ];
      };
    } // (lib.mapAttrs' (name: job:
      lib.nameValuePair "hortusfox-cron-${name}" {
        description = "HortusFox cronjob: ${name}";
        after = [ "${cfg.proxy.server}.service" ];
        serviceConfig = commonHardening // {
          Type = "oneshot";
          User = cfg.user;
          ExecStart = "${cronScript name job}";
          # Only touches the filesystem to read cronPwFile back -- stateDir
          # stays visible (read-only) under ProtectSystem=strict since it
          # isn't under /home, so no ReadWritePaths/ReadOnlyPaths needed.
          ProtectSystem = "strict";
          ProtectHome = "tmpfs";
        };
      }) cronjobs);

    systemd.timers = lib.mapAttrs' (name: job:
      lib.nameValuePair "hortusfox-cron-${name}" {
        description = "Timer for HortusFox cronjob: ${name}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = job.when;
          Persistent = true;
        };
      }) cronjobs;

    # --- phpfpm pool ------------------------------------------------------
    services.phpfpm.pools.hortusfox = {
      user = cfg.user;
      group = cfg.group;
      phpPackage = phpPackage;
      # PHP's own stock defaults (upload_max_filesize=2M, post_max_size=8M)
      # are far below what both proxy configs below already allow through
      # (nginx's client_max_body_size / caddy's request_body.max_size, both
      # 64M) -- without this, PHP itself truncates/rejects any plant photo
      # upload past 2M (a single modern phone camera JPEG, easily) before
      # PlantsModel::editPlantPhoto ever sees it, surfacing as a bare
      # "Errorneous file" 500 with no indication it was ever a size limit.
      phpOptions = ''
        upload_max_filesize = 64M
        post_max_size = 64M
      '';
      settings = {
        "listen.owner" = if cfg.proxy.server == "caddy" then config.services.caddy.user else config.services.nginx.user;
        "listen.group" = if cfg.proxy.server == "caddy" then config.services.caddy.group else config.services.nginx.group;
        "pm" = "dynamic";
        "pm.max_children" = 16;
        "pm.start_servers" = 2;
        "pm.min_spare_servers" = 1;
        "pm.max_spare_servers" = 4;
        "catch_workers_output" = true;
      };
    };

    # --- nginx + ACME ------------------------------------------------------
    services.nginx = lib.mkIf (cfg.proxy.server == "nginx") {
      enable = true;
      recommendedTlsSettings = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;

      virtualHosts.${cfg.domain} = {
        forceSSL = cfg.proxy.ssl;
        enableACME = cfg.proxy.ssl;

        root = "${runDir}/public";

        # Asatru front controller: everything that isn't a real file
        # rewrites to index.php (mirrors the upstream .htaccess).
        locations."/" = {
          index = "index.php";
          tryFiles = "$uri $uri/ /index.php?$query_string";
        };

        locations."~ \\.php$".extraConfig = ''
          fastcgi_split_path_info ^(.+\.php)(/.+)$;
          fastcgi_pass unix:${config.services.phpfpm.pools.hortusfox.socket};
          fastcgi_index index.php;
          include ${config.services.nginx.package}/conf/fastcgi_params;
          fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
          fastcgi_param PATH_INFO $fastcgi_path_info;
          ${lib.optionalString (cfg.port != null) ''
            # Asatru's own url()/asset() helpers (vendor/danielbrendel/asatru-php-framework/src/helper.php)
            # build every absolute URL straight from $_SERVER['SERVER_PORT'], never from APP_URL. That
            # default fastcgi_params' $server_port is the port nginx itself listens on -- e.g. the QEMU
            # test VM's unforwarded guest port 80 -- not the externally-reachable/forwarded one (8080),
            # so every asset/redirect URL silently drops the real port. Override it to match cfg.port.
            fastcgi_param SERVER_PORT "${toString cfg.port}";
          ''}
        '';

        # Don't let anyone fetch the rendered .env or app internals.
        locations."~ /\\.".extraConfig = "deny all;";

        extraConfig = ''
          client_max_body_size 64M;
        '';
      };
    };

    # --- caddy ---------------------------------------------------------
    # `proxy.ssl = false` prefixes the site address with "http://", which
    # disables Caddy's automatic HTTPS/ACME for this vhost specifically
    # (rather than needing a separate flag like nginx's forceSSL/enableACME).
    services.caddy = lib.mkIf (cfg.proxy.server == "caddy") {
      enable = true;

      virtualHosts.${if cfg.proxy.ssl then cfg.domain else "http://${cfg.domain}"}.extraConfig = ''
        root * ${runDir}/public
        encode gzip

        # Don't let anyone fetch the rendered .env or app internals.
        @dotfiles path /.*
        respond @dotfiles 403

        request_body {
          max_size 64MB
        }

        # php_fastcgi already covers the Asatru front-controller rewrite
        # (try real file, then index.php) and static file serving.
        php_fastcgi unix/${config.services.phpfpm.pools.hortusfox.socket} {
          ${lib.optionalString (cfg.port != null) ''
            # See the matching nginx fastcgi_param SERVER_PORT override above:
            # Asatru's url()/asset() helpers build absolute URLs from
            # $_SERVER['SERVER_PORT'] alone, which Caddy otherwise sets to the
            # port it's actually listening on rather than an external/forwarded one.
            env SERVER_PORT ${toString cfg.port}
          ''}
        }
        file_server
      '';
    };

    # ACME needs an email; set this once globally in your host config:
    #   nginx: security.acme = { acceptTerms = true; defaults.email = "you@example.com"; };
    #   caddy: services.caddy.email = "you@example.com";

    networking.firewall.allowedTCPPorts = [ 80 443 ];
  };
}
