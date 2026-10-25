# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for resolver.j: the transitive dependency graph resolver.
# Run with:
#
#     jennifer test src/resolver_test.j
#
# The overlay reaches resolver.j's names bare (GraphResult, resolveGraph) and
# its imports through their aliases (catalog.add, constraint.satisfies).

use testing;

# put adds one version of a deck, with its own requirements, to a catalog.
func put(
    cat as catalog.Catalog,
    name as string,
    version as string,
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

# yank adds one version of a deck that the repository has withdrawn.
func yank(cat as catalog.Catalog, name as string, version as string) {
    def c as catalog.Candidate init catalog.candidate($name, $version);
    $c.yanked = true;
    return catalog.add($cat, $c);
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
    testing.assertEqual(findVer($g.resolved, "beta"), "1.2.0"); # highest satisfying
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
    testing.assertEqual(len($g.missing), 0); # not retryable
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
    testing.assertEqual($g.error, ""); # retryable, not a hard error
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
    $cat = catalog.add(
        $cat,
        catalog.Candidate{
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
            capabilities: [],
            yanked: false,
            registry: ""
        });
    def g as GraphResult init resolveGraph($cat, {"@jennifer/routeros": "^0.1.0"});
    testing.assertTrue($g.ok);
    def r as catalog.Candidate init $g.resolved[0];
    testing.assertEqual($r.url, "https://reg.example/routeros-0.1.0.tar.gz");
    testing.assertEqual($r.checksum, "sha256:abc");
    testing.assertEqual($r.kind, "tar.gz");
    testing.assertEqual($r.engines["jennifer"], ">=0.24.0");
}

# --- yanked versions ---------------------------------------------------------

func testAYankedVersionIsNotChosen() {
    def cat as catalog.Catalog init catalog.empty();
    $cat = plain($cat, "ansi", "1.2.0");
    $cat = yank($cat, "ansi", "1.3.0");
    def g as GraphResult init resolveGraph($cat, {"ansi": "^1.2.0"});
    testing.assertTrue($g.ok);
    testing.assertEqual(findVer($g.resolved, "ansi"), "1.2.0");
}

func testYankingEveryVersionLeavesNothingToChoose() {
    def cat as catalog.Catalog init catalog.empty();
    $cat = yank($cat, "ansi", "1.2.0");
    def g as GraphResult init resolveGraph($cat, {"ansi": "^1.2.0"});
    testing.assertFalse($g.ok);
    testing.assertContains($g.error, "no version of ansi satisfies");
}

func testAYankedVersionIsStillSkippedForATransitiveNeed() {
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "app", "1.0.0", {"ansi": "^1.0.0"});
    $cat = plain($cat, "ansi", "1.0.0");
    $cat = yank($cat, "ansi", "1.9.0");
    def g as GraphResult init resolveGraph($cat, {"app": "^1.0.0"});
    testing.assertTrue($g.ok);
    testing.assertEqual(findVer($g.resolved, "ansi"), "1.0.0");
}

# --- requirements of decks no longer chosen -----------------------------------

func testADroppedDeckStopsImposingRequirements() {
    # m@2 pulls in x, and x and y require each other; n then forces m below 2.
    # Once m@1 is chosen nothing reachable needs x or y, so their requirements
    # must stop counting. They used to keep counting, and x and y swapped in and
    # out of the choice for every remaining round.
    def cat as catalog.Catalog init catalog.empty();
    $cat = plain($cat, "m", "1.0.0");
    $cat = put($cat, "m", "2.0.0", {"x": "*"});
    $cat = put($cat, "x", "1.0.0", {"y": "*"});
    $cat = put($cat, "y", "1.0.0", {"x": "*"});
    $cat = put($cat, "n", "1.0.0", {"m": "<2.0.0"});
    def g as GraphResult init resolveGraph($cat, {"m": "*", "n": "*"});
    testing.assertTrue($g.ok);
    testing.assertEqual(findVer($g.resolved, "m"), "1.0.0");
    testing.assertEqual(findVer($g.resolved, "x"), "");
}

func testAlternatingChoicesFailAtOnceAndSaySo() {
    # a@2 wants b<2 and b@2 wants a<2: taking the highest that fits alternates
    # between {a2, b2} and {a1, b1}. This resolver does not backtrack, so it
    # cannot find {a1, b2}; what it must do is stop on the first repeat with a
    # message that names the cycle, not run out its round budget
    def cat as catalog.Catalog init catalog.empty();
    $cat = plain($cat, "a", "1.0.0");
    $cat = put($cat, "a", "2.0.0", {"b": "<2.0.0"});
    $cat = plain($cat, "b", "1.0.0");
    $cat = put($cat, "b", "2.0.0", {"a": "<2.0.0"});
    def g as GraphResult init resolveGraph($cat, {"a": "*", "b": "*"});
    testing.assertFalse($g.ok);
    testing.assertContains($g.error, "alternating");
}

func testAnUnusableVersionCannotCrashAFailedResolution() {
    def cat as catalog.Catalog init catalog.empty();
    $cat = plain($cat, "a", "1.0.0");
    $cat = plain($cat, "a", "99999999999999999999.0.0-1");
    def g as GraphResult init resolveGraph($cat, {"a": "^2"});
    testing.assertFalse($g.ok);
    testing.assertContains($g.error, "no version of a");
}

func testAnInvalidConstraintIsNamedInTheFailure() {
    def cat as catalog.Catalog init catalog.empty();
    $cat = plain($cat, "a", "1.0.0");
    def g as GraphResult init resolveGraph($cat, {"a": "^ 1"});
    testing.assertFalse($g.ok);
    testing.assertContains($g.error, "not a valid constraint");
}

# --- a prerelease the constraint names ---------------------------------------

func testAnExactPrereleasePinResolves() {
    def cat as catalog.Catalog init catalog.empty();
    $cat = plain($cat, "a", "1.0.0-rc.1");
    def g as GraphResult init resolveGraph($cat, {"a": "=1.0.0-rc.1"});
    testing.assertTrue($g.ok);
    testing.assertEqual(findVer($g.resolved, "a"), "1.0.0-rc.1");
}

func testAPrereleaseFloorResolvesToTheHighestItReaches() {
    def cat as catalog.Catalog init catalog.empty();
    $cat = plain($cat, "a", "0.9.0");
    $cat = plain($cat, "a", "1.0.0-rc.1");
    $cat = plain($cat, "a", "1.0.0-rc.2");
    def g as GraphResult init resolveGraph($cat, {"a": ">=1.0.0-rc.1"});
    testing.assertTrue($g.ok);
    testing.assertEqual(findVer($g.resolved, "a"), "1.0.0-rc.2");
}

func testAWildcardStillNeverPicksAPrerelease() {
    def cat as catalog.Catalog init catalog.empty();
    $cat = plain($cat, "a", "0.9.0");
    $cat = plain($cat, "a", "1.0.0-rc.1");
    def g as GraphResult init resolveGraph($cat, {"a": "*"});
    testing.assertTrue($g.ok);
    testing.assertEqual(findVer($g.resolved, "a"), "0.9.0");
    def only as catalog.Catalog init plain(catalog.empty(), "b", "1.0.0-rc.1");
    def h as GraphResult init resolveGraph($only, {"b": "*"});
    testing.assertFalse($h.ok);
    testing.assertContains($h.error, "no stable version yet");
}

# --- deck names are case-insensitive -----------------------------------------

func testAMixedCaseRootFindsTheFoldedDeck() {
    # the registry answers `@acme/app`; the root used to stay missing for ever
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "@acme/app", "1.0.0", {"@Acme/Lib": "^1.0.0"});
    $cat = plain($cat, "@acme/lib", "1.2.0");
    def g as GraphResult init resolveGraph($cat, {"@Acme/App": "*"});
    testing.assertTrue($g.ok);
    testing.assertEqual(findVer($g.resolved, "@acme/app"), "1.0.0");
    testing.assertEqual(findVer($g.resolved, "@acme/lib"), "1.2.0");
}

func testMissingNamesAreFolded() {
    def g as GraphResult init resolveGraph(catalog.empty(), {"@Acme/App": "*"});
    testing.assertFalse($g.ok);
    testing.assertTrue(hasMissing($g.missing, "@acme/app"));
}

func testAMixedCaseCatalogNameResolvesFolded() {
    def cat as catalog.Catalog init plain(catalog.empty(), "@Acme/App", "1.0.0");
    def g as GraphResult init resolveGraph($cat, {"@acme/app": "*"});
    testing.assertTrue($g.ok);
    testing.assertEqual($g.resolved[0].name, "@acme/app");
}

# --- a repeated (name, version) ---------------------------------------------

func testARepeatedVersionUsesTheFirstEntrysRequirements() {
    # catalog.get takes the first; the round used to read the last one's
    # requirements, so the graph and the locked set disagreed
    def first as catalog.Candidate init catalog.candidate("a", "1.0.0");
    $first.requires = {"b": "*"};
    def second as catalog.Candidate init catalog.candidate("a", "1.0.0");
    $second.requires = {"c": "*"};
    def entries as list of catalog.Candidate init [$first, $second];
    def cat as catalog.Catalog init catalog.Catalog{entries: $entries};
    $cat = plain($cat, "b", "1.0.0");
    def g as GraphResult init resolveGraph($cat, {"a": "*"});
    testing.assertTrue($g.ok);
    testing.assertEqual(findVer($g.resolved, "b"), "1.0.0");
    testing.assertEqual(findVer($g.resolved, "c"), "");
}

# --- the locked set ----------------------------------------------------------

func testTheLockedSetFollowsCatalogOrder() {
    def cat as catalog.Catalog init catalog.empty();
    $cat = plain($cat, "z", "1.0.0");
    $cat = put($cat, "app", "1.0.0", {"z": "*", "m": "*"});
    $cat = plain($cat, "m", "1.0.0");
    $cat = plain($cat, "z", "2.0.0");
    $cat = plain($cat, "unused", "1.0.0");
    def g as GraphResult init resolveGraph($cat, {"app": "*"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.resolved), 3);
    testing.assertEqual($g.resolved[0].name, "z");
    testing.assertEqual($g.resolved[0].version, "2.0.0");
    testing.assertEqual($g.resolved[1].name, "app");
    testing.assertEqual($g.resolved[2].name, "m");
}

# --- the pick cache ----------------------------------------------------------

func testOneInvalidConstraintDoesNotReuseThePickOfAValidPair() {
    # Round 3 constrains a by the pair "^1.0.0" and ">=1.0.0" (from m@2 and r);
    # once k forces m down to 1, only m@1's single, invalid "^1.0.0, >=1.0.0"
    # remains. Joined with ", " the two sets made one cache key, and the
    # invalid one silently reused the valid pair's pick.
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "m", "1.0.0", {"a": "^1.0.0, >=1.0.0"});
    $cat = put($cat, "m", "2.0.0", {"a": "^1.0.0", "r": "*"});
    $cat = put($cat, "r", "1.0.0", {"a": ">=1.0.0"});
    $cat = put($cat, "n", "1.0.0", {"k": "*"});
    $cat = put($cat, "k", "1.0.0", {"m": "<2.0.0"});
    $cat = plain($cat, "a", "1.0.0");
    def g as GraphResult init resolveGraph($cat, {"m": "*", "n": "*"});
    testing.assertFalse($g.ok);
    testing.assertContains($g.error, "not a valid constraint");
}

# --- a choice the constraints have overtaken ---------------------------------

func testAnOvertakenChoiceDoesNotFailTheGraph() {
    # x@2 wants z ^2, but y wants x ^1 and z ^1. Round two counted x@2's
    # requirement although x@2 was already ruled out, and failed with "no
    # version of @a/z satisfies ^2.0.0, ^1.0.0"; x 1, y 2, z 1 is a solution.
    def cat as catalog.Catalog init catalog.empty();
    $cat = plain($cat, "@a/x", "1.0.0");
    $cat = put($cat, "@a/x", "2.0.0", {"@a/z": "^2.0.0"});
    $cat = put($cat, "@a/y", "2.0.0", {"@a/x": "^1.0.0", "@a/z": "^1.0.0"});
    $cat = plain($cat, "@a/z", "1.0.0");
    $cat = plain($cat, "@a/z", "2.0.0");
    def g as GraphResult init resolveGraph($cat, {"@a/x": "*", "@a/y": "*"});
    testing.assertTrue($g.ok);
    testing.assertEqual($g.error, "");
    testing.assertEqual(len($g.resolved), 3);
    testing.assertEqual(findVer($g.resolved, "@a/x"), "1.0.0");
    testing.assertEqual(findVer($g.resolved, "@a/y"), "2.0.0");
    testing.assertEqual(findVer($g.resolved, "@a/z"), "1.0.0");
}

func testAnOvertakenChoiceSendsNobodyToFetch() {
    # x@2 names a deck nobody has; y rules x@2 out, so the caller must not be
    # sent to fetch it (it used to come back in `missing`)
    def cat as catalog.Catalog init catalog.empty();
    $cat = plain($cat, "@a/x", "1.0.0");
    $cat = put($cat, "@a/x", "2.0.0", {"@evil/ghost": "*"});
    $cat = put($cat, "@a/y", "2.0.0", {"@a/x": "^1.0.0"});
    def g as GraphResult init resolveGraph($cat, {"@a/x": "*", "@a/y": "*"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.missing), 0);
    testing.assertEqual(findVer($g.resolved, "@a/x"), "1.0.0");
    testing.assertEqual(findVer($g.resolved, "@evil/ghost"), "");
}

func testAReplacementChoiceStillReportsWhatItNeeds() {
    # the settled graph does need the ghost, so it is still reported
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "@a/x", "1.0.0", {"@a/ghost": "*"});
    $cat = plain($cat, "@a/x", "2.0.0");
    $cat = put($cat, "@a/y", "2.0.0", {"@a/x": "^1.0.0"});
    def g as GraphResult init resolveGraph($cat, {"@a/x": "*", "@a/y": "*"});
    testing.assertFalse($g.ok);
    testing.assertEqual($g.error, "");
    testing.assertEqual(len($g.missing), 1);
    testing.assertTrue(hasMissing($g.missing, "@a/ghost"));
}

func testAFailureWaitsForADeckReachedLater() {
    # c@2 wants d ^2, which does not exist, and the m that rules c@2 out is
    # only reached a round later, through k. Failing on d as soon as it was
    # named lost r 1, c 1, k 1, m 1.
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "r", "1.0.0", {"c": "*", "k": "*"});
    $cat = plain($cat, "c", "1.0.0");
    $cat = put($cat, "c", "2.0.0", {"d": "^2.0.0"});
    $cat = put($cat, "k", "1.0.0", {"m": "*"});
    $cat = put($cat, "m", "1.0.0", {"c": "^1.0.0"});
    $cat = plain($cat, "d", "1.0.0");
    def g as GraphResult init resolveGraph($cat, {"r": "*"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.resolved), 4);
    testing.assertEqual(findVer($g.resolved, "c"), "1.0.0");
    testing.assertEqual(findVer($g.resolved, "d"), "");
}

func testARootWithNothingThatFitsStillFails() {
    # deferring a failure until the round settles must not turn it into success
    def cat as catalog.Catalog init plain(catalog.empty(), "a", "1.0.0");
    def g as GraphResult init resolveGraph($cat, {"a": "^2.0.0"});
    testing.assertFalse($g.ok);
    testing.assertEqual(len($g.resolved), 0);
    testing.assertContains($g.error, "no version of a satisfies ^2.0.0");
}

func testAConflictReachedThroughAReplacementStillFails() {
    # b@2 is overtaken by a's b ^1, and b@1 then wants c ^2 while the root wants
    # c ^1: a genuine conflict, reported once the round has settled
    def cat as catalog.Catalog init catalog.empty();
    $cat = put($cat, "a", "1.0.0", {"b": "^1.0.0"});
    $cat = put($cat, "b", "1.0.0", {"c": "^2.0.0"});
    $cat = plain($cat, "b", "2.0.0");
    $cat = plain($cat, "c", "1.0.0");
    $cat = plain($cat, "c", "2.0.0");
    def g as GraphResult init resolveGraph($cat, {"a": "*", "b": "*", "c": "^1.0.0"});
    testing.assertFalse($g.ok);
    testing.assertEqual(len($g.missing), 0);
    testing.assertContains($g.error, "no version of c satisfies ^1.0.0, ^2.0.0");
}
