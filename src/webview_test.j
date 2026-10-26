# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for webview.j. Run with:
#
#     jennifer test src/webview_test.j
#
# The overlay reaches webview.j's imports through their aliases and its own
# names bare. Tests assert each page's contract (status, required values,
# escaping of untrusted text), not its markup.

use testing;
use json;

# 2026-08-17T19:20:00Z. Fixed: the counts on a deck page are relative to now.
def const NOW as int init 1786994400;
use strings;
use time;
use convert;

def const COMMIT as string init "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293";
def const CHECKSUM as string init "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"; # lint-disable: L203

func emptyDb() {
    return store.open("/no/such/jvc/webview/missing.json");
}

# gitVer builds a git-kind DeckVersion carrying dependencies and engines.
func gitVer(v as string) {
    return store.DeckVersion{
        version: $v,
        kind: store.KIND_GIT,
        url: "https://github.com/acme/deck-routeros.git",
        ref: "v" + $v,
        commit: COMMIT,
        checksum: "",
        requires: {"@acme/net": "^1.0.0"},
        engines: {"jennifer": ">=0.24.0"},
        capabilities: ["net"],
        description: "",
        publishedAt: "0",
        yanked: false,
        license: "",
        keywords: []
    };
}

# tarVer builds a tar.gz-kind DeckVersion, whose pin is a checksum.
func tarVer(v as string) {
    return store.DeckVersion{
        version: $v,
        kind: store.KIND_TARGZ,
        url: "https://example.test/d.tgz",
        ref: "",
        commit: "",
        checksum: CHECKSUM,
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

func seeded() {
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "@acme/routeros", "MikroTik client", gitVer("0.1.0"));
    $db = store.putVersion($db, "@acme/routeros", "", gitVer("0.2.0"));
    return $db;
}

# --- the landing page -------------------------------------------------------

func testHomeIsAWholeDocument() {
    def page as Page init home(seeded());
    testing.assertEqual($page.status, 200);
    testing.assertTrue(strings.startsWith($page.body, "<!doctype html>"));
    testing.assertContains($page.body, "</html>");
}

func testBrowseListsEveryDeckAndLinksIt() {
    def page as Page init browse(search.index(seeded()), 1);
    testing.assertContains($page.body, "@acme/routeros");
    testing.assertContains($page.body, 'href="/deck/acme/routeros"');
}

func testBrowseShowsTheLatestVersion() {
    def page as Page init browse(search.index(seeded()), 1);
    testing.assertContains($page.body, "0.2.0");
}

func testEmptyRegistrySaysSo() {
    def page as Page init browse(search.index(emptyDb()), 1);
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "No decks published yet");
}

func testHomeLinksJvc() {
    def page as Page init home(seeded());
    testing.assertContains($page.body, '<a href="https://jvc.jennifer-lang.dev/">jvc</a>');
}

func testHomeDoesNotListEveryDeck() {
    # the full listing is /browse, not the landing page
    def page as Page init home(seeded());
    testing.assertEqual($page.status, 200);
    testing.assertFalse(strings.contains($page.body, "@acme/routeros"));
    testing.assertContains($page.body, '/browse');
    testing.assertContains($page.body, '/tags');
}

func testHomeStillCountsTheRegistry() {
    testing.assertContains(home(seeded()).body, "decks");
}

# --- search -----------------------------------------------------------------

func testResultsReportTheMatchCount() {
    def page as Page init results(search.index(seeded()), "routeros", 1);
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "1 result");
    testing.assertContains($page.body, "@acme/routeros");
}

func testResultsEchoTheQueryIntoTheBox() {
    def page as Page init results(search.index(seeded()), "routeros", 1);
    testing.assertContains($page.body, 'value="routeros"');
}

func testNoMatchesStillAnswers200() {
    # an empty result set is not an error
    def page as Page init results(search.index(seeded()), "nothing-here", 1);
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "Nothing matched");
}

func testAnEmptyQueryListsEverything() {
    def page as Page init results(search.index(seeded()), "", 1);
    testing.assertContains($page.body, "All decks");
    testing.assertContains($page.body, "@acme/routeros");
}

# --- a deck page ------------------------------------------------------------

func testDeckPageShowsVersionsNewestFirst() {
    def page as Page init deck(seeded(), "@acme/routeros", NOW);
    testing.assertEqual($page.status, 200);
    def first as int init strings.indexOf($page.body, "0.2.0");
    def second as int init strings.indexOf($page.body, "0.1.0");
    testing.assertTrue($first >= 0);
    testing.assertTrue($first < $second);
}

func testDeckPageShowsTheGitPinAbbreviated() {
    def page as Page init deck(seeded(), "@acme/routeros", NOW);
    testing.assertContains($page.body, strings.substring(COMMIT, 0, 12));
}

func testDeckPageShowsTheChecksumPinForATarball() {
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "@acme/blob", "an artifact", tarVer("1.0.0"));
    def page as Page init deck($db, "@acme/blob", NOW);
    testing.assertContains($page.body, "sha256:");
    testing.assertEqual($page.status, 200);
}

func testDeckPageShowsRequiresEnginesAndCapabilities() {
    def page as Page init deck(seeded(), "@acme/routeros", NOW);
    testing.assertContains($page.body, "@acme/net");
    testing.assertContains($page.body, "jennifer");
    testing.assertContains($page.body, "net");
}

func testDeckPageOffersAnInstallSnippetPinnedToTheLatest() {
    def page as Page init deck(seeded(), "@acme/routeros", NOW);
    testing.assertContains($page.body, "[decks]");
    testing.assertContains($page.body, '"@acme/routeros" = "^0.2.0"');
}

func testDeckPageLinksItsJson() {
    def page as Page init deck(seeded(), "@acme/routeros", NOW);
    testing.assertContains($page.body, "/deck?name=@acme/routeros");
}

func testUnknownDeckIs404() {
    def page as Page init deck(seeded(), "@acme/ghost", NOW);
    testing.assertEqual($page.status, 404);
    testing.assertContains($page.body, "Not found");
}

# --- escaping ---------------------------------------------------------------

func testDescriptionIsEscaped() {
    # a description is untrusted input landing inside markup
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "@acme/x", "<script>alert(1)</script>", gitVer("1.0.0"));
    def page as Page init browse(search.index($db), 1);
    testing.assertFalse(strings.contains($page.body, "<script>alert"));
    testing.assertContains($page.body, "&lt;script&gt;");
}

func testTheSearchQueryIsEscaped() {
    # the query is echoed into a value attribute and into the heading
    def page as Page init results(search.index(seeded()), '"><script>', 1);
    testing.assertFalse(strings.contains($page.body, '"><script>'));
    testing.assertContains($page.body, "&lt;script&gt;");
}

func testTheSearchQueryCannotLeaveTheValueAttribute() {
    # a bare quote closing value="..." was a reflected XSS
    def page as Page init results(search.index(seeded()), '" autofocus onfocus=alert(1) x="', 1);
    testing.assertFalse(strings.contains($page.body, '" autofocus'));
    testing.assertContains($page.body, "&quot; autofocus");
    def single as Page init results(search.index(seeded()), "' onfocus=alert(1) '", 1);
    testing.assertFalse(strings.contains($single.body, "' onfocus"));
}

func testTheTitleIsEscaped() {
    # deck and scope pages title themselves with a name taken from the URL
    def out as string init layout("</title><script>x</script>", "");
    testing.assertFalse(strings.contains($out, "<script>x"));
    testing.assertContains($out, "&lt;/title&gt;");
}

func testTheNotFoundMessageIsEscaped() {
    # the 404 echoes the requested path; this was a reflected XSS
    def page as Page init notFound('No such page: /x"><svg onload=alert(1)>');
    testing.assertFalse(strings.contains($page.body, "<svg onload"));
    testing.assertContains($page.body, "&lt;svg onload=alert(1)&gt;");
}

func testAnUnknownDeckNameIsEscapedOnce() {
    # `notFound` escapes; escaping in the caller too would show `&lt;`
    def page as Page init deck(emptyDb(), "@acme/<b>", NOW);
    testing.assertContains($page.body, "@acme/&lt;b&gt;");
    testing.assertFalse(strings.contains($page.body, "&amp;lt;"));
}

# --- the not-built placeholder ----------------------------------------------

func testSectionMissingExplainsHowToBuild() {
    def page as Page init sectionMissing("Reference", "public/reference", "");
    testing.assertEqual($page.status, 404);
    testing.assertContains($page.body, "Reference not built");
    testing.assertContains($page.body, "grimoire");
    testing.assertContains($page.body, "public/reference/");
    # the default book takes no --config
    testing.assertFalse(strings.contains($page.body, "--config"));
}

func testSectionMissingNamesTheConfigForASecondBook() {
    def page as Page init sectionMissing("Manual", "public/manual", "grimoire-manual.toml");
    testing.assertContains($page.body, "Manual not built");
    testing.assertContains($page.body, "--config grimoire-manual.toml");
}

# --- the README ---------------------------------------------------------------

func withReadme(source as string) {
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "@acme/tool", "a tool", gitVer("1.0.0"));
    return store.putReadme($db, "@acme/tool", $source);
}

func testAReadmeIsRendered() {
    def out as string init readmeSection(
        withReadme("# Title\n\nSome **bold** text.\n"),
        "@acme/tool");
    testing.assertContains($out, "<h1>Title</h1>");
    testing.assertContains($out, "<strong>bold</strong>");
}

func testADeckWithNoReadmeRendersNothing() {
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "@acme/tool", "a tool", gitVer("1.0.0"));
    testing.assertEqual(readmeSection($db, "@acme/tool"), "");
    testing.assertEqual(readmeSection(withReadme("   \n  "), "@acme/tool"), "");
}

func testAReadmeCannotInjectScript() {
    # These tests are the guarantee that markdown.toHtml escapes raw HTML.
    def out as string init readmeSection(
        withReadme("# Hi\n\n<script>alert(1)</script>\n"),
        "@acme/tool");
    testing.assertFalse(strings.contains($out, "<script>"));
    testing.assertContains($out, "&lt;script&gt;");
}

func testAReadmeCannotInjectAnEventHandler() {
    def out as string init readmeSection(
        withReadme("<img src=x onerror=alert(1)>\n"),
        "@acme/tool");
    testing.assertFalse(strings.contains($out, "<img"));
    testing.assertContains($out, "&lt;img");
}

func testAReadmeCannotBreakOutOfTheContainer() {
    def out as string init readmeSection(
        withReadme("</div><script>alert(1)</script><div>\n"),
        "@acme/tool");
    testing.assertFalse(strings.contains($out, "</div><script>"));
}

func testAReadmeLinkCannotRunScript() {
    # the link target is refused, whatever the case of the scheme
    def out as string init readmeSection(
        withReadme("[a](javascript:alert(1)) [b](JaVaScRiPt:alert(1)) [c](data:text/html,x)\n"),
        "@acme/tool");
    testing.assertFalse(strings.contains(strings.lower($out), "javascript:"));
    testing.assertFalse(strings.contains($out, "data:"));
}

func testAReadmeShowsItsTextExactlyOnce() {
    # escaping before rendering escaped twice
    def out as string init readmeSection(
        withReadme("```\nif (a < b && c) x\n```\n\n> quoted\n"),
        "@acme/tool");
    testing.assertContains($out, "a &lt; b &amp;&amp; c");
    testing.assertFalse(strings.contains($out, "&amp;lt;"));
    testing.assertContains($out, "<blockquote>");
}

func testRenderingKeepsMarkdownIntact() {
    def out as string init readmeSection(
        withReadme("# H\n\n- one\n- two\n\n`code`\n\n[link](https://example.com)\n"),
        "@acme/tool");
    testing.assertContains($out, "<li>one</li>");
    testing.assertContains($out, "<code>code</code>");
    testing.assertContains($out, 'href="https://example.com"');
}

func testTheDeckPageShowsTheReadmeAndLicence() {
    def db as flatdb.DB init emptyDb();
    def v as store.DeckVersion init gitVer("1.0.0");
    $v.license = "LGPL-3.0-only";
    $db = store.putVersion($db, "@acme/tool", "a tool", $v);
    $db = store.putReadme($db, "@acme/tool", "# Tool\n\nDoes things.\n");
    def page as Page init deck($db, "@acme/tool", NOW);
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "LGPL-3.0-only");
    testing.assertContains($page.body, "Does things.");
}

func testTheMenuLinksToTheDiscoveryDocument() {
    # The live discovery document, after the reference link.
    def page as Page init home(emptyDb());
    testing.assertContains($page.body, '<a href="/.well-known/jennifer-registry">API</a>');
    def nav as int init strings.indexOf($page.body, "<nav>");
    testing.assertTrue(strings.indexOf($page.body, "/.well-known/") > $nav);
    testing.assertTrue(strings.indexOf($page.body, "/.well-known/") >
        strings.indexOf($page.body, '"/reference/"'));
}

func testTheMenuIsOnEveryPage() {
    # it lives in `layout`, so a deck page and a 404 carry it too
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "@acme/tool", "a tool", gitVer("1.0.0"));
    testing.assertContains(deck($db, "@acme/tool", NOW).body, "/.well-known/jennifer-registry");
    testing.assertContains(notFound("gone").body, "/.well-known/jennifer-registry");
}

# --- the theme switch ---------------------------------------------------------

func testTheSwitchIsOnEveryPage() {
    testing.assertContains(home(emptyDb()).body, 'class="theme"');
    testing.assertContains(notFound("gone").body, 'class="theme"');
    testing.assertContains(results(search.index(emptyDb()), "x", 1).body, 'class="theme"');
}

func testTheScriptRunsBeforeTheBodyPaints() {
    # applied later, a stored choice shows the wrong theme for a frame
    def page as Page init home(emptyDb());
    testing.assertTrue(strings.indexOf($page.body, "jvcTheme") <
        strings.indexOf($page.body, "<body>"));
}

func testAllThreeThemeStatesAreStyled() {
    # an explicit choice must override the system in both directions
    def css as string init home(emptyDb()).body;
    testing.assertContains($css, "@media (prefers-color-scheme: dark)");
    testing.assertContains($css, ':root:not([data-theme="light"])');
    testing.assertContains($css, ':root[data-theme="dark"]');
}

func testTheSwitchHidesItselfWithoutScripting() {
    # without scripting the button is hidden and the page follows the system
    def page as Page init home(emptyDb());
    testing.assertContains($page.body, 'class="no-js"');
    testing.assertContains($page.body, '.no-js .theme');
}

func testTheSwitchIsLabelledForScreenReaders() {
    testing.assertContains(home(emptyDb()).body, "aria-label=");
    testing.assertContains(home(emptyDb()).body, 'aria-hidden="true"');
}

# --- tags --------------------------------------------------------------------

# tagged builds a version carrying keywords.
func tagged(v as string, words as list of string) {
    return store.DeckVersion{
        version: $v,
        kind: store.KIND_GIT,
        url: "https://github.com/acme/deck-x.git",
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
        keywords: $words
    };
}

func taggedDb() {
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "@acme/one", "first", tagged("1.0.0", ["cli", "net"]));
    $db = store.putVersion($db, "@acme/two", "second", tagged("1.0.0", ["cli"]));
    return $db;
}

func testTheTagIndexCountsDecksPerTag() {
    def page as Page init tags(search.index(taggedDb()));
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "/tag/cli");
    testing.assertContains($page.body, "/tag/net");
}

func testAnEmptyRegistryHasNoTags() {
    testing.assertContains(tags(search.index(emptyDb())).body, "No tags in use");
}

func testATagPageListsTheDecksCarryingIt() {
    def page as Page init tag(search.index(taggedDb()), "cli", 1);
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "@acme/one");
    testing.assertContains($page.body, "@acme/two");
}

func testATagPageExcludesDecksWithoutIt() {
    def page as Page init tag(search.index(taggedDb()), "net", 1);
    testing.assertContains($page.body, "@acme/one");
    testing.assertFalse(strings.contains($page.body, "@acme/two"));
}

func testAnUnusedTagIs404() {
    testing.assertEqual(tag(search.index(taggedDb()), "nothing", 1).status, 404);
}

func testARefusedTagIsNotEchoedBack() {
    # a refused tag cannot be stored, so the page must not reflect it
    def refused as string init decodeAllFromKeywords();
    def page as Page init tag(search.index(taggedDb()), $refused, 1);
    testing.assertEqual($page.status, 404);
    testing.assertFalse(strings.contains($page.body, $refused));
}

# decodeAllFromKeywords yields one refused term without spelling it here.
func decodeAllFromKeywords() {
    return keywords.abuse()[0];
}

func testAMalformedTagIs404RatherThanReflected() {
    def page as Page init tag(search.index(taggedDb()), "<script>x</script>", 1);
    testing.assertEqual($page.status, 404);
    testing.assertFalse(strings.contains($page.body, "<script>x"));
}

func testADeckPageLinksItsOwnTags() {
    def page as Page init deck(taggedDb(), "@acme/one", NOW);
    testing.assertContains($page.body, '/tag/cli');
}

func testTagsAreReadFromTheNewestVersionOnly() {
    # a keyword dropped in a later release stops grouping the deck
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "@acme/one", "d", tagged("1.0.0", ["old"]));
    $db = store.putVersion($db, "@acme/one", "", tagged("2.0.0", ["new"]));
    testing.assertEqual(tag(search.index($db), "old", 1).status, 404);
    testing.assertEqual(tag(search.index($db), "new", 1).status, 200);
}

# --- scope, source, counts ---------------------------------------------------

func testADeckPageLinksItsRepository() {
    # the clone URL ends .git; the link must be the browsable form
    def page as Page init deck(seeded(), "@acme/routeros", NOW);
    testing.assertContains($page.body, 'href="https://github.com/acme/deck-routeros"');
    # and reads without the scheme
    testing.assertContains($page.body, ">github.com/acme/deck-routeros<");
}

func testADeckPageShowsTheRepositoryOwnerAndWarnsWhenItChanged() {
    def db as flatdb.DB init seeded();
    def was as store.Provenance init store.Provenance{
        repoId: "7",
        repoOwnerId: "42",
        repoOwner: "acme"
    };
    $db = store.putProvenance($db, "@acme/routeros", "0.1.0", $was);
    $db = store.putProvenance($db, "@acme/routeros", "0.2.0", $was);
    def page as Page init deck($db, "@acme/routeros", NOW);
    testing.assertContains($page.body, "Repository owner");
    testing.assertFalse(strings.contains($page.body, "changed owner"));
    def now as store.Provenance init store.Provenance{
        repoId: "7",
        repoOwnerId: "666",
        repoOwner: "<b>mallory</b>"
    };
    $db = store.putProvenance($db, "@acme/routeros", "0.2.0", $now);
    $page = deck($db, "@acme/routeros", NOW);
    testing.assertContains($page.body, "changed owner since version <code>0.1.0</code>");
    testing.assertContains($page.body, "&lt;b&gt;mallory&lt;/b&gt;");
}

func testARepositoryUrlIsOnlyLinkedWhenItIsHttp() {
    # an escaped javascript: href still runs
    testing.assertEqual(repoLink("javascript:alert(1)"), "");
    testing.assertEqual(repoLink("data:text/html,x"), "");
    testing.assertEqual(repoLink("https://x/y.git"), "https://x/y");
}

func testADeckPageNamesTheScopeItIsPublishedUnder() {
    def page as Page init deck(seeded(), "@acme/routeros", NOW);
    testing.assertContains($page.body, '/scope/acme');
}

func testAScopePageListsTheScopesDecks() {
    def page as Page init scope(taggedDb(), search.index(taggedDb()), "acme", 1);
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "@acme/one");
    testing.assertContains($page.body, "@acme/two");
}

func testAnUnknownScopeIs404() {
    testing.assertEqual(scope(taggedDb(), search.index(taggedDb()), "nobody", 1).status, 404);
}

func testADeckWithNoLookupsShowsNoCounts() {
    # no section rather than six zeroes
    def p as Page init deck(seeded(), "@acme/routeros", NOW);
    testing.assertFalse(strings.contains($p.body, "Resolutions"));
}

func testCountsAppearOnceSomethingHasBeenCounted() {
    def db as flatdb.DB init seeded();
    $db = store.putStats(
        $db,
        "@acme/routeros",
        stats.record(json.map(), stats.hourKey(NOW), 3, NOW));
    def page as Page init deck($db, "@acme/routeros", NOW);
    testing.assertContains($page.body, "Resolutions");
    # and it says what it is not
    testing.assertContains($page.body, "Not downloads");
}

# --- yanking ------------------------------------------------------------------

# yankedDb publishes two versions and yanks the newer one.
func yankedDb() {
    def db as flatdb.DB init seeded();
    return store.setYanked($db, "@acme/routeros", "0.2.0", true);
}

func testAYankedVersionIsLabelledOnTheDeckPage() {
    # the page presented a yanked version as current while the resolver refused it
    def page as Page init deck(yankedDb(), "@acme/routeros", NOW);
    testing.assertContains($page.body, ">yanked<");
}

func testTheInstallSnippetSkipsAYankedVersion() {
    # no resolver will pick a yanked version
    def page as Page init deck(yankedDb(), "@acme/routeros", NOW);
    testing.assertContains($page.body, '"@acme/routeros" = "^0.1.0"');
    testing.assertFalse(strings.contains($page.body, '= "^0.2.0"'));
}

func testTheNoticeNamesTheNewestInstallableVersion() {
    def page as Page init deck(yankedDb(), "@acme/routeros", NOW);
    testing.assertContains($page.body, "newest installable version");
}

func testAYankedVersionIsStillListed() {
    # a lockfile pinning it still installs it, so it must remain findable
    testing.assertContains(deck(yankedDb(), "@acme/routeros", NOW).body, "0.2.0");
}

func testADeckWithEveryVersionYankedSaysSo() {
    def db as flatdb.DB init yankedDb();
    $db = store.setYanked($db, "@acme/routeros", "0.1.0", true);
    def page as Page init deck($db, "@acme/routeros", NOW);
    testing.assertContains($page.body, "Every published version");
    # and offers nothing to depend on
    testing.assertFalse(strings.contains($page.body, "Depend on it"));
}

func testAnEntirelyLiveDeckGetsNoNotice() {
    # the stylesheet names the class on every page, so match the marker
    def page as Page init deck(seeded(), "@acme/routeros", NOW);
    testing.assertFalse(strings.contains($page.body, ">yanked<"));
    testing.assertFalse(strings.contains($page.body, "is-yanked\">"));
}

func testYankingAnOlderVersionDoesNotRaiseABanner() {
    # the table labels it
    def db as flatdb.DB init store.setYanked(seeded(), "@acme/routeros", "0.1.0", true);
    def page as Page init deck($db, "@acme/routeros", NOW);
    testing.assertFalse(strings.contains($page.body, "newest installable"));
    testing.assertFalse(strings.contains($page.body, "Every published version"));
}

func testAListingMarksADeckWithNothingInstallable() {
    def db as flatdb.DB init yankedDb();
    $db = store.setYanked($db, "@acme/routeros", "0.1.0", true);
    testing.assertContains(browse(search.index($db), 1).body, "all versions yanked");
}

func testAListingShowsTheNewestLiveVersionAsLatest() {
    testing.assertContains(browse(search.index(yankedDb()), 1).body, "0.1.0");
}

# manyDecks returns a registry of `n` decks, @acme/d000 upwards.
func manyDecks(n as int) {
    def db as flatdb.DB init emptyDb();
    for (def i in 0..$n) {
        def name as string init "@acme/d" + strings.repeat("0", 3 - len(convert.toString($i))) +
            convert.toString($i);
        $db = store.putVersion($db, $name, "router helper", gitVer("1.0.0"));
    }
    return $db;
}

func testBrowseShowsOnePageAtATime() {
    def index as json.Value init search.index(manyDecks(250));
    def first as string init browse($index, 1).body;
    testing.assertContains($first, "All decks (250)");
    testing.assertContains($first, "@acme/d099");
    testing.assertFalse(strings.contains($first, "@acme/d100"));
    testing.assertContains($first, "Page 1 of 3");
    testing.assertContains($first, 'href="/browse?page=2"');
    testing.assertFalse(strings.contains($first, 'rel="prev"'));
    def last as string init browse($index, 3).body;
    testing.assertContains($last, "@acme/d249");
    testing.assertContains($last, 'href="/browse?page=2"');
    testing.assertFalse(strings.contains($last, 'rel="next"'));
}

func testAPagePastTheEndShowsTheLast() {
    def index as json.Value init search.index(manyDecks(150));
    testing.assertContains(browse($index, 99).body, "Page 2 of 2");
}

func testASmallListingHasNoPager() {
    testing.assertFalse(strings.contains(browse(search.index(seeded()), 1).body, 'class="pager"'));
}

func testSearchPagesKeepTheQueryEscaped() {
    def db as flatdb.DB init manyDecks(150);
    $db = store.putVersion($db, "@acme/zz", '"><b>router</b>', gitVer("1.0.0"));
    def body as string init results(search.index($db), 'router"<x>', 1).body;
    testing.assertFalse(strings.contains($body, '"<x>'));
    def page as Page init results(search.index($db), "router", 2);
    testing.assertContains($page.body, 'href="/search?q=router&amp;page=1"');
}

func testThePageParameterIsForgiving() {
    testing.assertEqual(pageNumber(""), 1);
    testing.assertEqual(pageNumber("3"), 3);
    testing.assertEqual(pageNumber("0"), 1);
    testing.assertEqual(pageNumber("-2"), 1);
    testing.assertEqual(pageNumber("2x"), 1);
    testing.assertEqual(pageNumber("99999999999999999999"), 1);
}

func testThePolicyAdmitsOnlyTheThemeScript() {
    def policy as string init contentSecurityPolicy();
    def digest as bytes init hash.compute(convert.bytesFromString(THEME_SCRIPT, "utf-8"), "sha256");
    testing.assertContains(
        $policy,
        "script-src 'sha256-" + encoding.toText($digest, "base64") + "'");
    testing.assertFalse(strings.contains($policy, "script-src 'unsafe-inline'"));
    testing.assertContains($policy, "frame-ancestors 'none'");
    # an inline handler would need unsafe-inline, so there must be none
    testing.assertFalse(strings.contains(home(emptyDb()).body, "onclick"));
    testing.assertContains(home(emptyDb()).body, "<script>" + THEME_SCRIPT + "</script>");
}

# --- shared maps and page size ----------------------------------------------

func testThePagesBuiltFromSharedMapsMatchTheIndexOnes() {
    def db as flatdb.DB init taggedDb();
    def all as json.Value init search.index($db);
    testing.assertEqual(tagsFrom(search.tagMap($all)).body, tags($all).body);
    testing.assertEqual(tagIn($all, search.tagMap($all), "cli", 1).body, tag($all, "cli", 1).body);
    testing.assertEqual(tagIn($all, search.tagMap($all), "nothing", 1).status, 404);
    def viaMap as Page init scopeIn($db, $all, search.scopeMap($all), "acme", 1);
    testing.assertEqual($viaMap.body, scope($db, $all, "acme", 1).body);
    def found as Page init resultsIn($all, search.lowered($all), "ONE", 1);
    testing.assertEqual($found.body, results($all, "ONE", 1).body);
    testing.assertContains($found.body, "@acme/one");
    testing.assertFalse(strings.contains($found.body, "@acme/two"));
}

func testAHugeTagIndexRendersInLinearTime() {
    # 2,000 tags; the page once grew quadratically (0.9 s here, 112 s at 25,000)
    def groups as json.Value init json.map();
    for (def i in 0..2000) {
        $groups = json.set($groups, "/tag" + convert.toString($i), json.list([$i]));
    }
    def t0 as int init time.unixMillis(time.now());
    def page as Page init tagsFrom($groups);
    def took as int init time.unixMillis(time.now()) - $t0;
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "/tag/tag1999");
    testing.assertContains($page.body, "2000 tags");
    testing.assertTrue($took < 500);
}

func testADeckWithManyVersionsRendersEveryRow() {
    def db as flatdb.DB init emptyDb();
    for (def i in 0..300) {
        $db = store.putVersion($db, "@acme/many", "d", gitVer("1." + convert.toString($i) + ".0"));
    }
    def page as Page init deck($db, "@acme/many", NOW);
    testing.assertContains($page.body, "1.299.0");
    testing.assertContains($page.body, "1.0.0");
}
