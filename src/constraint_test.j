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
