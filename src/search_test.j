# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for search.j. Run with:
#
#     jennifer test src/search_test.j
#
# The overlay reaches store and flatdb through their aliases and search.j's own
# names bare.

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
        license: "",
        keywords: []
    };
}

# seeded returns a registry of three decks whose name and description matches
# can be told apart.
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
    def db as flatdb.DB init seeded();
    $db = store.putVersion($db, "@acme/terminal", "an ansi helper", ver("1.0.0"));
    def hits as list of Hit init find($db, "terminal");
    testing.assertEqual(len($hits), 2);
    # @acme/terminal matches by name, @zeta/ansi only by description
    testing.assertEqual($hits[0].name, "@acme/terminal");
    testing.assertEqual($hits[1].name, "@zeta/ansi");
}

func testDeckAppearsOnlyOnceWhenBothMatch() {
    # "ansi" matches @zeta/ansi by name and @acme/terminal by description; no deck
    # is listed twice.
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

func testAnIndexEntryCarriesTheNewestKeywords() {
    def v as store.DeckVersion init ver("3.0.0");
    $v.keywords = ["net", "cli"];
    def db as flatdb.DB init store.putVersion(seeded(), "@acme/net", "", $v);
    def all as json.Value init index($db);
    testing.assertEqual(json.length($all, ""), 3);
    testing.assertEqual(json.asString(json.get($all, "/0/name")), "@acme/net");
    testing.assertEqual(json.asString(json.get($all, "/0/latest")), "3.0.0");
    testing.assertEqual(strings.join(keywordsAt($all, 0), ","), "net,cli");
    testing.assertEqual(len(tagged($all, "cli")), 1);
    testing.assertEqual(len(under($all, "acme")), 2);
}

func testEntriesFollowTheSelectionOrder() {
    def db as flatdb.DB init seeded();
    $db = store.putVersion($db, "@acme/terminal", "an ansi helper", ver("1.0.0"));
    def all as json.Value init index($db);
    def picked as json.Value init entries($all, select($all, "ansi"));
    testing.assertEqual(json.length($picked, ""), 2);
    testing.assertEqual(json.asString(json.get($picked, "/0/name")), "@zeta/ansi");
    testing.assertEqual(json.asString(json.get($picked, "/1/name")), "@acme/terminal");
}

func testSelectInRanksLikeSelectAndReadsTheLoweredText() {
    def all as json.Value init index(seeded());
    def low as json.Value init lowered($all);
    testing.assertEqual(json.length($low, ""), json.length($all, ""));
    testing.assertEqual(len(selectIn($low, "")), json.length($all, ""));
    testing.assertEqual(
        strings.join(lists.map(selectIn($low, "ROUTER"), str), ","),
        strings.join(lists.map(select($all, "ROUTER"), str), ","));
    testing.assertEqual(len(selectIn($low, "nothing-here")), 0);
    # a query with a newline cannot straddle name and description
    testing.assertEqual(len(selectIn($low, "s\nMikro")), 0);
}

func str(i as int) {
    return convert.toString($i);
}

func testTheTagAndScopeMapsAnswerLikeTheScans() {
    def db as flatdb.DB init seeded();
    def v as store.DeckVersion init ver("3.0.0");
    $v.keywords = ["net", "cli"];
    $db = store.putVersion($db, "@acme/net", "", $v);
    def all as json.Value init index($db);
    def tags as json.Value init tagMap($all);
    def scopes as json.Value init scopeMap($all);
    testing.assertEqual(
        strings.join(lists.map(positionsIn($tags, "cli"), str), ","),
        strings.join(lists.map(tagged($all, "cli"), str), ","));
    testing.assertEqual(
        strings.join(lists.map(positionsIn($scopes, "acme"), str), ","),
        strings.join(lists.map(under($all, "acme"), str), ","));
    testing.assertEqual(len(positionsIn($tags, "nothing")), 0);
    testing.assertEqual(len(positionsIn($scopes, "nobody")), 0);
    testing.assertEqual(countsIn($tags)["cli"], 1);
    testing.assertEqual(countsIn($scopes)["acme"], 2);
}
