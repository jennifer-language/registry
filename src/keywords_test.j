# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * White-box overlay for `keywords.j`.
 * @module keywords_test
 */

use testing;
use lists;
use strings;

# The refused terms are base64 here for the same reason they are base64 in the
# module: a test file is a public file, and a crawler reading a list of these
# words does not care that the surrounding function is named "assert". `term`
# decodes one so an assertion still says what it means.
func term(encoded as string) {
    return decodeAll([$encoded])[0];
}

# --- the grammar -------------------------------------------------------------

func testAnOrdinaryKeywordIsAccepted() {
    testing.assertTrue(isWellFormed("cli"));
    testing.assertTrue(isWellFormed("http-client"));
    testing.assertTrue(isWellFormed("base64"));
    testing.assertTrue(isWellFormed("x9"));
}

func testTheGrammarKeepsAKeywordUrlSafe() {
    # /tag/<keyword> is a path segment, so anything needing escaping is out
    testing.assertFalse(isWellFormed("hello world"));
    testing.assertFalse(isWellFormed("a/b"));
    testing.assertFalse(isWellFormed("c++"));
    testing.assertFalse(isWellFormed("café"));
    testing.assertFalse(isWellFormed("Upper"));
}

func testHyphensMayNotLeadTrailOrDouble() {
    # one spelling per tag: "http--client" and "http-client" must not be two
    testing.assertFalse(isWellFormed("-cli"));
    testing.assertFalse(isWellFormed("cli-"));
    testing.assertFalse(isWellFormed("http--client"));
}

func testLengthIsBounded() {
    testing.assertFalse(isWellFormed("a"));
    testing.assertTrue(isWellFormed("ab"));
    testing.assertFalse(isWellFormed(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

# --- the blocklist -----------------------------------------------------------

func testRefusedTermsAreRefused() {
    testing.assertTrue(isBlocked(term("cG9ybg==")));
    testing.assertTrue(isBlocked(term("Y3NhbQ==")));
    testing.assertTrue(isBlocked(term("bnNmdw==")));
    testing.assertTrue(isBlocked(term("bmF6aQ==")));
}

func testTheChildAbuseGroupMatchesInsideALongerWord() {
    # a near miss matters more than a false positive for this group only
    testing.assertTrue(isBlocked("cute-" + term("bG9saWNvbg==") + "-art"));
    testing.assertTrue(isBlocked(term("cGVkb3BoaWxpYQ==")));
    testing.assertTrue(isBlocked("my" + term("Y3NhbQ==") + "thing"));
}

func testOrdinaryWordsContainingABlockedSubstringSurvive() {
    # the substring pass is deliberately limited to the abuse group; applying it
    # to "sex" would refuse "sexagesimal" and to "cp" would refuse half of unix
    testing.assertFalse(isBlocked("sexagesimal"));
    testing.assertFalse(isBlocked("cpp"));
    testing.assertFalse(isBlocked("cpu"));
    testing.assertFalse(isBlocked("cpanel"));
    testing.assertFalse(isBlocked("essex"));
}

func testTheTwoLetterTermIsRefusedExactlyAndOnlyExactly() {
    testing.assertTrue(isBlocked(term("Y3A=")));
    testing.assertFalse(isBlocked("cpio"));
}

func testCasingDoesNotEvadeTheBlocklist() {
    def shouty as list of string init [
        strings.upper(term("cG9ybg==")), strings.upper(term("Y3NhbQ=="))
    ];
    testing.assertEqual(len(normalise($shouty)), 0);
}

# --- normalisation -----------------------------------------------------------

func testKeywordsAreFoldedAndDeduplicated() {
    def out as list of string init normalise(["CLI", "cli", " Cli "]);
    testing.assertEqual(len($out), 1);
    testing.assertEqual($out[0], "cli");
}

func testThePublishersOrderIsKept() {
    # which five survive is the publisher's choice, so the order they wrote is
    # the order that decides
    def out as list of string init normalise(["zebra", "apple", "mango"]);
    testing.assertEqual($out[0], "zebra");
    testing.assertEqual($out[2], "mango");
}

func testOnlyTheFirstFiveAreUsed() {
    def out as list of string init normalise(
        ["one", "two", "three", "four", "five", "six", "seven"]);
    testing.assertEqual(len($out), LIMIT);
    testing.assertFalse(lists.contains($out, "six"));
}

func testBlockedKeywordsDoNotConsumeTheBudget() {
    # the ordering that matters: filtering runs before the cap, so padding the
    # list with refused terms cannot push a real keyword out of the five
    def padding as list of string init lists.concat(abuse(), adult());
    def out as list of string init normalise(
        [$padding[0], $padding[1], $padding[2], $padding[3], $padding[4],
         "cli", "spinner"]);
    testing.assertEqual(len($out), 2);
    testing.assertEqual($out[0], "cli");
    testing.assertEqual($out[1], "spinner");
}

func testMalformedKeywordsDoNotConsumeTheBudgetEither() {
    def out as list of string init normalise(
        ["a", "b/c", "d e", "real-tag"]);
    testing.assertEqual(len($out), 1);
    testing.assertEqual($out[0], "real-tag");
}

func testAnEmptyListIsFine() {
    testing.assertEqual(len(normalise([])), 0);
}

func testNormalisingNeverThrowsOnRubbish() {
    # a bad keyword costs the publisher that keyword, never their release
    testing.assertEqual(len(normalise(["", "   ", "!!!", "éé"])), 0);
}

func testTheAbuseListIsNotEmptyAndIsIncludedInBlocked() {
    # a refactor that dropped a group from blocked() would silently reopen it,
    # and nothing else in the suite would fail
    testing.assertTrue(len(abuse()) > 0);
    for (def one in abuse()) {
        testing.assertTrue(lists.contains(blocked(), $one));
    }
    for (def one in adult()) {
        testing.assertTrue(lists.contains(blocked(), $one));
    }
    for (def one in slur()) {
        testing.assertTrue(lists.contains(blocked(), $one));
    }
}
