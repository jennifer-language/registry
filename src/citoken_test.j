# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for citoken.j. Run with:
#
#     jennifer test src/citoken_test.j
#
# A CI token is a standing secret, which 8.10 permits only because it is
# narrower, expiring, and revocable. These tests are those three properties: if
# one of them silently stops holding, the token quietly becomes a copy of its
# owner and nothing else here would notice.

use testing;

def const NOW as int init 1700000000;

func scoped() {
    return Token{
        fingerprint: "abcd", name: "release", scope: "acme", deck: "",
        provider: "github", subject: "1234567",
        createdAt: "1600000000", expiresAt: "", lastUsedAt: ""
    };
}

func perDeck() {
    def t as Token init scoped();
    $t.deck = "@acme/routeros";
    return $t;
}

# --- narrower than its owner --------------------------------------------------

func testAScopedTokenWritesAnyDeckUnderThatScope() {
    testing.assertTrue(covers(scoped(), "@acme/routeros"));
    testing.assertTrue(covers(scoped(), "@acme/ansi"));
}

func testAScopedTokenWritesNothingElse() {
    # the whole point: not a copy of the minting user
    testing.assertFalse(covers(scoped(), "@other/tool"));
}

func testAPerDeckTokenWritesOnlyThatDeck() {
    testing.assertTrue(covers(perDeck(), "@acme/routeros"));
    testing.assertFalse(covers(perDeck(), "@acme/ansi"));
}

func testCoverageIsFolded() {
    testing.assertTrue(covers(scoped(), "@ACME/RouterOS"));
    testing.assertTrue(covers(perDeck(), "@Acme/RouterOS"));
}

func testATokenWithNoScopeCoversNothing() {
    # a zero record must never authorise anything
    def t as Token init scoped();
    $t.scope = "";
    testing.assertFalse(covers($t, "@acme/routeros"));
}

# --- expiry -------------------------------------------------------------------

func testExpiry() {
    def t as Token init scoped();
    $t.expiresAt = "1700000001";
    testing.assertFalse(isExpired($t, NOW));
    # expiry is inclusive: at the stated second it is already gone
    $t.expiresAt = "1700000000";
    testing.assertTrue(isExpired($t, NOW));
}

func testAnEmptyExpiryNeverExpires() {
    testing.assertFalse(isExpired(scoped(), NOW));
}

func testExpiryOf() {
    testing.assertEqual(expiryOf(NOW, 3600), "1700003600");
    # 0 means never, and a caller has to ask for it explicitly
    testing.assertEqual(expiryOf(NOW, 0), "");
    testing.assertEqual(expiryOf(NOW, -1), "");
}

# --- the decision -------------------------------------------------------------

func testAMatchingTokenAuthorises() {
    def v as Verdict init check(scoped(), "@acme/routeros", NOW);
    testing.assertTrue($v.allowed);
    testing.assertEqual($v.fingerprint, "abcd");
}

func testAnUnknownTokenIsRefused() {
    # a zero record from a missed store lookup must fail closed
    def zero as Token init Token{
        fingerprint: "", name: "", scope: "", deck: "", provider: "",
        subject: "", createdAt: "", expiresAt: "", lastUsedAt: ""
    };
    def v as Verdict init check($zero, "@acme/routeros", NOW);
    testing.assertFalse($v.allowed);
    testing.assertContains($v.reason, "no such token");
}

func testAnExpiredTokenIsRefused() {
    def t as Token init scoped();
    $t.expiresAt = "1600000000";
    def v as Verdict init check($t, "@acme/routeros", NOW);
    testing.assertFalse($v.allowed);
    testing.assertContains($v.reason, "expired");
}

func testExpiryIsReportedBeforeScope() {
    # an expired token should say so, not complain about a deck it would never
    # have been allowed to write anyway
    def t as Token init scoped();
    $t.expiresAt = "1600000000";
    testing.assertContains(check($t, "@other/tool", NOW).reason, "expired");
}

func testAWriteOutsideItsScopeIsRefused() {
    def v as Verdict init check(scoped(), "@other/tool", NOW);
    testing.assertFalse($v.allowed);
    testing.assertContains($v.reason, "@acme");
}

func testARefusalNamesTheDeckForAPerDeckToken() {
    def v as Verdict init check(perDeck(), "@acme/ansi", NOW);
    testing.assertFalse($v.allowed);
    testing.assertContains($v.reason, "@acme/routeros");
}

# --- shape --------------------------------------------------------------------

func testTheShapeCheck() {
    testing.assertTrue(looksLikeToken(PREFIX + "0123456789abcdef"));
    testing.assertFalse(looksLikeToken("ghp_0123456789abcdef"));
    testing.assertFalse(looksLikeToken(PREFIX));
    testing.assertFalse(looksLikeToken(""));
}

func testThePrefixIsScannable() {
    # a recognisable prefix is what lets a secret scanner spot one in a public
    # repository before it is abused
    testing.assertTrue(strings.startsWith(PREFIX, "jvc"));
}
