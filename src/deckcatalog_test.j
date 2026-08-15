# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for deckcatalog.j: the store-to-catalog adapter and the
# server's fetch loop around the shared resolver. Run with:
#
#     jennifer test server/deckcatalog_test.j
#
# deckcatalog.j imports store / flatdb / catalog / resolver, so the overlay
# reaches them through those aliases, and GraphResult / addDeck / resolveGraph by
# bare name. The resolution *rules* are tested in cli/resolver_test.j against a
# plain catalog; what matters here is that the store feeds them correctly.

use testing;

# ver builds a git-kind DeckVersion with the given requirements map.
func ver(v as string, requires as map of string to string) {
    return store.DeckVersion{
        version: $v,
        kind: store.KIND_GIT,
        url: "u/" + $v,
        ref: "v" + $v,
        commit: "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293",
        checksum: "",
        requires: $requires,
        engines: {},
        capabilities: [],
        description: "",
        publishedAt: "0",
        yanked: false,
        license: ""
    };
}

# emptyDb opens a fresh store over a missing file.
func emptyDb() {
    return store.open("/no/such/deckcatalog/registry.json");
}

# findVer returns the resolved version of a deck, or "" when absent.
func findVer(resolved as list of catalog.Candidate, name as string) {
    for (def r in $resolved) {
        if ($r.name == $name) {
            return $r.version;
        }
    }
    return "";
}

# --- the adapter ------------------------------------------------------------

func testAddDeckCopiesEveryVersion() {
    def db as flatdb.DB init emptyDb();
    def none as map of string to string init {};
    $db = store.putVersion($db, "ansi", "", ver("1.2.0", $none));
    $db = store.putVersion($db, "ansi", "", ver("1.3.0", $none));
    def cat as catalog.Catalog init addDeck($db, catalog.empty(), "ansi");
    testing.assertEqual(len(catalog.versions($cat, "ansi")), 2);
}

func testAddDeckCarriesDeliveryFields() {
    def db as flatdb.DB init emptyDb();
    def none as map of string to string init {};
    $db = store.putVersion($db, "ansi", "", ver("1.2.0", $none));
    def cat as catalog.Catalog init addDeck($db, catalog.empty(), "ansi");
    def c as catalog.Candidate init catalog.get($cat, "ansi", "1.2.0");
    testing.assertEqual($c.url, "u/1.2.0");
    testing.assertEqual($c.kind, store.KIND_GIT);
    # the git pin must survive the store -> catalog hop: the resolver hands it to
    # the client, which fetches the commit rather than the mutable tag
    testing.assertEqual($c.ref, "v1.2.0");
    testing.assertEqual($c.commit, "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293");
}

func testAddDeckCarriesRequiresAndEngines() {
    def db as flatdb.DB init emptyDb();
    def v as store.DeckVersion init ver("1.0.0", {"beta": "^1.0.0"});
    $v.engines = {"jennifer": ">=0.24.0"};
    $db = store.putVersion($db, "alpha", "", $v);
    def cat as catalog.Catalog init addDeck($db, catalog.empty(), "alpha");
    def c as catalog.Candidate init catalog.get($cat, "alpha", "1.0.0");
    testing.assertEqual($c.requires["beta"], "^1.0.0");
    testing.assertEqual($c.engines["jennifer"], ">=0.24.0");
}

func testAddDeckOfUnknownDeckAddsNothing() {
    def db as flatdb.DB init emptyDb();
    def cat as catalog.Catalog init addDeck($db, catalog.empty(), "ghost");
    testing.assertEqual(len($cat.entries), 0);
}

# --- resolution through the store -------------------------------------------

func testResolveFlat() {
    def db as flatdb.DB init emptyDb();
    def none as map of string to string init {};
    $db = store.putVersion($db, "ansi", "", ver("1.2.0", $none));
    $db = store.putVersion($db, "ansi", "", ver("1.3.0", $none));
    def g as GraphResult init resolveGraph($db, {"ansi": "^1.2.0"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.resolved), 1);
    testing.assertEqual(findVer($g.resolved, "ansi"), "1.3.0");
}

func testResolveTransitive() {
    def db as flatdb.DB init emptyDb();
    def none as map of string to string init {};
    $db = store.putVersion($db, "alpha", "", ver("1.0.0", {"beta": "^1.0.0"}));
    $db = store.putVersion($db, "beta", "", ver("1.0.0", $none));
    $db = store.putVersion($db, "beta", "", ver("1.2.0", $none));
    def g as GraphResult init resolveGraph($db, {"alpha": "^1.0.0"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.resolved), 2);
    testing.assertEqual(findVer($g.resolved, "alpha"), "1.0.0");
    testing.assertEqual(findVer($g.resolved, "beta"), "1.2.0");   # highest satisfying
}

func testDiamondUnifiesShared() {
    # top -> left, right; left needs shared ^1.0.0; right needs shared <1.5.0.
    # shared must satisfy BOTH -> highest is 1.4.0 (not 1.9.0).
    def db as flatdb.DB init emptyDb();
    def none as map of string to string init {};
    $db = store.putVersion($db, "top", "", ver("1.0.0", {"left": "^1.0.0", "right": "^1.0.0"}));
    $db = store.putVersion($db, "left", "", ver("1.0.0", {"shared": "^1.0.0"}));
    $db = store.putVersion($db, "right", "", ver("1.0.0", {"shared": "<1.5.0"}));
    $db = store.putVersion($db, "shared", "", ver("1.0.0", $none));
    $db = store.putVersion($db, "shared", "", ver("1.4.0", $none));
    $db = store.putVersion($db, "shared", "", ver("1.9.0", $none));
    def g as GraphResult init resolveGraph($db, {"top": "^1.0.0"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.resolved), 4);
    testing.assertEqual(findVer($g.resolved, "shared"), "1.4.0");
}

func testUnsatisfiableConflict() {
    # root wants y ^1.0.0; dep a wants y >=2.0.0 -> no y satisfies both.
    def db as flatdb.DB init emptyDb();
    def none as map of string to string init {};
    $db = store.putVersion($db, "a", "", ver("1.0.0", {"y": ">=2.0.0"}));
    $db = store.putVersion($db, "y", "", ver("1.0.0", $none));
    $db = store.putVersion($db, "y", "", ver("2.0.0", $none));
    def g as GraphResult init resolveGraph($db, {"a": "*", "y": "^1.0.0"});
    testing.assertFalse($g.ok);
    testing.assertContains($g.error, "no version of y");
}

func testMissingDeck() {
    def db as flatdb.DB init emptyDb();
    def g as GraphResult init resolveGraph($db, {"ghost": "*"});
    testing.assertFalse($g.ok);
    testing.assertContains($g.error, "no such deck");
}

func testMissingTransitiveDeck() {
    # alpha is published but the beta it requires is not: still "no such deck".
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "alpha", "", ver("1.0.0", {"beta": "^1.0.0"}));
    def g as GraphResult init resolveGraph($db, {"alpha": "^1.0.0"});
    testing.assertFalse($g.ok);
    testing.assertContains($g.error, "no such deck");
    testing.assertContains($g.error, "beta");
}

func testCycleTerminates() {
    # p <-> q mutually require each other; resolution must terminate.
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "p", "", ver("1.0.0", {"q": "*"}));
    $db = store.putVersion($db, "q", "", ver("1.0.0", {"p": "*"}));
    def g as GraphResult init resolveGraph($db, {"p": "*"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.resolved), 2);
    testing.assertEqual(findVer($g.resolved, "p"), "1.0.0");
    testing.assertEqual(findVer($g.resolved, "q"), "1.0.0");
}

func testScopedTransitive() {
    # a scoped deck depending on another scoped deck resolves through the
    # pointer-escaped requires map.
    def db as flatdb.DB init emptyDb();
    def none as map of string to string init {};
    def ros as store.DeckVersion init ver("0.1.0", {"@jennifer/net": "^1.0.0"});
    $db = store.putVersion($db, "@jennifer/routeros", "", $ros);
    $db = store.putVersion($db, "@jennifer/net", "", ver("1.0.0", $none));
    def g as GraphResult init resolveGraph($db, {"@jennifer/routeros": "^0.1.0"});
    testing.assertTrue($g.ok);
    testing.assertEqual(findVer($g.resolved, "@jennifer/net"), "1.0.0");
}

func testAYankedVersionIsNotACandidate() {
    # transitive resolution must not land on a withdrawn version either
    def db as flatdb.DB init emptyDb();
    def none as map of string to string init {};
    $db = store.putVersion($db, "ansi", "", ver("1.0.0", $none));
    $db = store.putVersion($db, "ansi", "", ver("1.3.0", $none));
    $db = store.setYanked($db, "ansi", "1.3.0", true);
    def cat as catalog.Catalog init addDeck($db, catalog.empty(), "ansi");
    testing.assertEqual(len(catalog.versions($cat, "ansi")), 1);
    testing.assertEqual(catalog.versions($cat, "ansi")[0], "1.0.0");
}
