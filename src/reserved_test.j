# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for reserved.j. Run with:
#
#     jennifer test src/reserved_test.j
#
# Every entry is a valid scope, none repeats, and the omitted brands stay omitted.

use testing;
use lists;

func testEveryReservedNameIsAValidScope() {
    # a reserved name the grammar rejects protects nothing and hides a typo
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
    for (def name in [
        "official",
        "admin",
        "root",
        "security",
        "api",
        "www",
        "jennifer",
        "jvc",
        "registry",
        "jennifer-lang",
        "deckyard"
    ]) {
        testing.assertTrue(lists.contains($all, $name));
    }
}

func testBrandsAreDeliberatelyNotHeld() {
    # Guards the decision in the module docblock against accidental reversal;
    # change both together.
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
