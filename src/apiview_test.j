# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for apiview.j. Run with:
#
#     JENNIFER_SYSMODDIR=../jennifer-lang/modules jennifer test server/apiview_test.j

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
        license: ""
    };
}

func testIndex() {
    def reply as Reply init index();
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asString($reply.body, "/service"), "jennifer-registry");
    testing.assertTrue(json.length($reply.body, "/endpoints") > 0);
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

func testDiscoveryKeepsTheRouteDerivedBase() {
    def reply as Reply init discovery(discoveryBase(), noAuth());
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asString($reply.body, "/registry"), SERVICE_NAME);
    testing.assertEqual(json.asString($reply.body, "/spec"), SPEC_VERSION);
    testing.assertEqual(json.asInt($reply.body, "/apis/0/version"), 1);
    testing.assertEqual(json.asString($reply.body, "/apis/0/basePath"), "/v1");
    # `deck` is the one feature a registry must advertise
    testing.assertEqual(json.asString($reply.body, "/features/0"), "deck");
}

func testDiscoveryOmitsAuthWhenNoneIsConfigured() {
    # The specification makes `auth` optional and gives its absence a meaning:
    # this registry accepts no logins. Advertising a provider with no endpoints
    # behind it would leave a client knowing identity is GitHub and still having
    # nowhere to send the exchange.
    def reply as Reply init discovery(discoveryBase(), noAuth());
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
    def reply as Reply init discovery(discoveryBase(), $urls);
    # whatever the caller supplied: this module never learns which provider is
    # configured, which is what lets a new one need no change here
    testing.assertEqual(json.asString($reply.body, "/auth/provider"), "gitea");
    testing.assertEqual(json.asString($reply.body, "/auth/flow"), "device");
    # the paths are absolute and used verbatim, not joined to a base path
    testing.assertEqual(json.asString($reply.body, "/auth/deviceUrl"), "/v1/auth/device");
    testing.assertEqual(json.asString($reply.body, "/auth/tokenUrl"), "/v1/auth/token");
    testing.assertEqual(json.asString($reply.body, "/auth/refreshUrl"), "/v1/auth/refresh");
}

func testHealth() {
    def reply as Reply init health();
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asString($reply.body, "/status"), "ok");
}

func testListDecksEmpty() {
    def reply as Reply init listDecks(emptyStore());
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.length($reply.body, "/decks"), 0);
}

func testListDecks() {
    def db as flatdb.DB init seeded();
    $db = store.putVersion($db, "csv", "rfc 4180", version("0.4.0", "u"));
    def reply as Reply init listDecks($db);
    testing.assertEqual(json.length($reply.body, "/decks"), 2);
    testing.assertEqual(json.asString($reply.body, "/decks/0"), "ansi");
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
        version: $v, kind: store.KIND_GIT, url: $url,
        ref: "v" + $v, commit: "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293", checksum: "",
        requires: $requires, engines: {}, capabilities: [], description: "",
        publishedAt: "0",
        yanked: false,
        license: ""
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
    # a bare 404 here is indistinguishable from a missing deck, which sends the
    # user looking for a typo instead of a version mismatch
    def served as list of int init [1];
    def reply as Reply init unsupportedVersion("/v2/deck", $served);
    testing.assertEqual($reply.status, 400);
    testing.assertEqual(json.asString($reply.body, "/error"), "unsupported API version");
    testing.assertEqual(json.length($reply.body, "/apis"), 1);
    testing.assertEqual(json.asInt($reply.body, "/apis/0"), 1);
}
