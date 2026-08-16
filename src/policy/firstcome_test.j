# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for the first-come claim policy. Run with:
#
#     jennifer test src/policy/firstcome_test.j

use testing;

def const RESERVED as list of string init ["jennifer"];

func someone() {
    return identity.Subject{ provider: "github", id: "1", login: "mplx",
        orgs: [], orgsCheckedAt: "" };
}

func claim(scope as string) {
    return policy().mayClaim(someone(), $scope, RESERVED);
}

func testAnyUnreservedNameIsAllowed() {
    testing.assertTrue(claim("mplx").allowed);
    # including a name with no relationship to the caller at all
    testing.assertTrue(claim("microsoft").allowed);
}

func testReservedIsStillRefused() {
    def d as policy.Decision init claim("jennifer");
    testing.assertFalse($d.allowed);
    testing.assertContains($d.reason, "reserved");
}

func testStanceRecordsRatherThanRefusing() {
    # a first-come registry has decided its users are trusted; refusing every
    # forge it cannot query would make it unusable
    testing.assertEqual(policy().sourceStance(), "record");
}
