# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for webview.j. Run with:
#
#     jennifer test src/webview_test.j
#
# webview.j imports store / search / deckname / html / flatdb, so the overlay
# reaches them through those aliases and Page / home / results / deck by bare
# name. These assert the contract of each page - status, the values that must
# appear, and that untrusted text is escaped - not its exact markup, so the
# stylesheet and layout can change without rewriting the suite.

use testing;
use json;

# 2026-08-17T19:20:00Z. Fixed: the counts on a deck page are relative to now.
def const NOW as int init 1786994400;
use strings;

def const COMMIT as string init "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293";
def const CHECKSUM as string init
    "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

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
    def page as Page init browse(seeded());
    testing.assertContains($page.body, "@acme/routeros");
    testing.assertContains($page.body, 'href="/deck/acme/routeros"');
}

func testBrowseShowsTheLatestVersion() {
    def page as Page init browse(seeded());
    testing.assertContains($page.body, "0.2.0");
}

func testEmptyRegistrySaysSo() {
    def page as Page init browse(emptyDb());
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "No decks published yet");
}

func testHomeDoesNotListEveryDeck() {
    # the front door offers search and two ways in; a full listing is /browse.
    # A registry that succeeds would otherwise ship its largest page as its
    # first impression.
    def page as Page init home(seeded());
    testing.assertEqual($page.status, 200);
    testing.assertFalse(strings.contains($page.body, "@acme/routeros"));
    testing.assertContains($page.body, '/browse');
    testing.assertContains($page.body, '/tags');
}

func testHomeStillCountsTheRegistry() {
    # "how big is this" is a fair question and one number answers it
    testing.assertContains(home(seeded()).body, "decks");
}

# --- search -----------------------------------------------------------------

func testResultsReportTheMatchCount() {
    def page as Page init results(seeded(), "routeros");
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "1 result");
    testing.assertContains($page.body, "@acme/routeros");
}

func testResultsEchoTheQueryIntoTheBox() {
    def page as Page init results(seeded(), "routeros");
    testing.assertContains($page.body, 'value="routeros"');
}

func testNoMatchesStillAnswers200() {
    # an empty result set is not an error: the page explains, and keeps the box
    def page as Page init results(seeded(), "nothing-here");
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "Nothing matched");
}

func testAnEmptyQueryListsEverything() {
    def page as Page init results(seeded(), "");
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
    # a description is operator input and lands inside markup, so a tag in it
    # must not survive as one
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "@acme/x", "<script>alert(1)</script>", gitVer("1.0.0"));
    def page as Page init browse($db);
    testing.assertFalse(strings.contains($page.body, "<script>alert"));
    testing.assertContains($page.body, "&lt;script&gt;");
}

func testTheSearchQueryIsEscaped() {
    # the query is echoed into a value attribute and into the heading
    def page as Page init results(seeded(), '"><script>');
    testing.assertFalse(strings.contains($page.body, '"><script>'));
    testing.assertContains($page.body, "&lt;script&gt;");
}

# --- the not-built placeholder ----------------------------------------------

func testSectionMissingExplainsHowToBuild() {
    def page as Page init sectionMissing("Reference", "public/reference", "");
    testing.assertEqual($page.status, 404);
    testing.assertContains($page.body, "Reference not built");
    testing.assertContains($page.body, "grimoire");
    testing.assertContains($page.body, "public/reference/");
    # the default book takes no --config, so the command must not carry one
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
    def out as string init readmeSection(withReadme("# Title\n\nSome **bold** text.\n"),
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
    # This is the one that matters. markdown.toHtml passes raw HTML through by
    # design, and a README is untrusted publisher input, so rendering it verbatim
    # would run a publisher's script on this origin for every visitor.
    def out as string init readmeSection(
        withReadme("# Hi\n\n<script>alert(1)</script>\n"), "@acme/tool");
    testing.assertFalse(strings.contains($out, "<script>"));
    testing.assertContains($out, "&lt;script&gt;");
}

func testAReadmeCannotInjectAnEventHandler() {
    def out as string init readmeSection(
        withReadme("<img src=x onerror=alert(1)>\n"), "@acme/tool");
    testing.assertFalse(strings.contains($out, "<img"));
    testing.assertContains($out, "&lt;img");
}

func testAReadmeCannotBreakOutOfTheContainer() {
    def out as string init readmeSection(
        withReadme("</div><script>alert(1)</script><div>\n"), "@acme/tool");
    testing.assertFalse(strings.contains($out, "</div><script>"));
}

func testEscapingDoesNotBreakMarkdown() {
    # the safety measure must not cost the feature: none of markdown's syntax
    # characters are HTML special characters, so every construct survives
    def out as string init readmeSection(withReadme(
        "# H\n\n- one\n- two\n\n`code`\n\n[link](https://example.com)\n"), "@acme/tool");
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
    # Not the rendered API prose: this points at the live document a client
    # actually reads, which is the one URL a client may hard-code and the only
    # thing on the site that answers "what does this registry serve, right now".
    # Last entry, so the order stays Decks / Manual / Reference / API.
    def page as Page init home(emptyDb());
    testing.assertContains($page.body,
        '<a href="/.well-known/jennifer-registry">API</a>');
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
    testing.assertContains(results(emptyDb(), "x").body, 'class="theme"');
}

func testTheScriptRunsBeforeTheBodyPaints() {
    # applying a stored choice after the body renders shows the wrong theme for
    # a frame, which is the flash every themed page gets wrong
    def page as Page init home(emptyDb());
    testing.assertTrue(strings.indexOf($page.body, "jvcTheme") <
        strings.indexOf($page.body, "<body>"));
}

func testAllThreeThemeStatesAreStyled() {
    # unstamped follows the system; an explicit choice has to beat the system in
    # both directions, or the switch works one way only
    def css as string init home(emptyDb()).body;
    testing.assertContains($css, "@media (prefers-color-scheme: dark)");
    testing.assertContains($css, ':root:not([data-theme="light"])');
    testing.assertContains($css, ':root[data-theme="dark"]');
}

func testTheSwitchHidesItselfWithoutScripting() {
    # a button that cannot work is worse than no button; the page still follows
    # the system setting, exactly as it did before the switch existed
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
        version: $v, kind: store.KIND_GIT,
        url: "https://github.com/acme/deck-x.git", ref: "v" + $v,
        commit: COMMIT, checksum: "", requires: {}, engines: {},
        capabilities: [], description: "", publishedAt: "0", yanked: false,
        license: "", keywords: $words
    };
}

func taggedDb() {
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "@acme/one", "first", tagged("1.0.0", ["cli", "net"]));
    $db = store.putVersion($db, "@acme/two", "second", tagged("1.0.0", ["cli"]));
    return $db;
}

func testTheTagIndexCountsDecksPerTag() {
    def page as Page init tags(taggedDb());
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "/tag/cli");
    testing.assertContains($page.body, "/tag/net");
}

func testAnEmptyRegistryHasNoTags() {
    testing.assertContains(tags(emptyDb()).body, "No tags in use");
}

func testATagPageListsTheDecksCarryingIt() {
    def page as Page init tag(taggedDb(), "cli");
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "@acme/one");
    testing.assertContains($page.body, "@acme/two");
}

func testATagPageExcludesDecksWithoutIt() {
    def page as Page init tag(taggedDb(), "net");
    testing.assertContains($page.body, "@acme/one");
    testing.assertFalse(strings.contains($page.body, "@acme/two"));
}

func testAnUnusedTagIs404() {
    testing.assertEqual(tag(taggedDb(), "nothing").status, 404);
}

func testARefusedTagIsNotEchoedBack() {
    # a refused tag can never have been stored, so the page must not render the
    # string at all rather than reflecting whatever was in the URL
    def refused as string init decodeAllFromKeywords();
    def page as Page init tag(taggedDb(), $refused);
    testing.assertEqual($page.status, 404);
    testing.assertFalse(strings.contains($page.body, $refused));
}

# decodeAllFromKeywords yields one refused term without spelling it here.
func decodeAllFromKeywords() {
    return keywords.abuse()[0];
}

func testAMalformedTagIs404RatherThanReflected() {
    def page as Page init tag(taggedDb(), "<script>x</script>");
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
    testing.assertEqual(tag($db, "old").status, 404);
    testing.assertEqual(tag($db, "new").status, 200);
}

# --- scope, source, counts ---------------------------------------------------

func testADeckPageLinksItsRepository() {
    # the clone URL ends .git; the link must be the browsable form
    def page as Page init deck(seeded(), "@acme/routeros", NOW);
    testing.assertContains($page.body,
        'href="https://github.com/acme/deck-routeros"');
    # and reads without the scheme
    testing.assertContains($page.body, ">github.com/acme/deck-routeros<");
}

func testARepositoryUrlIsOnlyLinkedWhenItIsHttp() {
    # publisher input reaching an href: escaping alone would not stop this one
    testing.assertEqual(repoLink("javascript:alert(1)"), "");
    testing.assertEqual(repoLink("data:text/html,x"), "");
    testing.assertEqual(repoLink("https://x/y.git"), "https://x/y");
}

func testADeckPageNamesTheScopeItIsPublishedUnder() {
    def page as Page init deck(seeded(), "@acme/routeros", NOW);
    testing.assertContains($page.body, '/scope/acme');
}

func testAScopePageListsTheScopesDecks() {
    def page as Page init scope(taggedDb(), "acme");
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "@acme/one");
    testing.assertContains($page.body, "@acme/two");
}

func testAnUnknownScopeIs404() {
    testing.assertEqual(scope(taggedDb(), "nobody").status, 404);
}

func testADeckWithNoLookupsShowsNoCounts() {
    # six zeroes on a day-old deck reads as failure; absence reads as new
    testing.assertFalse(strings.contains(
        deck(seeded(), "@acme/routeros", NOW).body, "Resolutions"));
}

func testCountsAppearOnceSomethingHasBeenCounted() {
    def db as flatdb.DB init seeded();
    $db = store.putStats($db, "@acme/routeros",
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
    # the bug this covers: the page listed a yanked version indistinguishably
    # from a live one, so the site said "current release" while the resolver
    # refused to choose it
    def page as Page init deck(yankedDb(), "@acme/routeros", NOW);
    testing.assertContains($page.body, ">yanked<");
}

func testTheInstallSnippetSkipsAYankedVersion() {
    # recommending a version no resolver will pick is the costly half of the bug
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
    # the stylesheet names the class on every page, so the marker is what to
    # look for, not the word
    def page as Page init deck(seeded(), "@acme/routeros", NOW);
    testing.assertFalse(strings.contains($page.body, ">yanked<"));
    testing.assertFalse(strings.contains($page.body, "is-yanked\">"));
}

func testYankingAnOlderVersionDoesNotRaiseABanner() {
    # the table says so row by row; a banner would be noise
    def db as flatdb.DB init store.setYanked(seeded(), "@acme/routeros", "0.1.0", true);
    def page as Page init deck($db, "@acme/routeros", NOW);
    testing.assertFalse(strings.contains($page.body, "newest installable"));
    testing.assertFalse(strings.contains($page.body, "Every published version"));
}

func testAListingMarksADeckWithNothingInstallable() {
    def db as flatdb.DB init yankedDb();
    $db = store.setYanked($db, "@acme/routeros", "0.1.0", true);
    testing.assertContains(browse($db).body, "all versions yanked");
}

func testAListingShowsTheNewestLiveVersionAsLatest() {
    testing.assertContains(browse(yankedDb()).body, "0.1.0");
}
