# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for token.j. Run with:
#
#     jennifer test src/token_test.j

use testing;
use convert;
use strings;

# jwt.verify checks `exp` against the real clock, so tokens that must verify
# are minted around now; only the expiry test uses this past instant.
def const PAST as int init 1700000000;
def const ACCOUNT as string init "1234567";
def const ISSUER as string init "github";

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
    def token as string init mint(key(), ISSUER, ACCOUNT, "alice", {}, 0, 3600, nowish());
    def who as Identity init verify(key(), ISSUER, $token);
    testing.assertEqual($who.subject, ACCOUNT);
    testing.assertEqual($who.login, "alice");
    testing.assertEqual($who.expiresAt, nowish() + 3600);
}

func testTokenIsACompactJwt() {
    def token as string init mint(key(), ISSUER, ACCOUNT, "alice", {}, 0, 3600, nowish());
    # header.payload.signature
    testing.assertEqual(len(strings.split($token, ".")), 3);
}

func testSubjectIsTheAccountIdNotTheLogin() {
    # a login can be re-registered after a rename, so ownership binds to the id
    def a as string init mint(key(), ISSUER, ACCOUNT, "alice", {}, 0, 3600, nowish());
    def b as string init mint(key(), ISSUER, ACCOUNT, "alice-renamed", {}, 0, 3600, nowish());
    testing.assertEqual(verify(key(), ISSUER, $a).subject, verify(key(), ISSUER, $b).subject);
}

# The zero-argument shims assertThrows dispatches by name.
func throwsOnForeignKey() {
    verify(otherKey(), ISSUER, mint(key(), ISSUER, ACCOUNT, "alice", {}, 0, 3600, nowish()));
}

func throwsOnTamperedToken() {
    def token as string init mint(key(), ISSUER, ACCOUNT, "alice", {}, 0, 3600, nowish());
    verify(key(), ISSUER, strings.substring($token, 0, len($token) - 2) + "xy");
}

func throwsOnGarbage() {
    verify(key(), ISSUER, "not-a-token");
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
    def token as string init mint(key(), ISSUER, ACCOUNT, "alice", {}, 0, 1, PAST);
    def threw as bool init false;
    try {
        verify(key(), ISSUER, $token);
    } catch (err) {
        $threw = true;
    }
    testing.assertTrue($threw);
}

# throwsOnNoExpiry signs, with the right key, a token that never expires.
func throwsOnNoExpiry() {
    def claims as json.Value init json.map();
    $claims = json.set($claims, "/iss", ISSUER);
    $claims = json.set($claims, "/sub", ACCOUNT);
    $claims = json.set($claims, "/login", "alice");
    verify(key(), ISSUER, jwt.sign($claims, key(), ALG));
}

func testATokenWithoutExpiryIsRejected() {
    testing.assertThrows("throwsOnNoExpiry", "value");
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

# --- the issuer -------------------------------------------------------------

func throwsOnForeignIssuer() {
    verify(key(), "gitlab", mint(key(), ISSUER, ACCOUNT, "alice", {}, 0, 3600, nowish()));
}

func testATokenMintedForAnotherProviderIsRejected() {
    # the same subject id under another provider is another account
    testing.assertThrows("throwsOnForeignIssuer", "value");
}
