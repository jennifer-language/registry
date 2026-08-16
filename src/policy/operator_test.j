# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for the operator-only claim policy. Run with:
#
#     jennifer test src/policy/operator_test.j

use testing;

def const RESERVED as list of string init ["jennifer"];

func someone() {
    return identity.Subject{ provider: "github", id: "1", login: "mplx",
        orgs: [], orgsCheckedAt: "" };
}

func testNothingIsSelfClaimable() {
    def p as policy.Policy init policy();
    # not even the caller's own username, which `derived` would allow
    testing.assertFalse($p.mayClaim(someone(), "mplx", RESERVED).allowed);
    testing.assertFalse($p.mayClaim(someone(), "anything", RESERVED).allowed);
    testing.assertFalse($p.mayClaim(someone(), "jennifer", RESERVED).allowed);
}

func testTheRefusalPointsAtTheOperator() {
    def d as policy.Decision init policy().mayClaim(someone(), "mplx", RESERVED);
    testing.assertContains($d.reason, "operator");
    testing.assertContains($d.reason, "@mplx");
}

func testStanceRefusesAnUnverifiableSource() {
    testing.assertEqual(policy().sourceStance(), "verify");
}
