# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for forge.j, the shared interface. Run with:
#
#     jennifer test src/forge_test.j

use testing;

func testHostOfHandlesTheOrdinaryCase() {
    testing.assertEqual(hostOf("https://github.com/acme/deck.git"), "github.com");
}

func testHostOfLowercases() {
    testing.assertEqual(hostOf("https://GitHub.COM/acme/deck.git"), "github.com");
}

func testHostOfStripsPortAndUserinfo() {
    testing.assertEqual(hostOf("https://git.example.test:8443/a/b.git"), "git.example.test");
    testing.assertEqual(hostOf("https://user@git.example.test/a/b.git"), "git.example.test");
}

func testHostOfRejectsWhatHasNoHost() {
    # a file:// URL or a bare path must fall through to "no forge handles this"
    testing.assertEqual(hostOf("/srv/decks/foo"), "");
    testing.assertEqual(hostOf("../relative/path"), "");
}

func testPathOfStripsGitSuffix() {
    testing.assertEqual(pathOf("https://github.com/acme/deck-routeros.git"),
        "acme/deck-routeros");
}

func testPathOfKeepsNestedGroups() {
    # GitLab nests groups arbitrarily deep, so the path is not just owner/repo
    testing.assertEqual(pathOf("https://gitlab.com/group/sub/project.git"),
        "group/sub/project");
}

func testPathOfToleratesATrailingSlash() {
    testing.assertEqual(pathOf("https://github.com/acme/deck/"), "acme/deck");
}

func testPathOfIsEmptyWithoutOne() {
    testing.assertEqual(pathOf("https://github.com"), "");
    testing.assertEqual(pathOf("not a url"), "");
}

func testUnknownIsNotARefusal() {
    # the distinction the whole permission model rests on: an unanswerable check
    # must never read as granted, and must be distinguishable from a denial
    def u as Permission init unknown("no credential");
    testing.assertFalse($u.known);
    testing.assertFalse($u.push);
    def r as Permission init refused("no access");
    testing.assertTrue($r.known);
    testing.assertFalse($r.push);
    def g as Permission init granted("has push");
    testing.assertTrue($g.known);
    testing.assertTrue($g.push);
}
