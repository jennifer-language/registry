# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for resolver.j: the transitive dependency graph resolver.
# Run with:
#
#     jennifer test cli/resolver_test.j
#
# resolver.j imports catalog / constraint, so the overlay reaches them through
# those aliases and GraphResult / resolveGraph by bare name.

use testing;

# put adds one version of a deck, with its own requirements, to a catalog.
func put(cat as catalog.Catalog, name as string, version as string,
    reqs as map of string to string) {
    def c as catalog.Candidate init catalog.candidate($name, $version);
    $c.requires = $reqs;
    return catalog.add($cat, $c);
}

# plain adds one version of a deck with no requirements.
func plain(cat as catalog.Catalog, name as string, version as string) {
    def none as map of string to string init {};
    return put($cat, $name, $version, $none);
}

# findVer returns the resolved version of a deck, or "" when it is not in the set.
func findVer(resolved as list of catalog.Candidate, name as string) {
    for (def r in $resolved) {
        if ($r.name == $name) {
            return $r.version;
        }
    }
    return "";
}

# hasMissing reports whether a name appears in a missing list.
func hasMissing(missing as list of string, name as string) {
    for (def m in $missing) {
        if ($m == $name) {
            return true;
        }
    }
    return false;
}

# --- the happy paths, ported from the store-backed resolver ------------------

func testResolveFlat() {
    def cat as catalog.Catalog init catalog.empty();
    $cat = plain($cat, "ansi", "1.2.0");
    $cat = plain($cat, "ansi", "1.3.0");
    def g as GraphResult init resolveGraph($cat, {"ansi": "^1.2.0"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.resolved), 1);
    testing.assertEqual(findVer($g.resolved, "ansi"), "1.3.0");
}

func testResolveTransitive() {
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "alpha", "1.0.0", {"beta": "^1.0.0"});
    $cat = plain($cat, "beta", "1.0.0");
    $cat = plain($cat, "beta", "1.2.0");
    def g as GraphResult init resolveGraph($cat, {"alpha": "^1.0.0"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.resolved), 2);
    testing.assertEqual(findVer($g.resolved, "alpha"), "1.0.0");
    testing.assertEqual(findVer($g.resolved, "beta"), "1.2.0");   # highest satisfying
}

func testDiamondUnifiesShared() {
    # top -> left, right; left needs shared ^1.0.0; right needs shared <1.5.0.
    # shared must satisfy BOTH -> highest is 1.4.0 (not 1.9.0).
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "top", "1.0.0", {"left": "^1.0.0", "right": "^1.0.0"});
    $cat = put($cat, "left", "1.0.0", {"shared": "^1.0.0"});
    $cat = put($cat, "right", "1.0.0", {"shared": "<1.5.0"});
    $cat = plain($cat, "shared", "1.0.0");
    $cat = plain($cat, "shared", "1.4.0");
    $cat = plain($cat, "shared", "1.9.0");
    def g as GraphResult init resolveGraph($cat, {"top": "^1.0.0"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.resolved), 4);
    testing.assertEqual(findVer($g.resolved, "shared"), "1.4.0");
}

func testCycleTerminates() {
    # p <-> q mutually require each other; resolution must terminate.
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "p", "1.0.0", {"q": "*"});
    $cat = put($cat, "q", "1.0.0", {"p": "*"});
    def g as GraphResult init resolveGraph($cat, {"p": "*"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.resolved), 2);
    testing.assertEqual(findVer($g.resolved, "p"), "1.0.0");
    testing.assertEqual(findVer($g.resolved, "q"), "1.0.0");
}

func testScopedTransitive() {
    # a scoped deck depending on another scoped deck resolves through the
    # requires map with the "/" intact.
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "@jennifer/routeros", "0.1.0", {"@jennifer/net": "^1.0.0"});
    $cat = plain($cat, "@jennifer/net", "1.0.0");
    def g as GraphResult init resolveGraph($cat, {"@jennifer/routeros": "^0.1.0"});
    testing.assertTrue($g.ok);
    testing.assertEqual(findVer($g.resolved, "@jennifer/net"), "1.0.0");
}

func testResolvedOrderIsDeterministic() {
    # the locked set follows the catalog's deck order, not map iteration order.
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "alpha", "1.0.0", {"beta": "*"});
    $cat = plain($cat, "beta", "1.0.0");
    def g as GraphResult init resolveGraph($cat, {"alpha": "*"});
    testing.assertTrue($g.ok);
    testing.assertEqual($g.resolved[0].name, "alpha");
    testing.assertEqual($g.resolved[1].name, "beta");
}

# --- hard failures (retrying will not help) ---------------------------------

func testUnsatisfiableConflict() {
    # root wants y ^1.0.0; dep a wants y >=2.0.0 -> no y satisfies both.
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "a", "1.0.0", {"y": ">=2.0.0"});
    $cat = plain($cat, "y", "1.0.0");
    $cat = plain($cat, "y", "2.0.0");
    def g as GraphResult init resolveGraph($cat, {"a": "*", "y": "^1.0.0"});
    testing.assertFalse($g.ok);
    testing.assertEqual(len($g.missing), 0);       # not retryable
    testing.assertContains($g.error, "no version of y");
}

func testUnsatisfiableListsEveryConstraint() {
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "a", "1.0.0", {"y": ">=2.0.0"});
    $cat = plain($cat, "y", "1.0.0");
    def g as GraphResult init resolveGraph($cat, {"a": "*", "y": "^1.0.0"});
    testing.assertContains($g.error, "^1.0.0");
    testing.assertContains($g.error, ">=2.0.0");
}

# --- the retryable path (what makes one resolver serve both callers) --------

func testUnknownRootIsReportedAsMissing() {
    def cat as catalog.Catalog init catalog.empty();
    def g as GraphResult init resolveGraph($cat, {"ghost": "*"});
    testing.assertFalse($g.ok);
    testing.assertEqual($g.error, "");             # retryable, not a hard error
    testing.assertTrue(hasMissing($g.missing, "ghost"));
}

func testUnknownDependencyIsReportedAsMissing() {
    # alpha is known, but the beta it requires has not been fetched yet.
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "alpha", "1.0.0", {"beta": "^1.0.0"});
    def g as GraphResult init resolveGraph($cat, {"alpha": "^1.0.0"});
    testing.assertFalse($g.ok);
    testing.assertTrue(hasMissing($g.missing, "beta"));
}

func testMissingReportsEveryUnknownAtOnce() {
    # one round trip per level of the graph, not one per deck.
    def cat as catalog.Catalog init catalog.empty();
    def g as GraphResult init resolveGraph($cat, {"one": "*", "two": "*"});
    testing.assertEqual(len($g.missing), 2);
    testing.assertTrue(hasMissing($g.missing, "one"));
    testing.assertTrue(hasMissing($g.missing, "two"));
}

func testTopUpThenResolveSucceeds() {
    # the caller's fetch loop: resolve, fill in what was missing, resolve again.
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "alpha", "1.0.0", {"beta": "^1.0.0"});
    def first as GraphResult init resolveGraph($cat, {"alpha": "^1.0.0"});
    testing.assertFalse($first.ok);
    for (def name in $first.missing) {
        $cat = plain($cat, $name, "1.0.0");
    }
    def second as GraphResult init resolveGraph($cat, {"alpha": "^1.0.0"});
    testing.assertTrue($second.ok);
    testing.assertEqual(len($second.resolved), 2);
    testing.assertEqual(findVer($second.resolved, "beta"), "1.0.0");
}

# --- the locked set carries the delivery metadata ---------------------------

func testResolvedCarriesDeliveryFields() {
    def cat as catalog.Catalog init catalog.empty();
    def noReqs as map of string to string init {};
    $cat = catalog.add($cat, catalog.Candidate{
        name: "@jennifer/routeros",
        version: "0.1.0",
        url: "https://reg.example/routeros-0.1.0.tar.gz",
        checksum: "sha256:abc",
        kind: "tar.gz",
        ref: "",
        commit: "",
        description: "mikrotik",
        requires: $noReqs,
        engines: {"jennifer": ">=0.24.0"},
        capabilities: []
    });
    def g as GraphResult init resolveGraph($cat, {"@jennifer/routeros": "^0.1.0"});
    testing.assertTrue($g.ok);
    def r as catalog.Candidate init $g.resolved[0];
    testing.assertEqual($r.url, "https://reg.example/routeros-0.1.0.tar.gz");
    testing.assertEqual($r.checksum, "sha256:abc");
    testing.assertEqual($r.kind, "tar.gz");
    testing.assertEqual($r.engines["jennifer"], ">=0.24.0");
}
