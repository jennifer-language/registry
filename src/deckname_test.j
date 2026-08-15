# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for deckname.j. Run with:
#
#     jennifer test src/deckname_test.j
#
# The grammar is specification 2.1: lowercase, folded rather than rejected, with
# hyphens in the scope half only and Windows device names refused outright.

use testing;

# --- folding ----------------------------------------------------------------

func testFoldLowercases() {
    testing.assertEqual(fold("@Netflix/Foo"), "@netflix/foo");
    testing.assertEqual(fold("ANSI"), "ansi");
}

func testFoldTrims() {
    testing.assertEqual(fold("  @acme/tool  "), "@acme/tool");
}

func testFoldIsIdempotent() {
    testing.assertEqual(fold(fold("@Acme/Tool")), fold("@Acme/Tool"));
}

# --- the deck half ----------------------------------------------------------

func testDeckHalfAcceptsLettersAndDigits() {
    testing.assertTrue(isIdent("ansi"));
    testing.assertTrue(isIdent("routeros"));
    testing.assertTrue(isIdent("utf8"));
    testing.assertTrue(isIdent("a"));
}

func testDeckHalfRejectsHyphens() {
    # this half becomes the bound Jennifer namespace, which takes no hyphen
    testing.assertFalse(isIdent("my-deck"));
    testing.assertFalse(isIdent("a-b"));
}

func testDeckHalfRejectsUppercase() {
    # it is checked after folding, so an uppercase half means the caller skipped
    # the fold rather than that the name is legal
    testing.assertFalse(isIdent("Ansi"));
    testing.assertFalse(isIdent("A"));
}

func testDeckHalfRejectsALeadingDigitOrUnderscore() {
    testing.assertFalse(isIdent("2fast"));
    testing.assertFalse(isIdent("my_deck"));
}

func testDeckHalfRejectsEmptyAndOverlong() {
    testing.assertFalse(isIdent(""));
    def long as string init "a";
    for (def i as int init 0; $i < 64; $i = $i + 1) {
        $long = $long + "a";
    }
    testing.assertFalse(isIdent($long));
}

# --- the scope half ---------------------------------------------------------

func testScopeHalfAcceptsHyphens() {
    # the whole reason the two halves differ: real account names carry hyphens
    testing.assertTrue(isScopeIdent("jennifer-language"));
    testing.assertTrue(isScopeIdent("my-org"));
    testing.assertTrue(isScopeIdent("a-b-c"));
}

func testScopeHalfAcceptsTheSimpleCases() {
    testing.assertTrue(isScopeIdent("acme"));
    testing.assertTrue(isScopeIdent("a"));
    testing.assertTrue(isScopeIdent("tool2"));
}

func testScopeHalfRejectsEdgeHyphens() {
    testing.assertFalse(isScopeIdent("-acme"));
    testing.assertFalse(isScopeIdent("acme-"));
}

func testScopeHalfRejectsDoubleHyphens() {
    testing.assertFalse(isScopeIdent("a--b"));
}

func testScopeHalfRejectsUppercaseAndUnderscores() {
    testing.assertFalse(isScopeIdent("Acme"));
    testing.assertFalse(isScopeIdent("my_org"));
}

# --- names reserved by the host filesystem ----------------------------------

func testWindowsDeviceNamesAreRefused() {
    # vendor/con/ cannot be created on Windows, whatever else the name satisfies
    testing.assertTrue(isReservedDevice("con"));
    testing.assertFalse(isIdent("con"));
    testing.assertFalse(isScopeIdent("nul"));
    testing.assertFalse(isValid("@con/tool"));
    testing.assertFalse(isValid("@acme/aux"));
    testing.assertFalse(isValid("com1"));
}

func testTheComparisonIsAgainstTheFoldedName() {
    testing.assertFalse(isValid("@CON/tool"));
    testing.assertFalse(isValid("@acme/PRN"));
}

func testSimilarNamesAreStillFine() {
    testing.assertTrue(isIdent("console"));
    testing.assertTrue(isIdent("com10"));
    testing.assertTrue(isIdent("auxiliary"));
}

# --- whole names ------------------------------------------------------------

func testScopedNamesWithHyphenatedScopes() {
    # the case that motivated the grammar split
    testing.assertTrue(isValid("@jennifer-language/routeros"));
    testing.assertTrue(isValid("@acme/tool2"));
}

func testAHyphenInTheDeckHalfIsRejected() {
    testing.assertFalse(isValid("@acme/my-deck"));
}

func testNamesAreCaseInsensitive() {
    testing.assertTrue(isValid("@Netflix/Foo"));
    testing.assertTrue(isValid("ANSI"));
}

func testBareNamesUseTheDeckGrammar() {
    testing.assertTrue(isValid("ansi"));
    testing.assertFalse(isValid("my-module"));
}

func testMalformedNamesAreRejected() {
    testing.assertFalse(isValid("@acme"));
    testing.assertFalse(isValid("@/tool"));
    testing.assertFalse(isValid("@acme/"));
    testing.assertFalse(isValid(""));
}

# --- decomposition ----------------------------------------------------------

func testScopeAndDeckOfFold() {
    testing.assertEqual(scopeOf("@Jennifer-Language/RouterOS"), "jennifer-language");
    testing.assertEqual(deckOf("@Jennifer/RouterOS"), "routeros");
}

func testScopeOfIsEmptyForABareName() {
    testing.assertEqual(scopeOf("ansi"), "");
    testing.assertEqual(deckOf("ANSI"), "ansi");
}

func testIsScopedIsAShapeTest() {
    testing.assertTrue(isScoped("@acme/tool"));
    testing.assertFalse(isScoped("ansi"));
    testing.assertFalse(isScoped("acme/tool"));
}

func testVendorSubdirIsFolded() {
    # what keeps a lockfile meaning the same thing on a case-insensitive
    # filesystem as on a case-sensitive one
    testing.assertEqual(vendorSubdir("@Jennifer/RouterOS"), "jennifer/routeros");
    testing.assertEqual(vendorSubdir("@my-org/tool"), "my-org/tool");
    testing.assertEqual(vendorSubdir("ANSI"), "ansi");
}

func testEntryFileIsFolded() {
    testing.assertEqual(entryFile("@Jennifer/RouterOS"), "routeros.j");
    testing.assertEqual(entryFile("ansi"), "ansi.j");
}

func testPtrEscape() {
    testing.assertEqual(ptrEscape("@acme/tool"), "@acme~1tool");
    testing.assertEqual(ptrEscape("a~b"), "a~0b");
}
