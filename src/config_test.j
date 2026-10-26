# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for config.j. Run with:
#
#     jennifer test src/config_test.j
#
# Precedence: defaults, then the file, then the environment, and an absent
# setting never blanks a present one.

use testing;

func sample() {
    return 'addr = ":9000"
db = "/srv/registry.json"
tokenKey = "from-file"

[log]
file = "/var/log/jvc.log"
level = "debug"
requests = true

[identity]
provider = "gitea"
clientId = "file-client"

[forge]
provider = "gitlab"
token = "file-forge-token"

[tls]
enabled = true
domains = ["a.example.com", "b.example.com"]
email = "ops@example.com"
agreeTos = true
renewBeforeDays = 14
';
}

func noEnv() {
    def none as map of string to string init {};
    return $none;
}

# --- defaults -----------------------------------------------------------------

func testDefaultsAreTheNarrowChoice() {
    # an unconfigured deployment must not serve more than its operator asked for
    def c as Config init defaults();
    testing.assertEqual($c.addr, ":8080");
    testing.assertFalse($c.tls.enabled);
    testing.assertFalse($c.tls.agreeTos);
    testing.assertFalse($c.logRequests);
    testing.assertEqual($c.identityClientId, "");
    testing.assertEqual($c.trustpubAudience, "");
}

func testAnEmptyFileChangesNothing() {
    testing.assertEqual(applyToml(defaults(), "").addr, ":8080");
    testing.assertEqual(applyToml(defaults(), "   ").addr, ":8080");
}

# --- the file -----------------------------------------------------------------

func testTheFileIsRead() {
    def c as Config init applyToml(defaults(), sample());
    testing.assertEqual($c.addr, ":9000");
    testing.assertEqual($c.dbPath, "/srv/registry.json");
    testing.assertEqual($c.logFile, "/var/log/jvc.log");
    testing.assertEqual($c.logLevel, "debug");
    testing.assertTrue($c.logRequests);
    testing.assertEqual($c.identity, "gitea");
    testing.assertEqual($c.forge, "gitlab");
}

func testNestedTlsIsRead() {
    def c as Config init applyToml(defaults(), sample());
    testing.assertTrue($c.tls.enabled);
    testing.assertEqual(len($c.tls.domains), 2);
    testing.assertEqual($c.tls.domains[0], "a.example.com");
    testing.assertEqual($c.tls.email, "ops@example.com");
    testing.assertEqual($c.tls.renewBeforeDays, 14);
    # untouched by the file, so still the default
    testing.assertEqual($c.tls.certDir, "data/tls");
}

func testAKeyTheFileOmitsKeepsItsDefault() {
    def c as Config init applyToml(defaults(), 'addr = ":9999"' + "\n");
    testing.assertEqual($c.addr, ":9999");
    testing.assertEqual($c.dbPath, "data/decks.json");
    testing.assertEqual($c.logFormat, "logfmt");
}

func testAMalformedFileThrows() {
    # refuse to start rather than run on a configuration that failed to load
    testing.assertThrows("parsesBrokenToml", "runtime");
}

func parsesBrokenToml() {
    applyToml(defaults(), "addr = \nnot toml");
    return null;
}

# --- the environment wins -----------------------------------------------------

func testTheEnvironmentOverridesTheFile() {
    def env as map of string to string init {
        "REGISTRY_ADDR": ":7000",
        "REGISTRY_IDENTITY": "oidc",
        "REGISTRY_TOKEN_KEY": "from-env"
    };
    def c as Config init applyEnv(applyToml(defaults(), sample()), $env);
    testing.assertEqual($c.addr, ":7000");
    testing.assertEqual($c.identity, "oidc");
    testing.assertEqual($c.tokenKey, "from-env");
    # what the environment did not mention stays as the file left it
    testing.assertEqual($c.dbPath, "/srv/registry.json");
    testing.assertEqual($c.forge, "gitlab");
}

func testAnEmptyVariableDoesNotBlankASetting() {
    # a stray empty value in a compose file must not erase configuration
    def env as map of string to string init {"REGISTRY_ADDR": "", "REGISTRY_DB": "   "};
    def c as Config init applyEnv(applyToml(defaults(), sample()), $env);
    testing.assertEqual($c.addr, ":9000");
    testing.assertEqual($c.dbPath, "/srv/registry.json");
}

func testABooleanCanBeTurnedOffFromTheEnvironment() {
    # "0" must be able to disable something the file enabled
    def env as map of string to string init {"REGISTRY_TLS": "0"};
    testing.assertFalse(applyEnv(applyToml(defaults(), sample()), $env).tls.enabled);
    def on as map of string to string init {"REGISTRY_TLS": "true"};
    testing.assertTrue(applyEnv(defaults(), $on).tls.enabled);
}

func testBooleanSpellings() {
    def base as bool init false;
    for (def yes in ["1", "true", "TRUE", "yes", "on"]) {
        def env as map of string to string init {"K": $yes};
        testing.assertTrue(envFlag($env, "K", $base));
    }
    for (def no in ["0", "false", "no", "off"]) {
        def env as map of string to string init {"K": $no};
        testing.assertFalse(envFlag($env, "K", true));
    }
}

func testAnUnrecognisedBooleanKeepsTheConfiguredValue() {
    # reading "maybe" as "no" would disable TLS
    def env as map of string to string init {"K": "perhaps"};
    testing.assertTrue(envFlag($env, "K", true));
    testing.assertFalse(envFlag($env, "K", false));
}

func testDomainsFromTheEnvironment() {
    def commas as map of string to string init {"REGISTRY_TLS_DOMAINS": "a.test, b.test"};
    def c as Config init applyEnv(defaults(), $commas);
    testing.assertEqual(len($c.tls.domains), 2);
    testing.assertEqual($c.tls.domains[1], "b.test");
    def spaces as map of string to string init {"REGISTRY_TLS_DOMAINS": "a.test b.test"};
    testing.assertEqual(len(applyEnv(defaults(), $spaces).tls.domains), 2);
}

# --- refusing to start --------------------------------------------------------

func testAUsableConfigurationHasNoProblem() {
    testing.assertEqual(problem(defaults()), "");
    # the sample's key is a placeholder, too short to serve with
    def c as Config init applyToml(defaults(), sample());
    $c.tokenKey = strings.repeat("k", 32);
    testing.assertEqual(problem($c), "");
}

# --- source authority (7.1 route A) -------------------------------------------

# loginsOn is a configuration that accepts logins, so the source-authority rules
# apply to it.
func loginsOn(identity as string, forge as string) {
    def c as Config init defaults();
    $c.identity = $identity;
    $c.forge = $forge;
    $c.identityClientId = "client";
    $c.tokenKey = "0123456789abcdef0123456789abcdef";
    return $c;
}

func testOneServiceDefaultsToTheLoginToken() {
    testing.assertEqual(sourceAuthorityOf(loginsOn("github", "github")), "login");
    # Forgejo logs in through the gitea identity module
    testing.assertEqual(sourceAuthorityOf(loginsOn("gitea", "forgejo")), "login");
    testing.assertEqual(problem(loginsOn("github", "github")), "");
}

func testTwoServicesDefaultToTheServiceAccount() {
    testing.assertEqual(sourceAuthorityOf(loginsOn("oidc", "gitea")), "service");
    # two self-hosted instances of one forge are two services
    def two as Config init loginsOn("gitea", "gitea");
    $two.identityBaseUrl = "https://login.example.com/";
    $two.forgeBaseUrl = "https://git.example.com";
    testing.assertEqual(sourceAuthorityOf($two), "service");
    $two.forgeBaseUrl = "https://LOGIN.example.com";
    testing.assertEqual(sourceAuthorityOf($two), "login");
}

func testAServiceAccountNeedsAToken() {
    testing.assertContains(problem(loginsOn("oidc", "gitea")), "forge.token");
    def withToken as Config init loginsOn("oidc", "gitea");
    $withToken.forgeToken = "svc";
    testing.assertEqual(problem($withToken), "");
}

func testALoginTokenCannotBeAskedOfAnotherForge() {
    def c as Config init loginsOn("oidc", "gitea");
    $c.sourceAuthority = "login";
    testing.assertContains(problem($c), "different services");
}

func testAnUnknownSourceAuthorityIsRefused() {
    def c as Config init defaults();
    $c.sourceAuthority = "trust-me";
    testing.assertContains(problem($c), "`login` or `service`");
}

func testTheOrganisationWindowReadsFileAndEnvironment() {
    testing.assertEqual(defaults().orgMaxAgeHours, 168);
    def file as Config init applyToml(defaults(), '[identity]
orgMaxAge = 24
');
    testing.assertEqual($file.orgMaxAgeHours, 24);
    def env as map of string to string init {"REGISTRY_ORG_MAX_AGE": "0"};
    testing.assertEqual(applyEnv($file, $env).orgMaxAgeHours, 0);
    def c as Config init defaults();
    $c.orgMaxAgeHours = -1;
    testing.assertContains(problem($c), "orgMaxAge");
}

func testTheWriteAndReadBudgetsReadFileAndEnvironment() {
    testing.assertEqual(defaults().writeRateLimit, 60);
    testing.assertEqual(defaults().readRateLimit, 120);
    def file as Config init applyToml(defaults(), 'writeRateLimit = 10
readRateLimit = 0
');
    testing.assertEqual($file.writeRateLimit, 10);
    testing.assertEqual($file.readRateLimit, 0);
    def env as map of string to string init {"REGISTRY_READ_RATE_LIMIT": "5"};
    testing.assertEqual(applyEnv($file, $env).readRateLimit, 5);
    def c as Config init defaults();
    $c.writeRateLimit = -1;
    testing.assertContains(problem($c), "writeRateLimit");
    $c.writeRateLimit = 0;
    $c.readRateLimit = -3;
    testing.assertContains(problem($c), "readRateLimit");
}

func testTheAuthRateLimitReadsFileAndEnvironment() {
    testing.assertEqual(defaults().authRateLimit, 30);
    def file as Config init applyToml(defaults(), '[identity]
rateLimit = 60
');
    testing.assertEqual($file.authRateLimit, 60);
    def env as map of string to string init {"REGISTRY_AUTH_RATE_LIMIT": "0"};
    testing.assertEqual(applyEnv($file, $env).authRateLimit, 0);
    def c as Config init defaults();
    $c.authRateLimit = -1;
    testing.assertContains(problem($c), "rateLimit");
}

func testUnknownProviderForgeAndPolicyNamesAreRefused() {
    # serve would otherwise wire the github module for any unknown name
    def c as Config init defaults();
    $c.identity = "gihtub";
    testing.assertContains(problem($c), "unknown identity provider \"gihtub\"");
    $c = defaults();
    $c.forge = "bitbucket";
    testing.assertContains(problem($c), "unknown forge");
    $c = defaults();
    $c.policy = "official";
    testing.assertContains(problem($c), "unknown policy");
    $c = defaults();
    $c.identity = "forgejo";
    $c.forge = "forgejo";
    testing.assertEqual(problem($c), "");
}

func testSourceAuthorityReadsFileAndEnvironment() {
    def file as Config init applyToml(defaults(), '[forge]
sourceAuthority = "service"
');
    testing.assertEqual($file.sourceAuthority, "service");
    def env as map of string to string init {"REGISTRY_SOURCE_AUTHORITY": "login"};
    testing.assertEqual(applyEnv($file, $env).sourceAuthority, "login");
}

func testWithoutLoginsNothingIsRequired() {
    # a read-only registry publishes nothing, so it needs no forge credential
    def c as Config init defaults();
    $c.identity = "oidc";
    $c.forge = "gitea";
    testing.assertEqual(problem($c), "");
}

func testTlsWithoutADomainIsRefused() {
    def env as map of string to string init {"REGISTRY_TLS": "1"};
    def c as Config init applyEnv(defaults(), $env);
    testing.assertContains(problem($c), "no tls.domains");
}

func testTlsWithoutAnEmailIsRefused() {
    def env as map of string to string init {
        "REGISTRY_TLS": "1",
        "REGISTRY_TLS_DOMAINS": "a.test",
        "REGISTRY_ACME_AGREE_TOS": "1"
    };
    testing.assertContains(problem(applyEnv(defaults(), $env)), "tls.email");
}

func testTheTermsMustBeAcceptedDeliberately() {
    def env as map of string to string init {
        "REGISTRY_TLS": "1",
        "REGISTRY_TLS_DOMAINS": "a.test",
        "REGISTRY_TLS_EMAIL": "o@a.test"
    };
    testing.assertContains(problem(applyEnv(defaults(), $env)), "agreeTos");
}

func testStagingIsRecognisable() {
    # boot warns that a staging certificate is untrusted
    testing.assertTrue(isStaging(LE_STAGING));
    testing.assertFalse(isStaging(LE_PRODUCTION));
}

# --- the rename ---------------------------------------------------------------

func testLegacyNamesMapAcrossThePrefix() {
    testing.assertEqual(legacyNameOf("REGISTRY_DB"), "JVC_DB");
    testing.assertEqual(legacyNameOf("REGISTRY_TLS_DOMAINS"), "JVC_TLS_DOMAINS");
}

func testSomethingElseHasNoLegacyName() {
    testing.assertEqual(legacyNameOf("PATH"), "");
    testing.assertEqual(legacyNameOf("JVC_DB"), "");
}

func testTheCanonicalUrlLosesATrailingSlash() {
    # two spellings of one registry would read as two registries
    def env as map of string to string init {"REGISTRY_URL": "https://registry.jennifer-lang.dev/"};
    testing.assertEqual(
        applyEnv(defaults(), $env).canonicalUrl,
        "https://registry.jennifer-lang.dev");
}

func testTheCanonicalUrlComesFromEitherSource() {
    def fromFile as Config init applyToml(defaults(), 'url = "https://from-file.example/"' + "\n");
    testing.assertEqual($fromFile.canonicalUrl, "https://from-file.example");
    def env as map of string to string init {"REGISTRY_URL": "https://from-env.example"};
    testing.assertEqual(applyEnv($fromFile, $env).canonicalUrl, "https://from-env.example");
}

func testNoCanonicalUrlByDefault() {
    testing.assertEqual(defaults().canonicalUrl, "");
}

func testTheClientIpHeaderIsOptInAndOff() {
    # an unconditionally trusted forwarded header lets any caller forge its logged
    # address
    testing.assertEqual(defaults().clientIpHeader, "");
    def env as map of string to string init {"REGISTRY_CLIENT_IP_HEADER": "CF-Connecting-IP"};
    testing.assertEqual(applyEnv(defaults(), $env).clientIpHeader, "CF-Connecting-IP");
}

func testTheBannerOnlyInventsAHostWhenThereIsNone() {
    testing.assertEqual(displayUrl("http", ":8080"), "http://localhost:8080");
    # guards against prefixing a host that is already there
    testing.assertEqual(displayUrl("http", "127.0.0.1:8080"), "http://127.0.0.1:8080");
    testing.assertEqual(displayUrl("https", "0.0.0.0:8443"), "https://0.0.0.0:8443");
}

func testTheInFlightLimitIsASetting() {
    testing.assertEqual(defaults().maxInFlight, 32);
    def file as Config init applyToml(defaults(), 'maxInFlight = 4
');
    testing.assertEqual($file.maxInFlight, 4);
    def env as map of string to string init {"REGISTRY_MAX_IN_FLIGHT": "2"};
    testing.assertEqual(applyEnv($file, $env).maxInFlight, 2);
    def junk as map of string to string init {"REGISTRY_MAX_IN_FLIGHT": "lots"};
    testing.assertEqual(applyEnv($file, $junk).maxInFlight, 4);
}

func testTheRespondTimeoutIsASetting() {
    # above the slowest publish: about nine forge calls of up to 10 s each
    testing.assertEqual(defaults().respondTimeoutSeconds, 120);
    def file as Config init applyToml(defaults(), 'respondTimeout = 300
');
    testing.assertEqual($file.respondTimeoutSeconds, 300);
    def env as map of string to string init {"REGISTRY_RESPOND_TIMEOUT": "90"};
    testing.assertEqual(applyEnv($file, $env).respondTimeoutSeconds, 90);
    def c as Config init defaults();
    $c.respondTimeoutSeconds = 0;
    testing.assertContains(problem($c), "respondTimeout");
}

func testAnInFlightLimitBelowOneIsRefused() {
    def c as Config init defaults();
    $c.maxInFlight = 0;
    testing.assertContains(problem($c), "maxInFlight");
}

func testAShortTokenKeyIsRefusedAtBoot() {
    def c as Config init loginsOn("github", "github");
    $c.tokenKey = "secret";
    testing.assertContains(problem($c), "at least 32");
    $c.tokenKey = strings.repeat("k", 32);
    testing.assertEqual(problem($c), "");
}

func testAPlainHttpBaseUrlIsRefusedUnlessLoopback() {
    # provider and forge tokens travel to these hosts
    def c as Config init defaults();
    $c.identityBaseUrl = "http://auth.corp.test";
    testing.assertContains(problem($c), "identity.baseUrl must be an https URL");
    $c.identityBaseUrl = "https://auth.corp.test";
    $c.forgeBaseUrl = "HTTP://git.corp.test:3000/api/v1";
    testing.assertContains(problem($c), "forge.baseUrl");
    for (def ok in ["http://localhost:8080", "http://127.0.0.1/", "http://[::1]:9000/x", ""]) {
        $c.forgeBaseUrl = $ok;
        testing.assertEqual(problem($c), "");
    }
}

func testTheRenewalWindowIsBounded() {
    def env as map of string to string init {
        "REGISTRY_TLS": "1",
        "REGISTRY_TLS_DOMAINS": "a.test",
        "REGISTRY_TLS_EMAIL": "ops@a.test",
        "REGISTRY_ACME_AGREE_TOS": "1"
    };
    def c as Config init applyEnv(defaults(), $env);
    testing.assertEqual(problem($c), "");
    $c.tls.renewBeforeDays = 0;
    testing.assertContains(problem($c), "renewBeforeDays");
    $c.tls.renewBeforeDays = 89;
    testing.assertContains(problem($c), "renewBeforeDays");
    $c.tls.renewBeforeDays = 88;
    testing.assertEqual(problem($c), "");
    # irrelevant while TLS is off
    $c.tls.renewBeforeDays = -1;
    $c.tls.enabled = false;
    testing.assertEqual(problem($c), "");
}
