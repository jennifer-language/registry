# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for catalog.j: the pure candidate set the resolver reads.
# Run with:
#
#     jennifer test src/catalog_test.j

use testing;

# withReqs builds a candidate carrying a requirements map.
func withReqs(name as string, version as string, reqs as map of string to string) {
    def c as Candidate init candidate($name, $version);
    $c.requires = $reqs;
    return $c;
}

# --- construction -----------------------------------------------------------

func testEmptyHasNothing() {
    def cat as Catalog init empty();
    testing.assertEqual(len($cat.entries), 0);
    testing.assertFalse(hasDeck($cat, "ansi"));
    testing.assertEqual(len(names($cat)), 0);
}

func testCandidateDefaults() {
    def c as Candidate init candidate("@jennifer/routeros", "0.1.0");
    testing.assertEqual($c.name, "@jennifer/routeros");
    testing.assertEqual($c.version, "0.1.0");
    testing.assertEqual($c.kind, "tar.gz");
    testing.assertEqual($c.url, "");
    testing.assertEqual(len($c.requires), 0);
    testing.assertEqual(len($c.engines), 0);
}

func testAddIsValueSemantic() {
    def cat as Catalog init empty();
    def grown as Catalog init add($cat, candidate("ansi", "1.0.0"));
    testing.assertEqual(len($cat.entries), 0); # the original is untouched
    testing.assertEqual(len($grown.entries), 1);
}

# --- lookup -----------------------------------------------------------------

func testVersionsInInsertionOrder() {
    def cat as Catalog init empty();
    $cat = add($cat, candidate("ansi", "1.2.0"));
    $cat = add($cat, candidate("ansi", "1.3.0"));
    $cat = add($cat, candidate("other", "9.9.9"));
    def vs as list of string init versions($cat, "ansi");
    testing.assertEqual(len($vs), 2);
    testing.assertEqual($vs[0], "1.2.0");
    testing.assertEqual($vs[1], "1.3.0");
}

func testVersionsOfUnknownDeckIsEmpty() {
    def cat as Catalog init empty();
    testing.assertEqual(len(versions($cat, "ghost")), 0);
}

func testNamesDeduplicates() {
    def cat as Catalog init empty();
    $cat = add($cat, candidate("ansi", "1.0.0"));
    $cat = add($cat, candidate("ansi", "1.1.0"));
    $cat = add($cat, candidate("beta", "1.0.0"));
    def ns as list of string init names($cat);
    testing.assertEqual(len($ns), 2);
    testing.assertEqual($ns[0], "ansi");
    testing.assertEqual($ns[1], "beta");
}

func testHasVersion() {
    def cat as Catalog init empty();
    $cat = add($cat, candidate("ansi", "1.0.0"));
    testing.assertTrue(hasVersion($cat, "ansi", "1.0.0"));
    testing.assertFalse(hasVersion($cat, "ansi", "2.0.0"));
    testing.assertFalse(hasVersion($cat, "ghost", "1.0.0"));
}

func testGetReturnsTheCandidate() {
    def cat as Catalog init empty();
    $cat = add($cat, candidate("ansi", "1.0.0"));
    $cat = add($cat, candidate("ansi", "1.1.0"));
    def c as Candidate init get($cat, "ansi", "1.1.0");
    testing.assertEqual($c.version, "1.1.0");
}

func testGetThrowsOnUnknown() {
    testing.assertThrows("getMissing", "catalog");
}

# getMissing is the throwing call testGetThrowsOnUnknown asserts on.
func getMissing() {
    def cat as Catalog init empty();
    return get($cat, "ghost", "1.0.0");
}

# --- requirements -----------------------------------------------------------

func testRequiresReadsTheVersionsOwnMap() {
    def cat as Catalog init empty();
    $cat = add($cat, withReqs("alpha", "1.0.0", {"beta": "^1.0.0"}));
    $cat = add($cat, candidate("beta", "1.0.0"));
    def reqs as map of string to string init requires($cat, "alpha", "1.0.0");
    testing.assertEqual(len($reqs), 1);
    testing.assertEqual($reqs["beta"], "^1.0.0");
    testing.assertEqual(len(requires($cat, "beta", "1.0.0")), 0);
}

func testRequiresOfUnknownVersionIsEmpty() {
    def cat as Catalog init empty();
    testing.assertEqual(len(requires($cat, "ghost", "1.0.0")), 0);
}

# A scoped name (@scope/deck) holds a "/" and must survive as one key.
func testScopedNamesRoundTrip() {
    def cat as Catalog init empty();
    $cat = add($cat, withReqs("@jennifer/routeros", "0.1.0", {"@jennifer/net": "^1.0.0"}));
    testing.assertTrue(hasDeck($cat, "@jennifer/routeros"));
    def reqs as map of string to string init requires($cat, "@jennifer/routeros", "0.1.0");
    testing.assertEqual($reqs["@jennifer/net"], "^1.0.0");
}

func testSelectableVersionsOmitsYankedOnes() {
    def cat as Catalog init empty();
    def live as Candidate init candidate("ansi", "1.0.0");
    def dead as Candidate init candidate("ansi", "1.1.0");
    $dead.yanked = true;
    $cat = add(add($cat, $live), $dead);
    testing.assertEqual(len(versions($cat, "ansi")), 2);
    def sel as list of string init selectableVersions($cat, "ansi");
    testing.assertEqual(len($sel), 1);
    testing.assertEqual($sel[0], "1.0.0");
}

# --- batches and repeats ----------------------------------------------------

func testAddAllAppendsInOrder() {
    def cat as Catalog init add(empty(), candidate("ansi", "1.0.0"));
    def batch as list of Candidate init [
        candidate("ansi", "1.1.0"),
        candidate("other", "2.0.0"),
        candidate("ansi", "1.2.0")
    ];
    def grown as Catalog init addAll($cat, $batch);
    testing.assertEqual(len($cat.entries), 1); # the original is untouched
    testing.assertEqual(len($grown.entries), 4);
    def vs as list of string init versions($grown, "ansi");
    testing.assertEqual(len($vs), 3);
    testing.assertEqual($vs[2], "1.2.0");
    testing.assertEqual(names($grown)[1], "other");
}

func testARepeatedVersionKeepsTheFirst() {
    def first as Candidate init withReqs("ansi", "1.0.0", {"a": "*"});
    def second as Candidate init withReqs("ansi", "1.0.0", {"b": "*"});
    $second.yanked = true;
    def one as Catalog init add(add(empty(), $first), $second);
    testing.assertEqual(len($one.entries), 1);
    testing.assertFalse(get($one, "ansi", "1.0.0").yanked);
    testing.assertTrue(maps.has(requires($one, "ansi", "1.0.0"), "a"));
    # the same through a batch, both against the catalog and within the batch
    def again as Catalog init addAll($one, [$second]);
    testing.assertEqual(len($again.entries), 1);
    def batched as Catalog init addAll(empty(), [$first, $second]);
    testing.assertEqual(len($batched.entries), 1);
    testing.assertFalse(get($batched, "ansi", "1.0.0").yanked);
}

# Two spellings of one deck at one version are one candidate, as the resolver
# reads them; the first added wins.
func testARepeatInAnotherCaseKeepsTheFirst() {
    def cat as Catalog init add(empty(), candidate("@acme/app", "1.0.0"));
    $cat = add($cat, candidate("@Acme/App", "1.0.0"));
    testing.assertEqual(len($cat.entries), 1);
    def pair as list of Candidate init [
        candidate("@acme/app", "1.0.0"),
        candidate("@ACME/app", "1.0.0")
    ];
    def batch as Catalog init addAll(empty(), $pair);
    testing.assertEqual(len($batch.entries), 1);
    testing.assertEqual($batch.entries[0].name, "@acme/app");
}
