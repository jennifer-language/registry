# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for search.j. Run with:
#
#     jennifer test src/search_test.j
#
# search.j imports store and flatdb, so the overlay reaches them through those
# aliases and Hit / find / matchesName by bare name.

use testing;

def const COMMIT as string init "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293";

# ver builds a git-kind DeckVersion.
func ver(v as string) {
    return store.DeckVersion{
        version: $v,
        kind: store.KIND_GIT,
        url: "https://example.test/d.git",
        ref: "v" + $v,
        commit: COMMIT,
        checksum: "",
        requires: {},
        engines: {},
        capabilities: [],
        description: "",
        publishedAt: "0",
        yanked: false,
        license: ""
    };
}

# seeded returns a registry with three decks whose names and descriptions are
# chosen so name matches and description matches can be told apart.
func seeded() {
    def db as flatdb.DB init store.open("/no/such/jvc/search/missing.json");
    $db = store.putVersion($db, "@acme/routeros", "MikroTik router client", ver("0.1.0"));
    $db = store.putVersion($db, "@acme/routeros", "", ver("0.2.0"));
    $db = store.putVersion($db, "@acme/net", "sockets and DNS", ver("1.0.0"));
    $db = store.putVersion($db, "@zeta/ansi", "terminal styling", ver("2.0.0"));
    return $db;
}

# names extracts the hit names, so an assertion reads as an ordered list.
func names(hits as list of Hit) {
    def out as list of string init [];
    for (def hit in $hits) {
        $out[] = $hit.name;
    }
    return $out;
}

func testEmptyQueryReturnsEverythingAlphabetically() {
    def hits as list of Hit init find(seeded(), "");
    testing.assertEqual(len($hits), 3);
    def got as list of string init names($hits);
    testing.assertEqual($got[0], "@acme/net");
    testing.assertEqual($got[1], "@acme/routeros");
    testing.assertEqual($got[2], "@zeta/ansi");
}

func testEmptyRegistrySearchesToNothing() {
    def db as flatdb.DB init store.open("/no/such/jvc/search/empty.json");
    testing.assertEqual(len(find($db, "")), 0);
    testing.assertEqual(len(find($db, "anything")), 0);
}

func testMatchesOnName() {
    def hits as list of Hit init find(seeded(), "routeros");
    testing.assertEqual(len($hits), 1);
    testing.assertEqual($hits[0].name, "@acme/routeros");
}

func testMatchesOnScope() {
    def hits as list of Hit init find(seeded(), "@acme");
    testing.assertEqual(len($hits), 2);
}

func testMatchIsCaseInsensitive() {
    testing.assertEqual(len(find(seeded(), "ROUTEROS")), 1);
    testing.assertEqual(len(find(seeded(), "RouterOS")), 1);
}

func testQueryIsTrimmed() {
    testing.assertEqual(len(find(seeded(), "   routeros  ")), 1);
    # a whitespace-only query is an empty query, not a search for a space
    testing.assertEqual(len(find(seeded(), "   ")), 3);
}

func testMatchesOnDescription() {
    def hits as list of Hit init find(seeded(), "sockets");
    testing.assertEqual(len($hits), 1);
    testing.assertEqual($hits[0].name, "@acme/net");
}

func testNameMatchesRankAboveDescriptionMatches() {
    # "ansi" is @zeta/ansi's name, and nothing else's; "terminal" is only in its
    # description. A query hitting one deck by name and another by description
    # must put the name match first.
    def db as flatdb.DB init seeded();
    $db = store.putVersion($db, "@acme/terminal", "an ansi helper", ver("1.0.0"));
    def hits as list of Hit init find($db, "terminal");
    testing.assertEqual(len($hits), 2);
    # @acme/terminal matches by name, @zeta/ansi only by description
    testing.assertEqual($hits[0].name, "@acme/terminal");
    testing.assertEqual($hits[1].name, "@zeta/ansi");
}

func testDeckAppearsOnlyOnceWhenBothMatch() {
    # "ansi" is in @zeta/ansi's name and in @acme/terminal's description; the
    # deck matching on both must not be listed twice.
    def db as flatdb.DB init seeded();
    $db = store.putVersion($db, "@acme/terminal", "an ansi helper", ver("1.0.0"));
    def hits as list of Hit init find($db, "ansi");
    testing.assertEqual(len($hits), 2);
    testing.assertEqual($hits[0].name, "@zeta/ansi");
}

func testHitCarriesLatestAndCount() {
    def hits as list of Hit init find(seeded(), "routeros");
    testing.assertEqual($hits[0].versions, 2);
    # the latest is the highest by SemVer, not the last written
    testing.assertEqual($hits[0].latest, "0.2.0");
    testing.assertEqual($hits[0].description, "MikroTik router client");
}

func testNoMatchIsEmpty() {
    testing.assertEqual(len(find(seeded(), "nothing-matches-this")), 0);
}
