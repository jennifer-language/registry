# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

use testing;
use strings;

# keyOf is a signing key from text, as `bin/serve` makes one from its config.
func keyOf(text as string) {
    return convert.bytesFromString($text, "utf-8");
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

func unsealUnderAnotherKey() {
    unseal(keyOf("another key entirely"), seal(keyOf("the right key"), "secret"));
}

func unsealAlteredText() {
    def sealed as string init seal(keyOf("the right key"), "secret");
    def flipped as string init "A" + strings.substring($sealed, 1, len($sealed));
    if ($flipped == $sealed) {
        $flipped = "B" + strings.substring($sealed, 1, len($sealed));
    }
    unseal(keyOf("the right key"), $flipped);
}

func testAWrongKeyOrATamperedRecordIsRefused() {
    # a rotated signing key, or an edited record, must fail rather than hand the
    # forge some other string as a credential
    testing.assertThrows("unsealUnderAnotherKey", "runtime");
    testing.assertThrows("unsealAlteredText", "runtime");
}
