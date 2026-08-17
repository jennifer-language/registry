# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for identity.j. Run with:
#
#     jennifer test src/identity_test.j
#
# `now` is a parameter everywhere in identity.j, so expiry is tested by moving
# the clock rather than by sleeping.

use testing;
use convert;
use strings;

# A token carries a real `exp`, and jwt.verify enforces it against the real
# clock, so a token that must verify has to be minted around now. Only the
# expiry test uses a fixed past instant.
def const PAST as int init 1700000000;
def const ACCOUNT as int init 1234567;

func nowish() {
    return now();
}

func key() {
    return convert.bytesFromString("a signing secret nobody else has", "utf-8");
}

func otherKey() {
    return convert.bytesFromString("a different signing secret entirely", "utf-8");
}

# --- minting and verifying --------------------------------------------------

func testRoundTripCarriesTheIdentity() {
    def token as string init mint(key(), ACCOUNT, "alice", {}, 0, 3600, nowish());
    def who as Identity init verify(key(), $token);
    testing.assertEqual($who.accountId, ACCOUNT);
    testing.assertEqual($who.login, "alice");
    testing.assertEqual($who.expiresAt, nowish() + 3600);
}

func testTokenIsACompactJwt() {
    def token as string init mint(key(), ACCOUNT, "alice", {}, 0, 3600, nowish());
    # header.payload.signature
    testing.assertEqual(len(strings.split($token, ".")), 3);
}

func testSubjectIsTheAccountIdNotTheLogin() {
    # ownership binds to the numeric id, because a login can be re-registered by
    # somebody else after a rename
    def a as string init mint(key(), ACCOUNT, "alice", {}, 0, 3600, nowish());
    def b as string init mint(key(), ACCOUNT, "alice-renamed", {}, 0, 3600, nowish());
    testing.assertEqual(verify(key(), $a).accountId, verify(key(), $b).accountId);
}

# The zero-argument shims assertThrows dispatches by name.
func throwsOnForeignKey() {
    verify(otherKey(), mint(key(), ACCOUNT, "alice", {}, 0, 3600, nowish()));
}

func throwsOnTamperedToken() {
    def token as string init mint(key(), ACCOUNT, "alice", {}, 0, 3600, nowish());
    verify(key(), strings.substring($token, 0, len($token) - 2) + "xy");
}

func throwsOnGarbage() {
    verify(key(), "not-a-token");
}

func testAForeignKeyIsRejected() {
    testing.assertThrows("throwsOnForeignKey", "value");
}

func testATamperedSignatureIsRejected() {
    testing.assertThrows("throwsOnTamperedToken", "value");
}

func testGarbageIsRejected() {
    testing.assertThrows("throwsOnGarbage", "value");
}

func testExpiryIsEnforced() {
    # minted with a one-second life, then verified a minute later
    def token as string init mint(key(), ACCOUNT, "alice", {}, 0, 1, PAST);
    def threw as bool init false;
    try {
        verify(key(), $token);
    } catch (err) {
        $threw = true;
    }
    testing.assertTrue($threw);
}

# --- refresh tokens ---------------------------------------------------------

func testRefreshTokensAreUniqueAndLongEnough() {
    def a as string init newRefresh();
    def b as string init newRefresh();
    testing.assertFalse($a == $b);
    # 32 bytes as hex
    testing.assertEqual(len($a), 64);
}

func testFingerprintIsStableAndNotTheToken() {
    def token as string init newRefresh();
    testing.assertEqual(fingerprint($token), fingerprint($token));
    # the stored value must not be the credential itself
    testing.assertFalse(fingerprint($token) == $token);
    testing.assertEqual(len(fingerprint($token)), 64);
}

func testDifferentTokensFingerprintDifferently() {
    testing.assertFalse(fingerprint(newRefresh()) == fingerprint(newRefresh()));
}
