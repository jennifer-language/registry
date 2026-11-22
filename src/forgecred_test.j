# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.27.0
#
# White-box tests for forgecred.j. Run with:
#
#     jennifer test src/forgecred_test.j

use testing;
use strings;

# keyOf is a signing key from text, as `bin/serve` makes one from its config.
func keyOf(text as string) {
    return encoding.encode("utf-8", $text);
}

func testASealedCredentialComesBack() {
    def key as bytes init keyOf("a signing secret nobody else has");
    testing.assertEqual(unseal($key, seal($key, "gho_live_credential")), "gho_live_credential");
}

func testTheCredentialIsNotStoredInTheClear() {
    def sealed as string init seal(
        keyOf("a signing secret nobody else has"),
        "gho_live_credential");
    testing.assertFalse(strings.contains($sealed, "gho_live_credential"));
}

func testSealingTwiceDiffers() {
    # a fresh nonce each time, so equal credentials do not show as equal records
    def key as bytes init keyOf("a signing secret nobody else has");
    testing.assertNotEqual(seal($key, "same"), seal($key, "same"));
}

func testACredentialSealedByJennifer025StillOpens() {
    # Sealed by jennifer 0.25's two-argument crypto.encrypt (nonce || ciphertext
    # || tag, AES-256-GCM, no AAD) under this key: records already in a database
    # must stay readable after the move to the 0.26 crypto API.
    def old as string init "p+tsWNSKFG2ivgA2O+tLYroZn1PL2H2Unm5ijOuli07xnSNy9IxOtv8kZeMVsg==";
    def key as bytes init keyOf("a signing secret nobody else has");
    testing.assertEqual(unseal($key, $old), "gho_sealed_by_0.25");
}

func testANewSealKeepsTheOldLayout() {
    # nonce (12) + ciphertext (same length as the text) + tag (16)
    def sealed as string init seal(keyOf("a signing secret nobody else has"), "abc");
    testing.assertEqual(len(encoding.fromText("base64", $sealed)), 12 + 3 + 16);
}

func unsealTooShort() {
    unseal(keyOf("the right key"), encoding.toText("base64", crypto.randBytes(27)));
}

func unsealUnderAnotherKey() {
    unseal(keyOf("another key entirely"), seal(keyOf("the right key"), "secret"));
}

func unsealAlteredText() {
    def sealed as string init seal(keyOf("the right key"), "secret");
    def flipped as string init "A" + $sealed[1..len($sealed)];
    if ($flipped == $sealed) {
        $flipped = "B" + $sealed[1..len($sealed)];
    }
    unseal(keyOf("the right key"), $flipped);
}

func testAWrongKeyOrATamperedRecordIsRefused() {
    # must fail rather than hand the forge some other string as a credential
    testing.assertThrows("unsealUnderAnotherKey", "runtime");
    testing.assertThrows("unsealAlteredText", "runtime");
    testing.assertThrows("unsealTooShort", "runtime");
}
