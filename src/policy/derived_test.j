# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for the derived claim policy. Run with:
#
#     jennifer test src/policy/derived_test.j

use testing;

def const RESERVED as list of string init ["jennifer"];

func mplx() {
    return identity.Subject{ provider: "github", id: "1234567", login: "mplx" };
}

func claim(subject as identity.Subject, scope as string) {
    return policy().mayClaim($subject, $scope, RESERVED);
}

func testOwnNameIsAllowed() {
    testing.assertTrue(claim(mplx(), "mplx").allowed);
}

func testAnotherNameIsRefusedAndSaysWhy() {
    def d as policy.Decision init claim(mplx(), "microsoft");
    testing.assertFalse($d.allowed);
    # the refusal names the username it compared against, and the way out
    testing.assertContains($d.reason, "mplx");
    testing.assertContains($d.reason, "operator");
}

func testComparisonIsCaseInsensitiveOnBothSides() {
    # scopes are stored folded, so a differently-cased username still derives
    def shouty as identity.Subject init identity.Subject{
        provider: "github", id: "1", login: "Netflix"
    };
    testing.assertTrue(claim($shouty, "netflix").allowed);
    testing.assertTrue(claim($shouty, "NETFLIX").allowed);
}

func testAReservedNameIsRefusedEvenWhenItMatches() {
    # somebody whose username is the reserved word still does not get it
    def owner as identity.Subject init identity.Subject{
        provider: "github", id: "9", login: "jennifer"
    };
    def d as policy.Decision init claim($owner, "jennifer");
    testing.assertFalse($d.allowed);
    testing.assertContains($d.reason, "reserved");
}

func testAnIdentityWithNoUsernameDerivesNothing() {
    # an OIDC subject need not carry a username at all
    def anon as identity.Subject init identity.Subject{
        provider: "authelia", id: "sub-abc", login: ""
    };
    def d as policy.Decision init claim($anon, "anything");
    testing.assertFalse($d.allowed);
    testing.assertContains($d.reason, "no username");
}

func testStanceRefusesAnUnverifiableSource() {
    testing.assertEqual(policy().sourceStance(), "verify");
}

func testNameIsNotNarrowed() {
    testing.assertTrue(policy().nameOk("acme", "routeros").allowed);
}
