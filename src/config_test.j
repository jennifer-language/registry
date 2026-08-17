# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for config.j. Run with:
#
#     jennifer test src/config_test.j
#
# The whole point of this module is a precedence rule, so that is what is tested:
# defaults, then the file, then the environment, with the environment winning and
# an absent setting never blanking a present one.

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
    # a deployment whose configuration silently failed to load is worse than one
    # that refuses to start and says so
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
    # a stray empty value in a compose file must not silently erase configuration
    def env as map of string to string init { "REGISTRY_ADDR": "", "REGISTRY_DB": "   " };
    def c as Config init applyEnv(applyToml(defaults(), sample()), $env);
    testing.assertEqual($c.addr, ":9000");
    testing.assertEqual($c.dbPath, "/srv/registry.json");
}

func testABooleanCanBeTurnedOffFromTheEnvironment() {
    # the exception to the rule above: "0" has to be able to disable something
    # the file enabled, so booleans parse rather than test for emptiness
    def env as map of string to string init { "REGISTRY_TLS": "0" };
    testing.assertFalse(applyEnv(applyToml(defaults(), sample()), $env).tls.enabled);
    def on as map of string to string init { "REGISTRY_TLS": "true" };
    testing.assertTrue(applyEnv(defaults(), $on).tls.enabled);
}

func testBooleanSpellings() {
    def base as bool init false;
    for (def yes in ["1", "true", "TRUE", "yes", "on"]) {
        def env as map of string to string init { "K": $yes };
        testing.assertTrue(envFlag($env, "K", $base));
    }
    for (def no in ["0", "false", "no", "off"]) {
        def env as map of string to string init { "K": $no };
        testing.assertFalse(envFlag($env, "K", true));
    }
}

func testAnUnrecognisedBooleanKeepsTheConfiguredValue() {
    # reading "maybe" as "no" would quietly disable TLS
    def env as map of string to string init { "K": "perhaps" };
    testing.assertTrue(envFlag($env, "K", true));
    testing.assertFalse(envFlag($env, "K", false));
}

func testDomainsFromTheEnvironment() {
    def commas as map of string to string init { "REGISTRY_TLS_DOMAINS": "a.test, b.test" };
    def c as Config init applyEnv(defaults(), $commas);
    testing.assertEqual(len($c.tls.domains), 2);
    testing.assertEqual($c.tls.domains[1], "b.test");
    def spaces as map of string to string init { "REGISTRY_TLS_DOMAINS": "a.test b.test" };
    testing.assertEqual(len(applyEnv(defaults(), $spaces).tls.domains), 2);
}

# --- refusing to start --------------------------------------------------------

func testAUsableConfigurationHasNoProblem() {
    testing.assertEqual(problem(defaults()), "");
    testing.assertEqual(problem(applyToml(defaults(), sample())), "");
}

func testTlsWithoutADomainIsRefused() {
    def env as map of string to string init { "REGISTRY_TLS": "1" };
    def c as Config init applyEnv(defaults(), $env);
    testing.assertContains(problem($c), "no tls.domains");
}

func testTlsWithoutAnEmailIsRefused() {
    def env as map of string to string init {
        "REGISTRY_TLS": "1", "REGISTRY_TLS_DOMAINS": "a.test", "REGISTRY_ACME_AGREE_TOS": "1"
    };
    testing.assertContains(problem(applyEnv(defaults(), $env)), "tls.email");
}

func testTheTermsMustBeAcceptedDeliberately() {
    def env as map of string to string init {
        "REGISTRY_TLS": "1", "REGISTRY_TLS_DOMAINS": "a.test", "REGISTRY_TLS_EMAIL": "o@a.test"
    };
    testing.assertContains(problem(applyEnv(defaults(), $env)), "agreeTos");
}

func testStagingIsRecognisable() {
    # a staging certificate is untrusted, and a browser warning is a confusing
    # way to discover which endpoint you pointed at
    testing.assertTrue(isStaging(LE_STAGING));
    testing.assertFalse(isStaging(LE_PRODUCTION));
}

# --- the rename ---------------------------------------------------------------

func testLegacyNamesMapAcrossThePrefix() {
    # `jvc` is the client; naming the server's variables after it meant a host
    # running both had one JVC_DB meaning two different databases
    testing.assertEqual(legacyNameOf("REGISTRY_DB"), "JVC_DB");
    testing.assertEqual(legacyNameOf("REGISTRY_TLS_DOMAINS"), "JVC_TLS_DOMAINS");
}

func testSomethingElseHasNoLegacyName() {
    testing.assertEqual(legacyNameOf("PATH"), "");
    testing.assertEqual(legacyNameOf("JVC_DB"), "");
}

func testTheCanonicalUrlLosesATrailingSlash() {
    # a client records this string to say where a deck came from; two spellings
    # of one registry would read as two registries
    def env as map of string to string init {
        "REGISTRY_URL": "https://registry.jennifer-lang.dev/"
    };
    testing.assertEqual(applyEnv(defaults(), $env).canonicalUrl,
        "https://registry.jennifer-lang.dev");
}

func testTheCanonicalUrlComesFromEitherSource() {
    def fromFile as Config init applyToml(defaults(),
        'url = "https://from-file.example/"' + "\n");
    testing.assertEqual($fromFile.canonicalUrl, "https://from-file.example");
    def env as map of string to string init { "REGISTRY_URL": "https://from-env.example" };
    testing.assertEqual(applyEnv($fromFile, $env).canonicalUrl, "https://from-env.example");
}

func testNoCanonicalUrlByDefault() {
    testing.assertEqual(defaults().canonicalUrl, "");
}

func testTheClientIpHeaderIsOptInAndOff() {
    # reading a forwarded header unconditionally would let any caller write its
    # own address into the audit log
    testing.assertEqual(defaults().clientIpHeader, "");
    def env as map of string to string init {
        "REGISTRY_CLIENT_IP_HEADER": "CF-Connecting-IP"
    };
    testing.assertEqual(applyEnv(defaults(), $env).clientIpHeader, "CF-Connecting-IP");
}

func testTheBannerOnlyInventsAHostWhenThereIsNone() {
    # ":8080" is every interface, so a name has to be invented to make the URL
    # clickable, and localhost is right because the reader is at the machine
    testing.assertEqual(displayUrl("http", ":8080"), "http://localhost:8080");
    # but an address that already names a host must keep it: prefixing produced
    # "localhost127.0.0.1:8080", which is not a URL and lies about the binding
    testing.assertEqual(displayUrl("http", "127.0.0.1:8080"),
        "http://127.0.0.1:8080");
    testing.assertEqual(displayUrl("https", "0.0.0.0:8443"),
        "https://0.0.0.0:8443");
}
