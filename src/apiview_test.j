# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for apiview.j. Run with:
#
#     jennifer test src/apiview_test.j

use testing;

# emptyStore returns an open, schema-normalized registry over a missing file.
func emptyStore() {
    return store.open("/no/such/jvc/apiview/missing.json");
}

# seeded returns a store with an "ansi" deck at three versions.
func seeded() {
    def db as flatdb.DB init emptyStore();
    $db = store.putVersion($db, "ansi", "terminal styling", version("1.0.0", "u1"));
    $db = store.putVersion($db, "ansi", "", version("1.4.3", "u2"));
    $db = store.putVersion($db, "ansi", "", version("2.0.0", "u3"));
    return $db;
}

func version(v as string, url as string) {
    return store.DeckVersion{
        version: $v,
        kind: store.KIND_GIT,
        url: $url,
        ref: "v" + $v,
        commit: "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293",
        checksum: "",
        requires: {},
        engines: {},
        capabilities: [],
        description: "v " + $v,
        publishedAt: "1700000000",
        yanked: false,
        license: "",
        keywords: []
    };
}

func testIndex() {
    def reply as Reply init index(false);
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asString($reply.body, "/service"), "jennifer-registry");
    testing.assertEqual(json.length($reply.body, "/endpoints"), 10);
    testing.assertEqual(json.asString($reply.body, "/endpoints/9"), "POST /publish");
}

func testIndexListsTheLoginGatedRoutesWhenLoginsAreOn() {
    def reply as Reply init index(true);
    testing.assertEqual(json.length($reply.body, "/endpoints"), 18);
    testing.assertEqual(json.asString($reply.body, "/endpoints/17"), "POST /auth/refresh");
}

# discoveryBase mimics what webapi.discovery derives from the route table, so
# this overlay can exercise `discovery` without importing the web engine.
func discoveryBase() {
    def doc as json.Value init json.set(json.map(), "/registry", SERVICE_NAME);
    $doc = json.set($doc, "/spec", SPEC_VERSION);
    $doc = json.set($doc, "/apis", json.list());
    def entry as json.Value init json.set(json.map(), "/version", 1);
    $entry = json.set($entry, "/basePath", "/v1");
    $entry = json.set($entry, "/deprecated", false);
    $doc = json.append($doc, "/apis", $entry);
    $doc = json.set($doc, "/features", json.list());
    $doc = json.append($doc, "/features", "deck");
    return $doc;
}

# noAuth is the empty URL map a read-only registry passes.
func noAuth() {
    def none as map of string to string init {};
    return $none;
}

# noTrust is trusted publishing switched off.
func noTrust() {
    return TrustedPublishing{audience: "", providers: [], url: ""};
}

func testDiscoveryKeepsTheRouteDerivedBase() {
    def reply as Reply init discovery(discoveryBase(), "", noAuth(), noTrust());
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asString($reply.body, "/registry"), SERVICE_NAME);
    testing.assertEqual(json.asString($reply.body, "/spec"), SPEC_VERSION);
    testing.assertEqual(json.asInt($reply.body, "/apis/0/version"), 1);
    testing.assertEqual(json.asString($reply.body, "/apis/0/basePath"), "/v1");
    # `deck` is the one feature a registry must advertise
    testing.assertEqual(json.asString($reply.body, "/features/0"), "deck");
}

func testDiscoveryOmitsAuthWhenNoneIsConfigured() {
    # An absent `auth` means "accepts no logins" (specification).
    def reply as Reply init discovery(discoveryBase(), "", noAuth(), noTrust());
    testing.assertFalse(json.has($reply.body, "/auth"));
}

func testDiscoveryAdvertisesTheAuthEndpointsWhenConfigured() {
    def urls as map of string to string init {
        "provider": "gitea",
        "flow": "device",
        "deviceUrl": "/v1/auth/device",
        "tokenUrl": "/v1/auth/token",
        "refreshUrl": "/v1/auth/refresh"
    };
    def reply as Reply init discovery(discoveryBase(), "", $urls, noTrust());
    # copied from the caller, whichever provider is configured
    testing.assertEqual(json.asString($reply.body, "/auth/provider"), "gitea");
    testing.assertEqual(json.asString($reply.body, "/auth/flow"), "device");
    # the paths are absolute and used verbatim, not joined to a base path
    testing.assertEqual(json.asString($reply.body, "/auth/deviceUrl"), "/v1/auth/device");
    testing.assertEqual(json.asString($reply.body, "/auth/tokenUrl"), "/v1/auth/token");
    testing.assertEqual(json.asString($reply.body, "/auth/refreshUrl"), "/v1/auth/refresh");
}

func testAuthcodeAdvertisesItsEndpointClientAndScopes() {
    # 12.2: the client cannot construct these itself
    def urls as map of string to string init {
        "provider": "oidc",
        "flow": "authcode",
        "authorizeUrl": "https://id.example/authorize",
        "clientId": "registry",
        "scopes": "openid  profile",
        "tokenUrl": "/v1/auth/token"
    };
    def reply as Reply init discovery(discoveryBase(), "", $urls, noTrust());
    testing.assertEqual(
        json.asString($reply.body, "/auth/authorizeUrl"),
        "https://id.example/authorize");
    testing.assertEqual(json.asString($reply.body, "/auth/clientId"), "registry");
    testing.assertEqual(json.length($reply.body, "/auth/scopes"), 2);
    testing.assertEqual(json.asString($reply.body, "/auth/scopes/1"), "profile");
}

func testTrustedPublishingIsANestedObjectWithAProviderList() {
    # specification 4.1: `auth.trustedPublishing.{audience,providers,url}`
    def tp as TrustedPublishing init TrustedPublishing{
        audience: "registry.example",
        providers: ["github-actions"],
        url: "/v1/publish"
    };
    def reply as Reply init discovery(discoveryBase(), "", noAuth(), $tp);
    testing.assertEqual(
        json.asString($reply.body, "/auth/trustedPublishing/audience"),
        "registry.example");
    testing.assertEqual(
        json.asString($reply.body, "/auth/trustedPublishing/providers/0"),
        "github-actions");
    testing.assertEqual(json.asString($reply.body, "/auth/trustedPublishing/url"), "/v1/publish");
    # without logins there is no device flow to advertise
    testing.assertFalse(json.has($reply.body, "/auth/deviceUrl"));
}

func testHealth() {
    def reply as Reply init health();
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asString($reply.body, "/status"), "ok");
}

func testListDecksEmpty() {
    def reply as Reply init listDecks(emptyStore(), 1);
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.length($reply.body, "/decks"), 0);
    testing.assertEqual(json.asInt($reply.body, "/pages"), 1);
}

func testListDecks() {
    def db as flatdb.DB init seeded();
    $db = store.putVersion($db, "csv", "rfc 4180", version("0.4.0", "u"));
    def reply as Reply init listDecks($db, 1);
    testing.assertEqual(json.length($reply.body, "/decks"), 2);
    testing.assertEqual(json.asString($reply.body, "/decks/0"), "ansi");
    testing.assertEqual(json.asInt($reply.body, "/total"), 2);
}

func testListDecksIsPagedAndSorted() {
    # 5.2: a large registry pages
    def db as flatdb.DB init emptyStore();
    for (def i in 0..(DECKS_PAGE_SIZE + 5)) {
        $db = store.putVersion($db, "d" + convert.toString(10000 + $i), "", version("1.0.0", "u"));
    }
    def first as Reply init listDecks($db, 1);
    testing.assertEqual(json.length($first.body, "/decks"), DECKS_PAGE_SIZE);
    testing.assertEqual(json.asInt($first.body, "/pages"), 2);
    testing.assertEqual(json.asString($first.body, "/decks/0"), "d10000");
    def second as Reply init listDecks($db, 2);
    testing.assertEqual(json.length($second.body, "/decks"), 5);
    testing.assertEqual(json.asString($second.body, "/decks/4"), "d11004");
    testing.assertEqual(json.length(listDecks($db, 3).body, "/decks"), 0);
}

func testGetDeckFound() {
    def reply as Reply init getDeck(seeded(), "ansi");
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asString($reply.body, "/name"), "ansi");
    testing.assertEqual(json.asString($reply.body, "/description"), "terminal styling");
}

func testGetDeckNotFound() {
    def reply as Reply init getDeck(seeded(), "ghost");
    testing.assertEqual($reply.status, 404);
    testing.assertTrue(json.has($reply.body, "/error"));
}

func testGetVersionFound() {
    def reply as Reply init getVersion(seeded(), "ansi", "1.4.3");
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asString($reply.body, "/url"), "u2");
}

func testGetVersionNotFound() {
    def reply as Reply init getVersion(seeded(), "ansi", "9.9.9");
    testing.assertEqual($reply.status, 404);
}

func testResolveFound() {
    def reply as Reply init resolve(seeded(), "ansi", "^1.2.0");
    testing.assertEqual($reply.status, 200);
    testing.assertTrue(json.asBool($reply.body, "/found"));
    testing.assertEqual(json.asString($reply.body, "/version"), "1.4.3");
    testing.assertEqual(json.asString($reply.body, "/url"), "u2");
}

func testResolveEmptyConstraintMeansAny() {
    def reply as Reply init resolve(seeded(), "ansi", "");
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asString($reply.body, "/version"), "2.0.0");
}

func testResolveNotFound() {
    def reply as Reply init resolve(seeded(), "ansi", "^3.0.0");
    testing.assertEqual($reply.status, 404);
    testing.assertFalse(json.asBool($reply.body, "/found"));
}

func testResolveMissingName() {
    def reply as Reply init resolve(emptyStore(), "", "*");
    testing.assertEqual($reply.status, 400);
}

# --- transitive resolve (/resolve-graph) ------------------------------------

func versionReq(v as string, url as string, requires as map of string to string) {
    return store.DeckVersion{
        version: $v,
        kind: store.KIND_GIT,
        url: $url,
        ref: "v" + $v,
        commit: "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293",
        checksum: "",
        requires: $requires,
        engines: {},
        capabilities: [],
        description: "",
        publishedAt: "0",
        yanked: false,
        license: "",
        keywords: []
    };
}

func testResolveGraphTransitive() {
    def db as flatdb.DB init emptyStore();
    def none as map of string to string init {};
    $db = store.putVersion($db, "alpha", "", versionReq("1.0.0", "u", {"beta": "^1.0.0"}));
    $db = store.putVersion($db, "beta", "", versionReq("1.0.0", "u", $none));
    def reply as Reply init resolveGraph($db, '{"alpha":"^1.0.0"}');
    testing.assertEqual($reply.status, 200);
    testing.assertTrue(json.asBool($reply.body, "/ok"));
    testing.assertEqual(json.length($reply.body, "/resolved"), 2);
}

func testResolveGraphUnsatisfiable() {
    def db as flatdb.DB init emptyStore();
    def reply as Reply init resolveGraph($db, '{"ghost":"*"}');
    testing.assertFalse(json.asBool($reply.body, "/ok"));
    testing.assertContains(json.asString($reply.body, "/error"), "no such deck");
}

func testResolveGraphBadJson() {
    def db as flatdb.DB init emptyStore();
    def reply as Reply init resolveGraph($db, "not json");
    testing.assertEqual($reply.status, 400);
}

# --- rejecting an unknown API version (4.5) -----------------------------------

func testVersionOfPath() {
    testing.assertEqual(versionOfPath("/v1/decks"), 1);
    testing.assertEqual(versionOfPath("/v27/deck"), 27);
    testing.assertEqual(versionOfPath("/v2"), 2);
    # the unversioned root alias names no version
    testing.assertEqual(versionOfPath("/decks"), 0);
    testing.assertEqual(versionOfPath("/"), 0);
    # these only look like version segments
    testing.assertEqual(versionOfPath("/version"), 0);
    testing.assertEqual(versionOfPath("/v1x/y"), 0);
    testing.assertEqual(versionOfPath("/v/1"), 0);
}

func testAServedVersionIsNotAMismatch() {
    def served as list of int init [1];
    testing.assertEqual(unsupportedVersion("/v1/decks", $served).status, 0);
    # an unversioned path is somebody else's 404 to answer
    testing.assertEqual(unsupportedVersion("/nope", $served).status, 0);
}

func testAnUnservedVersionIsA400NamingTheSupportedOnes() {
    # a 404 would be indistinguishable from a missing deck
    def served as list of int init [1];
    def reply as Reply init unsupportedVersion("/v2/deck", $served);
    testing.assertEqual($reply.status, 400);
    testing.assertEqual(json.asString($reply.body, "/error"), "unsupported API version");
    testing.assertEqual(json.length($reply.body, "/apis"), 1);
    testing.assertEqual(json.asInt($reply.body, "/apis/0"), 1);
}

# --- the canonical URL --------------------------------------------------------

func testTheCanonicalUrlIsAdvertisedWhenConfigured() {
    def reply as Reply init discovery(
        discoveryBase(),
        "https://registry.jennifer-lang.dev",
        noAuth(),
        noTrust());
    testing.assertEqual(json.asString($reply.body, "/url"), "https://registry.jennifer-lang.dev");
}

func testAnUndeclaredCanonicalUrlIsOmitted() {
    # A guessed URL would be recorded in lockfiles as the registry's identity.
    testing.assertFalse(json.has(discovery(discoveryBase(), "", noAuth(), noTrust()).body, "/url"));
    testing.assertFalse(json.has(
        discovery(discoveryBase(), "   ", noAuth(), noTrust()).body,
        "/url"));
}

func testTheCanonicalUrlDoesNotDisturbTheRestOfTheDocument() {
    def reply as Reply init discovery(discoveryBase(), "https://r.example", noAuth(), noTrust());
    testing.assertEqual(json.asString($reply.body, "/registry"), SERVICE_NAME);
    testing.assertEqual(json.asString($reply.body, "/spec"), SPEC_VERSION);
    testing.assertEqual(json.asInt($reply.body, "/apis/0/version"), 1);
}

# --- what a resolution request may ask ------------------------------------------

func testAConstraintOutsideTheGrammarIsA400() {
    # a 404 would read as "no such version"
    def db as flatdb.DB init emptyStore();
    testing.assertEqual(resolve($db, "alpha", "~>1.2").status, 400);
    testing.assertEqual(resolve($db, "alpha", "^99999999999999999999").status, 400);
}

func testRootsUnderTwoSpellingsAreA400() {
    # names fold, so this is one deck asked for at two versions
    def reply as Reply init resolveGraph(emptyStore(), '{"@t/d":"^1","@T/D":"^2"}');
    testing.assertEqual($reply.status, 400);
    testing.assertContains(json.asString($reply.body, "/error"), "two spellings");
}

func testABadRootIsA400() {
    testing.assertEqual(resolveGraph(emptyStore(), '{"not a name!":"*"}').status, 400);
    testing.assertEqual(resolveGraph(emptyStore(), '{"@t/d":"^abc"}').status, 400);
    testing.assertEqual(resolveGraph(emptyStore(), '{"@t/d":5}').status, 400);
}

func testTheNumberOfRootsIsBounded() {
    def roots as map of string to string init {};
    for (def i in 0..(MAX_GRAPH_ROOTS + 1)) {
        $roots["@t/d" + convert.toString($i)] = "*";
    }
    testing.assertContains(rootsProblem($roots), "too many roots");
}

func testAnOversizedApiVersionIsA400NotA500() {
    def r as Reply init unsupportedVersion("/v99999999999999999999/decks", [1]);
    testing.assertEqual($r.status, 400);
}

# --- conditional reads ----------------------------------------------------------

func testPagesAndListingsMayBeAnsweredFromATag() {
    for (def p in [
        "/",
        "/browse",
        "/tags",
        "/tag/net",
        "/scope/acme",
        "/deck/acme/tool",
        "/search",
        "/v1/decks",
        "/v1/resolve-graph",
        "/scopes"
    ]) {
        testing.assertTrue(isConditional("GET", $p));
    }
    testing.assertTrue(isConditional("HEAD", "/browse"));
}

func testCountedLookupsAndWritesAreNever() {
    # a 304 would skip the lookup count
    for (def p in ["/deck", "/v1/deck", "/decks/ansi", "/v1/resolve", "/resolve"]) {
        testing.assertFalse(isConditional("GET", $p));
    }
    testing.assertFalse(isConditional("POST", "/v1/publish"));
    testing.assertFalse(isConditional("POST", "/browse"));
    testing.assertFalse(isConditional("GET", "/manual/index.html"));
    testing.assertFalse(isConditional("GET", "/health"));
}

func testTheTagMovesWithTheDatabaseTheHourAndTheRepresentation() {
    def base as string init cacheTag(100, 5, 7200, "html");
    testing.assertEqual(cacheTag(100, 5, 7300, "html"), $base);
    testing.assertNotEqual(cacheTag(101, 5, 7200, "html"), $base);
    testing.assertNotEqual(cacheTag(100, 6, 7200, "html"), $base);
    testing.assertNotEqual(cacheTag(100, 5, 10800, "html"), $base);
    testing.assertNotEqual(cacheTag(100, 5, 7200, "json"), $base);
}

func testSearchAnswersFromTheIndex() {
    def reply as Reply init search(search.index(seeded()), "TERM");
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asInt(json.get($reply.body, "/count")), 1);
    testing.assertEqual(json.asString(json.get($reply.body, "/results/0/name")), "ansi");
    testing.assertEqual(json.asString(json.get($reply.body, "/results/0/latest")), "2.0.0");
    testing.assertEqual(json.asInt(json.get($reply.body, "/results/0/versions")), 3);
    testing.assertTrue(json.asBool(json.get($reply.body, "/results/0/live")));
}

func testAnEmptySearchListsEverything() {
    def reply as Reply init search(search.index(seeded()), "");
    testing.assertEqual(json.asInt(json.get($reply.body, "/count")), 1);
    def none as Reply init search(search.index(seeded()), "zzz");
    testing.assertEqual(json.asInt(json.get($none.body, "/count")), 0);
}

func testAnOverlongSearchIsRefused() {
    testing.assertEqual(search(search.index(seeded()), strings.repeat("a", 201)).status, 400);
    testing.assertEqual(search(search.index(seeded()), strings.repeat("a", 200)).status, 200);
}

func testListDecksFromTheIndexMatchesTheStoreListing() {
    def db as flatdb.DB init seeded();
    $db = store.putVersion($db, "csv", "rfc 4180", version("0.4.0", "u"));
    def all as json.Value init search.index($db);
    testing.assertEqual(
        json.encode(listDecksFrom($all, 1).body),
        json.encode(listDecks($db, 1).body));
    testing.assertEqual(json.length(listDecksFrom($all, 2).body, "/decks"), 0);
    testing.assertEqual(json.asInt(listDecksFrom(search.index(emptyStore()), 1).body, "/pages"), 1);
}

func testSearchInMatchesSearch() {
    def all as json.Value init search.index(seeded());
    def low as json.Value init search.lowered($all);
    testing.assertEqual(
        json.encode(searchIn($all, $low, "ANSI").body),
        json.encode(search($all, "ANSI").body));
    testing.assertEqual(
        json.encode(searchIn($all, $low, "").body),
        json.encode(search($all, "").body));
    testing.assertEqual(
        searchIn($all, $low, strings.repeat("x", search.MAX_QUERY + 1)).status,
        400);
}
