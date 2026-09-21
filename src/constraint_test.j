# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for constraint.j. Run with:
#
#     jennifer test cli/constraint_test.j
#
# The overlay splices constraint.j in first, so the tests reach its exported
# surface (satisfies / best) by bare identifier.

use testing;

func testWildcardMatchesAnyValidVersion() {
    testing.assertTrue(satisfies("1.0.0", "*"));
    testing.assertTrue(satisfies("0.0.1", ""));
    testing.assertTrue(satisfies("9.9.9", "any"));
    testing.assertFalse(satisfies("not-a-version", "*"));
}

func testExactMatch() {
    testing.assertTrue(satisfies("1.2.3", "1.2.3"));
    testing.assertTrue(satisfies("1.2.3", "=1.2.3"));
    testing.assertFalse(satisfies("1.2.4", "1.2.3"));
}

func testCaretMajorNonZero() {
    testing.assertTrue(satisfies("1.2.0", "^1.2.0"));
    testing.assertTrue(satisfies("1.4.9", "^1.2.0"));
    testing.assertFalse(satisfies("1.1.9", "^1.2.0"));
    testing.assertFalse(satisfies("2.0.0", "^1.2.0"));
}

func testCaretZeroMinor() {
    # ^0.2.3 -> >=0.2.3 <0.3.0
    testing.assertTrue(satisfies("0.2.3", "^0.2.3"));
    testing.assertTrue(satisfies("0.2.9", "^0.2.3"));
    testing.assertFalse(satisfies("0.3.0", "^0.2.3"));
    testing.assertFalse(satisfies("0.2.2", "^0.2.3"));
}

func testCaretZeroZeroPatch() {
    # ^0.0.3 -> >=0.0.3 <0.0.4
    testing.assertTrue(satisfies("0.0.3", "^0.0.3"));
    testing.assertFalse(satisfies("0.0.4", "^0.0.3"));
}

func testCaretPartial() {
    # ^1 -> <2.0.0
    testing.assertTrue(satisfies("1.9.9", "^1"));
    testing.assertFalse(satisfies("2.0.0", "^1"));
    # ^0 -> <1.0.0
    testing.assertTrue(satisfies("0.9.9", "^0"));
    testing.assertFalse(satisfies("1.0.0", "^0"));
    # ^0.0 -> <0.1.0
    testing.assertTrue(satisfies("0.0.9", "^0.0"));
    testing.assertFalse(satisfies("0.1.0", "^0.0"));
}

func testTilde() {
    # ~1.2.3 -> >=1.2.3 <1.3.0
    testing.assertTrue(satisfies("1.2.3", "~1.2.3"));
    testing.assertTrue(satisfies("1.2.9", "~1.2.3"));
    testing.assertFalse(satisfies("1.3.0", "~1.2.3"));
    # ~1.2 -> >=1.2.0 <1.3.0
    testing.assertTrue(satisfies("1.2.5", "~1.2"));
    testing.assertFalse(satisfies("1.3.0", "~1.2"));
    # ~1 -> >=1.0.0 <2.0.0
    testing.assertTrue(satisfies("1.5.0", "~1"));
    testing.assertFalse(satisfies("2.0.0", "~1"));
}

func testComparators() {
    testing.assertTrue(satisfies("1.2.3", ">=1.2.3"));
    testing.assertTrue(satisfies("2.0.0", ">=1.2.3"));
    testing.assertFalse(satisfies("1.2.2", ">=1.2.3"));
    testing.assertTrue(satisfies("1.2.4", ">1.2.3"));
    testing.assertFalse(satisfies("1.2.3", ">1.2.3"));
    testing.assertTrue(satisfies("1.2.3", "<=1.2.3"));
    testing.assertFalse(satisfies("1.2.4", "<=1.2.3"));
    testing.assertTrue(satisfies("1.2.2", "<1.2.3"));
    testing.assertFalse(satisfies("1.2.3", "<1.2.3"));
}

func testPrereleaseExcludedFromRanges() {
    # A prerelease candidate never satisfies a numeric-core caret / tilde range.
    testing.assertFalse(satisfies("2.0.0-rc.1", "^1.2.0"));
    testing.assertFalse(satisfies("1.3.0-beta", "~1.2.0"));
    # But an exact / comparator constraint can still address it.
    testing.assertTrue(satisfies("1.2.3-rc.1", "=1.2.3-rc.1"));
}

func testInvalidVersionNeverMatches() {
    testing.assertFalse(satisfies("1.2", "^1.0.0"));
    testing.assertFalse(satisfies("", "*"));
}

func testBestPicksHighestSatisfying() {
    def vers as list of string init ["1.0.0", "1.2.0", "1.4.3", "2.0.0"];
    testing.assertEqual(best($vers, "^1.2.0"), "1.4.3");
    testing.assertEqual(best($vers, ">=1.0.0"), "2.0.0");
    testing.assertEqual(best($vers, "~1.0.0"), "1.0.0");
}

func testBestReturnsEmptyWhenNoneMatch() {
    def vers as list of string init ["1.0.0", "1.1.0"];
    testing.assertEqual(best($vers, "^2.0.0"), "");
}

func testBestSkipsInvalidVersions() {
    def vers as list of string init ["bad", "1.2.0", "also-bad", "1.3.0"];
    testing.assertEqual(best($vers, "^1.0.0"), "1.3.0");
}

# --- prereleases are opt-in (server specification 2.4) ----------------------

# The defect this rule fixes: a prerelease sorts above the release it precedes,
# so where it matched at all it was *preferred*, and `>=0.1.0` quietly meant
# "0.1.0 or later, including anything unreleased".
func testAPrereleaseDoesNotSatisfyAWildcard() {
    testing.assertFalse(satisfies("0.2.0-dev", "*"));
    testing.assertFalse(satisfies("0.2.0-dev", "any"));
    testing.assertFalse(satisfies("0.2.0-dev", ""));
}

func testAPrereleaseDoesNotSatisfyAComparator() {
    testing.assertFalse(satisfies("0.2.0-dev", ">=0.1.0"));
    testing.assertFalse(satisfies("0.2.0-dev", ">0.1.0"));
    testing.assertFalse(satisfies("0.2.0-dev", "<0.3.0"));
    testing.assertFalse(satisfies("0.2.0-dev", "<=0.2.0"));
}

func testAPrereleaseDoesNotSatisfyARange() {
    testing.assertFalse(satisfies("0.2.0-dev", "^0.1.0"));
    testing.assertFalse(satisfies("0.2.0-dev", "~0.2.0"));
    # The one spelling that could opt in through a range is closed too: a range
    # targets released versions whatever its operand looks like.
    testing.assertFalse(satisfies("0.2.0-rc.2", "^0.2.0-rc.1"));
}

# The opt-in has to name the candidate's own core.
func testAConstraintNamingAPrereleaseReachesThatCore() {
    testing.assertTrue(satisfies("0.2.0-dev", "=0.2.0-dev"));
    testing.assertTrue(satisfies("0.2.0-rc.1", ">=0.2.0-dev"));
    testing.assertTrue(satisfies("0.2.0", ">=0.2.0-dev"));
    testing.assertFalse(satisfies("0.3.0-alpha", ">=0.2.0-dev"));
}

# An exact constraint naming the release still excludes its prereleases.
func testAnExactReleaseDoesNotMatchItsPrereleases() {
    testing.assertFalse(satisfies("0.2.0-dev", "0.2.0"));
    testing.assertFalse(satisfies("0.2.0-dev", "=0.2.0"));
}

func testTheLastReleaseWinsOverAPrerelease() {
    def vs as list of string init ["0.1.0", "0.2.0-dev"];
    testing.assertEqual(best($vs, "*"), "0.1.0");
    testing.assertEqual(best($vs, ">=0.1.0"), "0.1.0");
    testing.assertEqual(best($vs, "^0.1.0"), "0.1.0");
    testing.assertEqual(best($vs, "=0.2.0-dev"), "0.2.0-dev");
}

# Releases are untouched: the gate only ever looks at prerelease candidates.
func testReleasesAreUnaffected() {
    testing.assertTrue(satisfies("0.2.0", "*"));
    testing.assertTrue(satisfies("0.2.0", ">=0.1.0"));
    testing.assertTrue(satisfies("1.4.9", "^1.2.0"));
    testing.assertEqual(best(["0.1.0", "0.2.0"], ">=0.1.0"), "0.2.0");
}

# Ordering is not what changed, and must not: SemVer 11 puts a prerelease below
# the release it precedes and above the one before it.
func testOrderingIsUnchanged() {
    testing.assertEqual(best(["0.1.0", "0.2.0-dev", "0.2.0"], ">=0.2.0-dev"),
        "0.2.0");
    testing.assertEqual(best(["0.2.0-dev", "0.2.0-rc.1"], ">=0.2.0-dev"),
        "0.2.0-rc.1");
}

# --- the failure message ----------------------------------------------------

func testNewestPrereleasePicksTheHighest() {
    testing.assertEqual(newestPrerelease(["0.2.0-dev", "0.2.0-rc.1"]),
        "0.2.0-rc.1");
    testing.assertEqual(newestPrerelease(["0.1.0", "0.2.0"]), "");
    testing.assertEqual(newestPrerelease([]), "");
    testing.assertEqual(newestPrerelease(["nonsense"]), "");
}

# "no version satisfies *" reads as "this deck does not exist" when every
# published version happens to be unreleased, so the hint names one.
func testThePrereleaseHintNamesTheOptIn() {
    def hint as string init prereleaseHint(["0.2.0-dev", "0.1.0-alpha"]);
    testing.assertContains($hint, "no stable version yet");
    testing.assertContains($hint, "0.2.0-dev");
    testing.assertContains($hint, "=0.2.0-dev");
}

# A deck with releases that failed the constraint failed for an ordinary
# reason, and "no stable version yet" would explain a true failure falsely.
func testNoHintWhenAReleaseExists() {
    testing.assertEqual(prereleaseHint(["0.1.0", "0.2.0-dev"]), "");
    testing.assertEqual(prereleaseHint(["0.1.0"]), "");
}
