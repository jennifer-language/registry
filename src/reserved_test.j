# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for reserved.j. Run with:
#
#     jennifer test src/reserved_test.j
#
# A reserved list is data, so what is worth testing is that the data is sound:
# that every entry could actually be claimed if it were not held, that the list
# does not repeat itself, and that the deliberate omissions are still omitted.

use testing;
use lists;

func testEveryReservedNameIsAValidScope() {
    # a reserved name the grammar rejects protects nothing, and hides the typo
    # that produced it
    def bad as list of string init invalidAmong(defaults());
    testing.assertEqual(len($bad), 0);
}

func testTheListIsDeduplicated() {
    def all as list of string init defaults();
    def seen as map of string to bool init {};
    for (def name in $all) {
        testing.assertFalse(maps.has($seen, $name));
        $seen[$name] = true;
    }
}

func testTheObviousDangerousNamesAreHeld() {
    def all as list of string init defaults();
    for (def name in ["official", "admin", "root", "security", "api", "www",
            "jennifer", "jvc", "registry"]) {
        testing.assertTrue(lists.contains($all, $name));
    }
}

func testBrandsAreDeliberatelyNotHeld() {
    # Not an oversight: under the derived policy the official registry runs,
    # @microsoft is claimable only by the GitHub account called microsoft, so the
    # provider has already settled it. A brand list has no edge and would promise
    # an adjudication nobody here performs. If this ever changes, change the
    # module docblock too - this test exists so the decision is not reversed by
    # accident.
    def all as list of string init defaults();
    for (def brand in ["microsoft", "google", "apple", "amazon", "meta"]) {
        testing.assertFalse(lists.contains($all, $brand));
    }
}

func testTheGroupsAreAllRepresented() {
    def all as list of string init defaults();
    testing.assertTrue(lists.contains($all, "abuse"));
    testing.assertTrue(lists.contains($all, "static"));
    testing.assertTrue(lists.contains($all, "grimoire"));
    testing.assertTrue(lists.contains($all, "example"));
}

func testNamesAreFolded() {
    for (def name in defaults()) {
        testing.assertEqual($name, strings.lower($name));
    }
}
