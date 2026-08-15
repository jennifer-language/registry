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
        license: ""
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
        license: ""
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

func testHomeListsEveryDeckAndLinksIt() {
    def page as Page init home(seeded());
    testing.assertContains($page.body, "@acme/routeros");
    testing.assertContains($page.body, 'href="/deck/acme/routeros"');
}

func testHomeShowsTheLatestVersion() {
    def page as Page init home(seeded());
    testing.assertContains($page.body, "0.2.0");
}

func testEmptyRegistrySaysSo() {
    def page as Page init home(emptyDb());
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "No decks published yet");
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
    def page as Page init deck(seeded(), "@acme/routeros");
    testing.assertEqual($page.status, 200);
    def first as int init strings.indexOf($page.body, "0.2.0");
    def second as int init strings.indexOf($page.body, "0.1.0");
    testing.assertTrue($first >= 0);
    testing.assertTrue($first < $second);
}

func testDeckPageShowsTheGitPinAbbreviated() {
    def page as Page init deck(seeded(), "@acme/routeros");
    testing.assertContains($page.body, strings.substring(COMMIT, 0, 12));
}

func testDeckPageShowsTheChecksumPinForATarball() {
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "@acme/blob", "an artifact", tarVer("1.0.0"));
    def page as Page init deck($db, "@acme/blob");
    testing.assertContains($page.body, "sha256:");
    testing.assertEqual($page.status, 200);
}

func testDeckPageShowsRequiresEnginesAndCapabilities() {
    def page as Page init deck(seeded(), "@acme/routeros");
    testing.assertContains($page.body, "@acme/net");
    testing.assertContains($page.body, "jennifer");
    testing.assertContains($page.body, "net");
}

func testDeckPageOffersAnInstallSnippetPinnedToTheLatest() {
    def page as Page init deck(seeded(), "@acme/routeros");
    testing.assertContains($page.body, "[decks]");
    testing.assertContains($page.body, '"@acme/routeros" = "^0.2.0"');
}

func testDeckPageLinksItsJson() {
    def page as Page init deck(seeded(), "@acme/routeros");
    testing.assertContains($page.body, "/deck?name=@acme/routeros");
}

func testUnknownDeckIs404() {
    def page as Page init deck(seeded(), "@acme/ghost");
    testing.assertEqual($page.status, 404);
    testing.assertContains($page.body, "Not found");
}

# --- escaping ---------------------------------------------------------------

func testDescriptionIsEscaped() {
    # a description is operator input and lands inside markup, so a tag in it
    # must not survive as one
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "@acme/x", "<script>alert(1)</script>", gitVer("1.0.0"));
    def page as Page init home($db);
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
    def page as Page init deck($db, "@acme/tool");
    testing.assertEqual($page.status, 200);
    testing.assertContains($page.body, "LGPL-3.0-only");
    testing.assertContains($page.body, "Does things.");
}
