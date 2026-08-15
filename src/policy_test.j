# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for policy.j, the shared interface. Run with:
#
#     jennifer test src/policy_test.j

use testing;

func reserved() {
    return ["jennifer", "Registry"];
}

func testReservedFoldsBothSides() {
    # reserving one casing reserves the name, because scopes are folded
    testing.assertTrue(isReserved("jennifer", reserved()));
    testing.assertTrue(isReserved("JENNIFER", reserved()));
    testing.assertTrue(isReserved("registry", reserved()));
    testing.assertFalse(isReserved("mplx", reserved()));
}

func testReservedIgnoresSurroundingSpace() {
    testing.assertTrue(isReserved("  jennifer  ", reserved()));
}

func testEmptyReservedListReservesNothing() {
    def none as list of string init [];
    testing.assertFalse(isReserved("anything", $none));
}

func testDecisionsCarryTheirReason() {
    # a refusal must say which cause applied, not return a bare false
    def yes as Decision init allow("because");
    testing.assertTrue($yes.allowed);
    testing.assertEqual($yes.reason, "because");
    def no as Decision init deny("nope");
    testing.assertFalse($no.allowed);
    testing.assertEqual($no.reason, "nope");
}

func testReservedDenialNamesTheScope() {
    def d as Decision init reservedDenial("jennifer");
    testing.assertFalse($d.allowed);
    testing.assertContains($d.reason, "@jennifer");
    testing.assertContains($d.reason, "operator");
}

func testAcceptAnyNameAllows() {
    testing.assertTrue(acceptAnyName("acme", "routeros").allowed);
}
