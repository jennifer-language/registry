# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.28.0
#
# White-box tests for feedview.j: which versions a feed shows, in which order,
# its parameters, its validators, and that both formats parse back. Run with:
#
#     jennifer test src/feedview_test.j

use testing;
import "feed.j" as feed;

# 2026-11-15T12:00:00Z, the clock every test reads.
def const NOW as int init 1794744000;
def const DAY as int init 86400;
def const BASE as string init "https://registry.example";
def const COMMIT as string init "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293";
def const ATOM_URI as string init "http://www.w3.org/2005/Atom";

# ver builds a git-kind version published `ago` seconds before NOW.
func ver(v as string, ago as int, description as string) {
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
        description: $description,
        publishedAt: convert.toString(NOW - $ago),
        yanked: false,
        license: "",
        keywords: []
    };
}

func emptyDb() {
    return store.open("/no/such/registry/feedview/missing.json");
}

# put publishes one version `ago` seconds before NOW.
func put(db as flatdb.DB, name as string, v as string, ago as int) {
    return store.putVersion($db, $name, "", ver($v, $ago, "about " + $name));
}

# many publishes `n` decks, one version each, deck i `i` days old.
func many(n as int) {
    def db as flatdb.DB init emptyDb();
    for (def i in 0..$n) {
        $db = put($db, "@acme/deck" + letters($i), "1.0.0", $i * DAY + 60);
    }
    return $db;
}

# letters names deck i with letters only (a deck half takes no digit first,
# and letters keep the names in the order of i).
func letters(i as int) {
    def alphabet as string init "abcdefghijklmnopqrstuvwxyz";
    return $alphabet[$i // 26..$i // 26 + 1] + $alphabet[$i % 26..$i % 26 + 1];
}

func answer(db as flatdb.DB, query as string) {
    return prepare($db, collect($db), ATOM, "", $query, NOW, BASE);
}

# titles lists the reply's item titles, joined by ", ".
func titles(r as FeedReply) {
    def out as list of string init [];
    for (def it in $r.items) {
        $out[] = entryTitle($it);
    }
    return strings.join($out, ", ");
}

# --- order -------------------------------------------------------------------

func testItemsAreNewestFirst() {
    def db as flatdb.DB init put(emptyDb(), "@acme/old", "1.0.0", 3 * DAY);
    $db = put($db, "@acme/mid", "1.0.0", 2 * DAY);
    $db = put($db, "@acme/old", "1.1.0", DAY);
    testing.assertEqual(
        titles(answer($db, "")),
        "@acme/old 1.1.0, @acme/mid 1.0.0, @acme/old 1.0.0");
}

func testEqualTimesOrderByNameThenVersion() {
    # one second, five versions: name first, then version by its numbers
    def db as flatdb.DB init put(emptyDb(), "@acme/zeta", "1.0.0", 100);
    $db = put($db, "@acme/alpha", "1.10.0", 100);
    $db = put($db, "@acme/alpha", "1.9.0", 100);
    $db = put($db, "@acme/alpha", "1.2.0", 100);
    $db = put($db, "@acme/beta", "2.0.0", 100);
    testing.assertEqual(
        titles(answer($db, "")),
        "@acme/alpha 1.2.0, @acme/alpha 1.9.0, @acme/alpha 1.10.0, @acme/beta 2.0.0, " +
            "@acme/zeta 1.0.0");
}

func testTheOrderDoesNotDependOnInsertionOrder() {
    def a as flatdb.DB init put(emptyDb(), "@acme/one", "1.0.0", 100);
    $a = put($a, "@acme/two", "1.0.0", 100);
    def b as flatdb.DB init put(emptyDb(), "@acme/two", "1.0.0", 100);
    $b = put($b, "@acme/one", "1.0.0", 100);
    testing.assertEqual(render(answer($a, "")), render(answer($b, "")));
    testing.assertEqual(answer($a, "").etag, answer($b, "").etag);
}

func testAVersionWithoutAPublishTimeIsLeftOut() {
    def db as flatdb.DB init put(emptyDb(), "@acme/good", "1.0.0", 100);
    def bad as store.DeckVersion init ver("1.0.0", 0, "");
    $bad.publishedAt = "";
    $db = store.putVersion($db, "@acme/undated", "", $bad);
    testing.assertEqual(titles(answer($db, "")), "@acme/good 1.0.0");
}

# --- the time and count cuts -------------------------------------------------

func testTheDefaultIsThirtyDaysAtMostFifty() {
    # 60 decks a day apart: 30 inside the window
    def r as FeedReply init answer(many(60), "");
    testing.assertEqual(len($r.items), 30);
    testing.assertEqual($r.items[29].publishedAt, NOW - 29 * DAY - 60);
}

func testTheCountCutsBeforeTheWindow() {
    def r as FeedReply init answer(many(60), "limit=5");
    testing.assertEqual(len($r.items), 5);
    testing.assertEqual($r.items[0].name, "@acme/deckaa");
}

func testTheDaysParameterMovesTheWindow() {
    testing.assertEqual(len(answer(many(60), "days=45").items), 45);
    testing.assertEqual(len(answer(many(60), "days=45&limit=40").items), 40);
}

func testAQuietRegistryStillShowsTenItems() {
    # everything is older than the window: the newest ten are shown anyway
    def db as flatdb.DB init emptyDb();
    for (def i in 0..15) {
        $db = put($db, "@acme/deck" + letters($i), "1.0.0", (100 + $i) * DAY);
    }
    def r as FeedReply init answer($db, "");
    testing.assertEqual(len($r.items), 10);
    testing.assertEqual($r.items[0].name, "@acme/deckaa");
    testing.assertEqual($r.items[9].name, "@acme/deckaj");
}

func testTheMinimumTopsUpAPartlyQuietWindow() {
    # three inside the window, the rest old: ten in all
    testing.assertEqual(len(answer(many(20), "days=3").items), 10);
}

func testTheMinimumNeverExceedsTheLimit() {
    def db as flatdb.DB init emptyDb();
    for (def i in 0..15) {
        $db = put($db, "@acme/deck" + letters($i), "1.0.0", (100 + $i) * DAY);
    }
    testing.assertEqual(len(answer($db, "limit=4").items), 4);
}

func testFewerThanTenVersionsShowsThemAll() {
    def r as FeedReply init answer(many(3), "days=1");
    testing.assertEqual(len($r.items), 3);
}

func testAnEmptyRegistryHasAnEmptyFeed() {
    def r as FeedReply init answer(emptyDb(), "");
    testing.assertEqual($r.status, 200);
    testing.assertEqual(len($r.items), 0);
    testing.assertEqual($r.lastModified, 0);
    # still a valid document with its required elements
    def root as xml.Value init xml.decode(render($r));
    testing.assertTrue(xml.has($root, "id", {"": ATOM_URI}));
    testing.assertTrue(xml.has($root, "updated", {"": ATOM_URI}));
}

# --- yanked, new and updated ---------------------------------------------------

func testYankedVersionsAreLeftOut() {
    def db as flatdb.DB init put(emptyDb(), "@acme/tool", "1.0.0", 3 * DAY);
    $db = put($db, "@acme/tool", "1.1.0", 2 * DAY);
    $db = put($db, "@acme/tool", "1.2.0", DAY);
    $db = store.setYanked($db, "@acme/tool", "1.1.0", true);
    testing.assertEqual(titles(answer($db, "")), "@acme/tool 1.2.0, @acme/tool 1.0.0");
}

func testTheFirstVersionIsNewAndLaterOnesUpdated() {
    def db as flatdb.DB init put(emptyDb(), "@acme/tool", "1.0.0", 2 * DAY);
    $db = put($db, "@acme/tool", "1.1.0", DAY);
    def r as FeedReply init answer($db, "");
    testing.assertEqual(kindOf($r.items[0]), "updated");
    testing.assertEqual(kindOf($r.items[1]), "new");
    def root as xml.Value init xml.decode(render($r));
    def entries as list of xml.Value init xml.findAll($root, "entry", {"": ATOM_URI});
    testing.assertEqual(
        xml.attr(xml.get($entries[0], "category", {"": ATOM_URI}), "term"),
        "updated");
    testing.assertEqual(xml.attr(xml.get($entries[1], "category", {"": ATOM_URI}), "term"), "new");
}

func testYankingTheFirstVersionDoesNotMakeTheNextNew() {
    def db as flatdb.DB init put(emptyDb(), "@acme/tool", "1.0.0", 2 * DAY);
    $db = put($db, "@acme/tool", "1.1.0", DAY);
    $db = store.setYanked($db, "@acme/tool", "1.0.0", true);
    def r as FeedReply init answer($db, "");
    testing.assertEqual(len($r.items), 1);
    testing.assertEqual(kindOf($r.items[0]), "updated");
}

func testTheFirstVersionIsByTimeNotByNumber() {
    # a backport published later is an update, not the deck's first version
    def db as flatdb.DB init put(emptyDb(), "@acme/tool", "2.0.0", 2 * DAY);
    $db = put($db, "@acme/tool", "1.9.1", DAY);
    def r as FeedReply init answer($db, "");
    testing.assertEqual(titles($r), "@acme/tool 1.9.1, @acme/tool 2.0.0");
    testing.assertEqual(kindOf($r.items[0]), "updated");
    testing.assertEqual(kindOf($r.items[1]), "new");
}

# --- parameters -----------------------------------------------------------------

func testTheDefaultsAreFiftyAndThirty() {
    def p as Params init params("");
    testing.assertEqual($p.status, 200);
    testing.assertEqual($p.limit, 50);
    testing.assertEqual($p.days, 30);
    testing.assertEqual($p.query, "");
}

func testValidParametersAreRead() {
    def p as Params init params("limit=100&days=365");
    testing.assertEqual($p.status, 200);
    testing.assertEqual($p.limit, 100);
    testing.assertEqual($p.days, 365);
    testing.assertEqual($p.query, "?limit=100&days=365");
    testing.assertEqual(params("days=1&limit=1").query, "?limit=1&days=1");
}

func testOtherParametersAreIgnored() {
    def p as Params init params("utm_source=reader&limit=7&x");
    testing.assertEqual($p.status, 200);
    testing.assertEqual($p.limit, 7);
}

func testMalformedParametersAre400() {
    def accepted as list of string init [];
    for (def q in [
        "limit=0",
        "limit=101",
        "limit=",
        "limit",
        "limit=-1",
        "limit=+5",
        "limit=05",
        "limit=5.0",
        "limit=%35",
        "limit=1e2",
        "limit= 5",
        "limit=five",
        "limit=1000",
        "days=0",
        "days=366",
        "days=",
        "days=abc",
        "days=030",
        "limit=5&limit=6",
        "days=1&days=1"
    ]) {
        def p as Params init params($q);
        if (not ($p.status == 400 and len($p.message) > 0)) {
            $accepted[] = $q;
        }
    }
    testing.assertEqual(strings.join($accepted, " "), "");
}

func testARefusedQueryIsA400Reply() {
    def r as FeedReply init answer(many(3), "limit=0");
    testing.assertEqual($r.status, 400);
    testing.assertEqual($r.message, "limit must be a whole number from 1 to 100");
}

func testTheScopeFileIsTakenApart() {
    def f as ScopeFile init scopeFile("@Jennifer.atom");
    testing.assertTrue($f.ok);
    testing.assertEqual($f.scope, "jennifer");
    testing.assertEqual($f.format, ATOM);
    testing.assertEqual(scopeFile("@my-org.rss").format, RSS);
    def accepted as list of string init [];
    for (def bad in [
        "jennifer.atom",
        "@.atom",
        "@jennifer",
        "@jennifer.xml",
        "@a--b.atom",
        "@jennifer.atom.rss.json",
        "@-x.rss",
        "@"
    ]) {
        if (scopeFile($bad).ok) {
            $accepted[] = $bad;
        }
    }
    testing.assertEqual(strings.join($accepted, " "), "");
}

# --- per scope ---------------------------------------------------------------

func testAScopeFeedShowsOnlyThatScope() {
    def db as flatdb.DB init put(emptyDb(), "@acme/tool", "1.0.0", 2 * DAY);
    $db = put($db, "@other/thing", "1.0.0", DAY);
    def r as FeedReply init prepare($db, collect($db), RSS, "acme", "", NOW, BASE);
    testing.assertEqual($r.status, 200);
    testing.assertEqual(titles($r), "@acme/tool 1.0.0");
    testing.assertEqual($r.contentType, "application/rss+xml; charset=utf-8");
}

func testAnUnknownScopeIs404AndAnEmptyOneIsNot() {
    def db as flatdb.DB init put(emptyDb(), "@acme/tool", "1.0.0", DAY);
    testing.assertEqual(prepare($db, collect($db), ATOM, "nobody", "", NOW, BASE).status, 404);
    $db = store.registerNamespace(
        $db,
        store.Namespace{
            scope: "quiet",
            provider: "github",
            subject: "1",
            login: "quiet",
            registeredAt: "1700000000",
            kind: "user",
            coOwners: []
        });
    def r as FeedReply init prepare($db, collect($db), ATOM, "quiet", "", NOW, BASE);
    testing.assertEqual($r.status, 200);
    testing.assertEqual(len($r.items), 0);
}

# --- validators ----------------------------------------------------------------

func testTheEtagIsStableAndFollowsTheItems() {
    def db as flatdb.DB init put(emptyDb(), "@acme/tool", "1.0.0", DAY);
    def first as string init answer($db, "").etag;
    testing.assertEqual(len($first), 32);
    testing.assertEqual(answer($db, "").etag, $first);
    # the same items in the other format, or a new version, is another tag
    testing.assertNotEqual(prepare($db, collect($db), RSS, "", "", NOW, BASE).etag, $first);
    testing.assertNotEqual(answer(put($db, "@acme/tool", "1.1.0", 60), "").etag, $first);
    # and so is a yank
    def yanked as flatdb.DB init put($db, "@acme/tool", "1.1.0", 60);
    testing.assertNotEqual(
        answer(store.setYanked($yanked, "@acme/tool", "1.1.0", true), "").etag,
        answer($yanked, "").etag);
}

func testLastModifiedIsTheNewestItem() {
    def db as flatdb.DB init put(emptyDb(), "@acme/tool", "1.0.0", 2 * DAY);
    $db = put($db, "@acme/tool", "1.1.0", 3600);
    def r as FeedReply init answer($db, "");
    testing.assertEqual($r.lastModified, NOW - 3600);
    testing.assertEqual(httpDate($r.lastModified), "Sun, 15 Nov 2026 11:00:00 GMT");
}

func testAnItemLeavingTheWindowMovesLastModified() {
    # twelve decks a day apart, 20 to 31 days old, a 15-day window and a
    # minimum of ten: the eleventh (30 days old) was in the feed until it turned
    # 15 days old, after the newest was published
    def db as flatdb.DB init emptyDb();
    for (def i in 0..12) {
        $db = put($db, "@acme/deck" + letters($i), "1.0.0", (20 + $i) * DAY);
    }
    def r as FeedReply init answer($db, "days=15");
    testing.assertEqual(len($r.items), 10);
    testing.assertEqual($r.lastModified, NOW - 15 * DAY);
    # a newer item than that moment is the date again
    testing.assertEqual(answer(many(12), "days=3").lastModified, NOW - 60);
}

func testIfModifiedSinceIsHonoured() {
    def at as int init NOW - 3600;
    testing.assertTrue(unchangedSince(httpDate($at), $at));
    testing.assertTrue(unchangedSince(httpDate($at + 10), $at));
    testing.assertFalse(unchangedSince(httpDate($at - 1), $at));
    testing.assertFalse(unchangedSince("", $at));
    testing.assertFalse(unchangedSince("yesterday", $at));
    testing.assertFalse(unchangedSince("2026-11-15T11:00:00Z", $at));
    # a feed with nothing in it has no date to compare
    testing.assertFalse(unchangedSince(httpDate($at), 0));
}

# --- the documents -------------------------------------------------------------

func hostileDb() {
    def evil as string init '<script>alert("x")</script> & ]]> &amp; ' + "\u0001\u0007tail";
    return store.putVersion(emptyDb(), "@acme/tool", "", ver("1.0.0", DAY, $evil));
}

func testAHostileDescriptionIsEscaped() {
    def db as flatdb.DB init hostileDb();
    for (def format in [ATOM, RSS]) {
        def text as string init render(prepare($db, collect($db), $format, "", "", NOW, BASE));
        testing.assertFalse(strings.contains($text, "<script>"));
        testing.assertTrue(strings.contains($text, "&lt;script&gt;"));
        testing.assertTrue(strings.contains($text, "&amp;amp;"));
        def back as feed.Feed init feed.parse($text);
        testing.assertEqual(
            $back.entries[0].summary,
            '<script>alert("x")</script> & ]]> &amp; tail');
    }
}

func testTheAtomDocumentHasEveryRequiredElement() {
    def db as flatdb.DB init put(emptyDb(), "@acme/tool", "1.0.0", 2 * DAY);
    $db = put($db, "@acme/tool", "1.1.0", DAY);
    def text as string init render(answer($db, "limit=20"));
    testing.assertTrue(strings.startsWith($text, '<?xml version="1.0" encoding="utf-8"?>'));
    def ns as map of string to string init {"": ATOM_URI};
    def root as xml.Value init xml.decode($text);
    testing.assertEqual(xml.localName($root), "feed");
    testing.assertEqual(xml.namespace($root), ATOM_URI);
    testing.assertEqual(xml.text(xml.get($root, "id", $ns)), BASE + "/feed.atom");
    testing.assertEqual(
        xml.text(xml.get($root, "title", $ns)),
        "Jennifer registry: new and updated decks");
    testing.assertEqual(xml.text(xml.get($root, "updated", $ns)), "2026-11-14T12:00:00Z");
    testing.assertTrue(xml.has($root, "author/name", $ns));
    def self as string init "";
    for (def l in xml.findAll($root, "link", $ns)) {
        if (xml.attr($l, "rel") == "self") {
            $self = xml.attr($l, "href");
        }
    }
    testing.assertEqual($self, BASE + "/feed.atom?limit=20");
    def e as xml.Value init xml.findAll($root, "entry", $ns)[0];
    testing.assertEqual(xml.text(xml.get($e, "title", $ns)), "@acme/tool 1.1.0");
    testing.assertEqual(
        xml.text(xml.get($e, "id", $ns)),
        "tag:registry.example,2026-11-14:@acme/tool/1.1.0");
    testing.assertEqual(xml.text(xml.get($e, "updated", $ns)), "2026-11-14T12:00:00Z");
    testing.assertEqual(xml.attr(xml.get($e, "link", $ns), "href"), BASE + "/deck/acme/tool");
    testing.assertEqual(xml.text(xml.get($e, "author/name", $ns)), "@acme");
    testing.assertEqual(xml.text(xml.get($e, "summary", $ns)), "about @acme/tool");
    # the module that reads feeds agrees
    def back as feed.Feed init feed.parse($text);
    testing.assertEqual(len($back.entries), 2);
    testing.assertEqual($back.entries[0].link, BASE + "/deck/acme/tool");
    testing.assertEqual(time.unix($back.entries[1].updated), NOW - 2 * DAY);
}

func testTheRssDocumentHasEveryRequiredElement() {
    def db as flatdb.DB init put(emptyDb(), "@acme/tool", "1.0.0", 2 * DAY);
    def text as string init render(prepare($db, collect($db), RSS, "acme", "", NOW, BASE));
    def root as xml.Value init xml.decode($text);
    testing.assertEqual(xml.tag($root), "rss");
    testing.assertEqual(xml.attr($root, "version"), "2.0");
    def ch as xml.Value init xml.get($root, "channel");
    for (def required in ["title", "link", "description"]) {
        testing.assertTrue(xml.has($ch, $required));
    }
    testing.assertEqual(xml.text(xml.get($ch, "link")), BASE + "/scope/acme");
    def self as xml.Value init xml.get($ch, "a:link", {"a": ATOM_URI});
    testing.assertEqual(xml.attr($self, "href"), BASE + "/feed/@acme.rss");
    testing.assertEqual(xml.text(xml.get($ch, "lastBuildDate")), "Fri, 13 Nov 2026 12:00:00 +0000");
    def item as xml.Value init xml.get($ch, "item");
    testing.assertEqual(xml.text(xml.get($item, "title")), "@acme/tool 1.0.0");
    testing.assertEqual(xml.text(xml.get($item, "pubDate")), "Fri, 13 Nov 2026 12:00:00 +0000");
    testing.assertEqual(xml.attr(xml.get($item, "guid"), "isPermaLink"), "false");
    testing.assertEqual(xml.text(xml.get($item, "category")), "new");
    testing.assertEqual(
        xml.text(xml.get($item, "dc:creator", {"dc": "http://purl.org/dc/elements/1.1/"})),
        "@acme");
    def back as feed.Feed init feed.parse($text);
    testing.assertEqual($back.entries[0].id, "tag:registry.example,2026-11-13:@acme/tool/1.0.0");
    testing.assertEqual($back.entries[0].author, "@acme");
    testing.assertEqual(time.unix($back.entries[0].published), NOW - 2 * DAY);
}

func testABareNameLinksItsRepository() {
    def db as flatdb.DB init put(emptyDb(), "tool", "1.0.0", DAY);
    def it as Item init answer($db, "").items[0];
    testing.assertEqual(entryLink(BASE, $it), "https://example.test/d");
    $it.url = "git@example.test:d.git";
    testing.assertEqual(entryLink(BASE, $it), BASE + "/deck?name=tool");
}

func testTheBaseUrlLosesItsTrailingSlash() {
    def db as flatdb.DB init put(emptyDb(), "@acme/tool", "1.0.0", DAY);
    def r as FeedReply init prepare(
        $db,
        collect($db),
        ATOM,
        "",
        "",
        NOW,
        "https://registry.example:8443/");
    testing.assertEqual($r.base, "https://registry.example:8443");
    testing.assertEqual(
        entryId($r.base, $r.items[0]),
        "tag:registry.example,2026-11-14:@acme/tool/1.0.0");
}
