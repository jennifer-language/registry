# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for featured.j: which deck each landing-page card picks.
# Run with:
#
#     jennifer test src/featured_test.j

use testing;
import "./search.j" as search;

# 2026-08-17T20:00:00Z, the clock every test reads.
def const NOW as int init 1786994400;
def const DAY as int init 86400;
def const COMMIT as string init "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293";

# ver builds a live git-kind version published `daysAgo` days before NOW.
func ver(v as string, daysAgo as int) {
    return store.DeckVersion{
        version: $v,
        kind: store.KIND_GIT,
        url: "https://example.test/d.git",
        ref: $v,
        commit: COMMIT,
        checksum: "",
        requires: {},
        engines: {},
        capabilities: [],
        description: "",
        publishedAt: convert.toString(NOW - $daysAgo * DAY),
        yanked: false,
        license: "",
        keywords: []
    };
}

func emptyDb() {
    return store.open("/no/such/registry/featured/missing.json");
}

# looked records `n` lookups of a deck in the current hour.
func looked(db as flatdb.DB, name as string, n as int) {
    def rec as json.Value init stats.record(json.map(), stats.hourKey(NOW), $n, NOW);
    return store.putStats($db, $name, $rec);
}

# cards is the label and deck of every card, "label=deck" joined by ", ".
func cards(db as flatdb.DB, now as int) {
    def out as list of string init [];
    for (def p in fromJson(build($db, search.index($db), $now))) {
        $out[] = $p.label + "=" + $p.name;
    }
    return strings.join($out, ", ");
}

func testAnEmptyRegistryFeaturesNothing() {
    testing.assertEqual(cards(emptyDb(), NOW), "");
}

# With no lookups and no dependents, only the cards that need neither appear.
func testANewRegistryShowsOnlyWhatItCanMeasure() {
    def db as flatdb.DB init store.putVersion(emptyDb(), "@acme/one", "the first", ver("0.1.0", 3));
    testing.assertEqual(cards($db, NOW), "Newest=@acme/one");
    $db = store.putVersion($db, "@acme/two", "", ver("0.1.0", 9));
    testing.assertEqual(cards($db, NOW), "Newest=@acme/one, Deck of the day=@acme/two");
}

# One deck tops every count, but appears once: each card takes the best deck the
# cards before it left.
func testADeckIsFeaturedOnce() {
    def db as flatdb.DB init emptyDb();
    for (def letter in strings.chars("abcdefg")) {
        $db = store.putVersion($db, "@acme/" + $letter, "", ver("1.0.0", 20));
    }
    $db = store.putVersion($db, "@acme/a", "", ver("1.1.0", 1));
    $db = store.putVersion($db, "@acme/b", "", ver("1.1.0", 2));
    $db = looked($db, "@acme/a", 50);
    $db = looked($db, "@acme/b", 40);
    $db = looked($db, "@acme/c", 30);
    def got as string init cards($db, NOW);
    testing.assertContains($got, "Most resolved=@acme/a");
    testing.assertContains($got, "Busy this week=@acme/b");
    # @acme/a and @acme/b released most recently, but both are already shown.
    testing.assertFalse(strings.contains($got, "Latest release="));
    testing.assertEqual(len(strings.split($got, ", ")), 4);
}

func testTheDetailSaysWhyADeckIsThere() {
    def db as flatdb.DB init store.putVersion(emptyDb(), "@acme/a", "routers", ver("1.0.0", 4));
    $db = looked($db, "@acme/a", 1);
    def p as Pick init fromJson(build($db, search.index($db), NOW))[0];
    testing.assertEqual($p.label, "Most resolved");
    testing.assertEqual($p.description, "routers");
    testing.assertEqual($p.detail, "1 resolution in the last 30 days");
}

# Counted from each live deck's newest live version; a deck requiring itself,
# or one that is not here, is not counted.
func testMostDependedOnCountsLiveDecksRequiringIt() {
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "@acme/base", "", ver("1.0.0", 30));
    $db = store.putVersion($db, "@acme/other", "", ver("1.0.0", 30));
    for (def name in ["@acme/x", "@acme/y"]) {
        def v as store.DeckVersion init ver("1.0.0", 30);
        $v.requires = {"@acme/base": "^1.0.0", "@acme/gone": "^1.0.0"};
        $db = store.putVersion($db, $name, "", $v);
    }
    def own as store.DeckVersion init ver("1.1.0", 30);
    $own.requires = {"@acme/other": "^1.0.0", "@acme/base": "^1.0.0"};
    $db = store.putVersion($db, "@acme/other", "", $own);
    def p as Pick init fromJson(build($db, search.index($db), NOW))[0];
    testing.assertEqual($p.label, "Most depended on");
    testing.assertEqual($p.name, "@acme/base");
    testing.assertEqual($p.detail, "required by 3 decks");
    testing.assertFalse(strings.contains(cards($db, NOW), "Most depended on=@acme/other"));
}

# The latest release is the newest by date, not the highest version, and needs
# a release after the first; a deck with one version is "Newest" material.
func testTheLatestReleaseIsByDateAfterAFirstRelease() {
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "@acme/old", "", ver("2.0.0", 40));
    $db = store.putVersion($db, "@acme/old", "", ver("1.4.1", 2));
    $db = store.putVersion($db, "@acme/single", "", ver("0.1.0", 1));
    $db = store.putVersion($db, "@acme/older", "", ver("0.1.0", 90));
    $db = store.putVersion($db, "@acme/older", "", ver("0.2.0", 60));
    def got as string init cards($db, NOW);
    testing.assertContains($got, "Newest=@acme/single");
    testing.assertContains($got, "Latest release=@acme/old");
    def picks as list of Pick init fromJson(build($db, search.index($db), NOW));
    testing.assertEqual($picks[1].detail, "1.4.1 on 2026-08-15");
}

func testAWithdrawnDeckIsNeverFeatured() {
    def db as flatdb.DB init store.putVersion(emptyDb(), "@acme/gone", "", ver("1.0.0", 1));
    $db = store.setYanked($db, "@acme/gone", "1.0.0", true);
    $db = looked($db, "@acme/gone", 99);
    testing.assertEqual(cards($db, NOW), "");
}

# The same all day, for every reader; another deck the next day.
func testTheDeckOfTheDayChangesDaily() {
    def db as flatdb.DB init emptyDb();
    for (def i in 0..9) {
        $db = store.putVersion($db, "@acme/d" + convert.toString($i), "", ver("1.0.0", 0));
    }
    def morning as string init cards($db, NOW - NOW % DAY + 60);
    testing.assertEqual(cards($db, NOW - NOW % DAY + DAY - 60), $morning);
    testing.assertFalse(cards($db, NOW - NOW % DAY + DAY + 60) == $morning);
}

func testAtMostSixCards() {
    testing.assertEqual(MAX_PICKS, 6);
}
