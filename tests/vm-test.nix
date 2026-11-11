# One nixosTest per proxy backend: boots the service, waits for the
# backend-specific web server unit, and exercises both a dynamic (PHP-FPM)
# and a static (nginx/caddy's own) request path. Called once per backend
# from flake.nix's `checks`.
{ pkgs, nixosModule, proxyServer }:

let
  # Known plaintext, embedded directly into the curl login POST below --
  # this is a throwaway test VM's password, not a real secret.
  adminPassword = "correct-horse-battery-staple";
in

pkgs.testers.nixosTest {
  name = "hortusfox-web-${proxyServer}";

  nodes.machine = {
    imports = [ nixosModule ];

    services.hortusfox-web = {
      enable = true;
      proxy.server = proxyServer;
      proxy.ssl = false; # no internet/ACME inside the test VM
      settings.APP_DEBUG = true; # required for `php asatru migrate:*` to run
      adminAccount.passwordFile = pkgs.writeText "hortusfox-test-admin-password" adminPassword;
    };
  };

  testScript = ''
    machine.wait_for_unit("mysql.service")
    machine.wait_for_unit("hortusfox-setup.service")
    machine.wait_for_unit("phpfpm-hortusfox.service")
    machine.wait_for_unit("${proxyServer}.service")
    machine.wait_for_open_port(80)
    # -L: "/" redirects to the login page (/auth) for a logged-out
    # user -- following it is what actually exercises the page that
    # broke before (a bare "/" 302 response has no exception text
    # to catch).
    response = machine.succeed("curl -sfL http://localhost/")

    # A <400 response alone isn't enough -- Asatru renders uncaught
    # exceptions as HTML without failing the HTTP status, so a plain
    # `curl -sf` above would happily "succeed" on a broken app (this
    # is exactly how the runtime-tree symlink-vs-copy bug slipped
    # past this check before). Fail loudly on that page instead.
    assert "Asatru PHP - Exception" not in response, (
        f"got an Asatru exception page instead of the real site:\n{response}"
    )

    # Also fetch a real static asset directly (the proxy's own job, not
    # PHP-FPM's) -- the login page's background image, which ships in
    # the package itself. This is what actually exercises the proxy
    # reading into stateDir's writable subdirs (public/img here), as
    # opposed to the runtime tree checked above.
    machine.succeed("curl -sf http://localhost/img/pattern.jpg -o /dev/null")

    # PHP-FPM runs as the hortusfox user and can serve pages even when
    # the proxy (a different user) can't read the runtime tree at all --
    # so a passing response above doesn't rule this out on its own. Check
    # the proxy's own log directly, and only after every request made so
    # far, so a permission error on any of them (runtime tree or
    # persistent state dir) gets caught here.
    machine.fail("journalctl -u ${proxyServer} --no-pager | grep -qi 'permission denied'")

    # Exercise the actual point of adminAccount.passwordFile: log in as the
    # seeded admin, not just confirm a login form renders. migrate:fresh
    # alone creates no user rows, so this is the only way any account gets
    # to exist at all -- worth proving it actually works end to end.
    machine.succeed(
        "curl -sc /tmp/cookies -o /tmp/auth.html -L http://localhost/"
    )
    csrf_token = machine.succeed(
        "sed -n 's/.*name=\"csrf_token\" value=\"\([^\"]*\)\".*/\\1/p' /tmp/auth.html | head -1"
    ).strip()
    assert csrf_token, "could not find a csrf_token on the /auth page"

    # -w appends the final URL after a marker, so we can tell *where* we
    # landed -- the dashboard itself also has a (normally hidden) change-
    # password form in its markup, so checking for a password input isn't
    # a reliable way to tell it apart from the login page.
    raw = machine.succeed(
        "curl -sb /tmp/cookies -c /tmp/cookies -L -w '\\n===URL===%{url_effective}' "
        "--data-urlencode email=admin@localhost "
        "--data-urlencode password=${adminPassword} "
        f"--data-urlencode csrf_token={csrf_token} "
        "--data-urlencode redirect=/ "
        "http://localhost/login"
    )
    login_response, final_url = raw.rsplit("\n===URL===", 1)
    assert "Asatru PHP - Exception" not in login_response, (
        f"login crashed instead of succeeding:\n{login_response}"
    )
    assert "/auth" not in final_url, (
        f"login didn't redirect away from /auth -- login failed (landed on {final_url}):\n{login_response}"
    )

    # The cron units curl the app's own cronjob endpoints with a `?cronpw=`
    # query param matching AppModel.cronjob_pw -- exercise one directly
    # rather than just trusting it, since this exact wiring broke silently
    # in production (every cron request 403'd, forever, with nothing short
    # of reading the journal ever surfacing it) before this assertion existed.
    machine.succeed("systemctl start hortusfox-cron-tasks-recurring.service")

    # Regression check for the All Plants view (app/views/plants_all.php,
    # routed at GET /plants/all): reuses the authenticated cookie jar from
    # the login above, so this is exercising the real route/controller/view
    # wiring end to end in a deployed instance, not just a template render.
    all_plants_response = machine.succeed(
        "curl -sb /tmp/cookies -c /tmp/cookies -fL http://localhost/plants/all"
    )
    assert "Asatru PHP - Exception" not in all_plants_response, (
        f"got an Asatru exception page from /plants/all:\n{all_plants_response}"
    )
    assert "All Plants" in all_plants_response, (
        f"/plants/all response is missing the expected page title:\n{all_plants_response}"
    )

    # Regression check: hortusfox-setup must seed PlantDefAttrModel and
    # CalendarClassModel on every boot (not just migrate schema), or every
    # plant_attr(...) check (app/helper/AppHelper.php) silently swallows a
    # "does not exist" exception to false, hiding the Set watered/repotted/
    # fertilised buttons and individual attribute fields app-wide with no
    # error surfaced anywhere -- this exact gap shipped once already.
    attr_count = machine.succeed(
        "mariadb -N hortusfox -e 'SELECT COUNT(*) FROM PlantDefAttrModel'"
    ).strip()
    assert attr_count != "0", "PlantDefAttrModel is empty -- plants:attributes was never seeded"

    class_count = machine.succeed(
        "mariadb -N hortusfox -e 'SELECT COUNT(*) FROM CalendarClassModel'"
    ).strip()
    assert class_count != "0", "CalendarClassModel is empty -- calendar:classes was never seeded"
  '';
}
