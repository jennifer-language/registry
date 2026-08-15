# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The website's HTML responses, as pure data. The same shape as `apiview`, one
 * layer up: each function maps a registry plus request inputs to a `Page` (an
 * HTTP status and an HTML string), with no dependency on the web engine, so
 * every page is unit-testable without booting a server.
 *
 * The web surface is **read-only** by design: a landing page, a search, and a
 * deck page. There is no form that writes anything, no session, and no account
 * UI - publishing is a CLI action. Keep it that way.
 *
 * Every interpolated value goes through `html.escape`, because deck names and
 * descriptions are operator input and end up inside markup.
 * @module webview
 * @example
 * import "./webview.j" as webview;
 * def page as webview.Page init webview.deck($db, "@acme/routeros");
 * # web.html($ctx, page.status, page.body);
 */

use strings;
use convert;
import "flatdb.j" as flatdb;
import "html.j" as html;
import "markdown.j" as markdown;
import "./store.j" as store;
import "./search.j" as search;
import "./deckname.j" as deckname;

/**
 * An HTML response as pure data: a status code and a rendered body.
 * @field status {int} the HTTP status code
 * @field body {string} the rendered HTML document
 */
export def struct Page {
    status as int,
    body as string
};

# The site's stylesheet. Inline, so a page is one request and nothing is fetched
# from anywhere: no CDN, no font download, no build step. Colours are custom
# properties redefined under prefers-color-scheme, so dark mode is the same
# markup.
def const STYLE as string init '
:root {
  --bg: #fdfdfc; --fg: #1a1a19; --muted: #6b6b66; --line: #e4e4e0;
  --card: #ffffff; --accent: #7c5cff; --code-bg: #f4f4f1;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #16161a; --fg: #e8e8e6; --muted: #9a9a95; --line: #2a2a30;
    --card: #1d1d22; --accent: #a893ff; --code-bg: #232329;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--fg);
  font: 16px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  -webkit-font-smoothing: antialiased;
}
.wrap { max-width: 54rem; margin: 0 auto; padding: 0 1.25rem 5rem; }
header { border-bottom: 1px solid var(--line); margin-bottom: 2.5rem; }
header .wrap {
  display: flex; align-items: baseline; gap: 1.25rem;
  padding-top: 1.25rem; padding-bottom: 1.25rem;
}
.brand {
  font-weight: 650; letter-spacing: -0.02em; text-decoration: none;
  color: var(--fg); font-size: 1.05rem;
}
.brand span { color: var(--accent); }
nav { margin-left: auto; display: flex; gap: 1.25rem; }
nav a, .muted a { color: var(--muted); text-decoration: none; font-size: 0.9rem; }
nav a:hover, .muted a:hover { color: var(--accent); }
h1 { font-size: 1.9rem; letter-spacing: -0.03em; margin: 0 0 0.35rem; }
h2 { font-size: 1.05rem; letter-spacing: -0.01em; margin: 2.5rem 0 0.9rem; }
.lede { color: var(--muted); margin: 0 0 2rem; }
.readme { border: 1px solid var(--line); border-radius: 6px; padding: 0 1.25rem;
  margin-top: 0.5rem; overflow-x: auto; }
.readme h1, .readme h2, .readme h3 { font-size: 1.05rem; margin: 1.25rem 0 0.5rem; }
.readme img { max-width: 100%; }
.readme pre { overflow-x: auto; }
form.search { display: flex; gap: 0.6rem; margin: 0 0 2rem; }
input[type=search] {
  flex: 1; padding: 0.7rem 0.9rem; border: 1px solid var(--line);
  border-radius: 9px; background: var(--card); color: var(--fg);
  font: inherit; font-size: 0.95rem;
}
input[type=search]:focus {
  outline: none; border-color: var(--accent);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 18%, transparent);
}
button {
  padding: 0.7rem 1.1rem; border: 0; border-radius: 9px;
  background: var(--accent); color: #fff; font: inherit; font-weight: 550;
  cursor: pointer;
}
button:hover { filter: brightness(1.08); }
ul.decks { list-style: none; padding: 0; margin: 0; display: grid; gap: 0.6rem; }
ul.decks li {
  border: 1px solid var(--line); border-radius: 11px; background: var(--card);
  padding: 0.9rem 1.1rem; transition: border-color 0.15s;
}
ul.decks li:hover { border-color: var(--accent); }
.deckname {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.95rem; font-weight: 600; text-decoration: none; color: var(--fg);
}
.deckname:hover { color: var(--accent); }
.row { display: flex; align-items: baseline; gap: 0.7rem; flex-wrap: wrap; }
.desc { color: var(--muted); font-size: 0.9rem; margin: 0.25rem 0 0; }
.pill {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.78rem; color: var(--muted); border: 1px solid var(--line);
  border-radius: 999px; padding: 0.05rem 0.5rem;
}
table { border-collapse: collapse; width: 100%; font-size: 0.9rem; }
th, td {
  text-align: left; padding: 0.55rem 0.7rem; border-bottom: 1px solid var(--line);
  vertical-align: top;
}
th { color: var(--muted); font-weight: 550; font-size: 0.8rem; }
td.mono, code {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.85rem;
}
code { background: var(--code-bg); border-radius: 5px; padding: 0.1rem 0.35rem; }
pre {
  background: var(--code-bg); border: 1px solid var(--line); border-radius: 10px;
  padding: 0.9rem 1.1rem; overflow-x: auto; font-size: 0.85rem;
}
pre code { background: none; padding: 0; }
.empty {
  border: 1px dashed var(--line); border-radius: 11px; padding: 2rem;
  text-align: center; color: var(--muted);
}
footer {
  margin-top: 4rem; padding-top: 1.5rem; border-top: 1px solid var(--line);
  color: var(--muted); font-size: 0.85rem;
}
';

# layout wraps a page body in the site chrome. `title` is escaped by the caller
# only when it holds a deck name; everything passed here is already escaped or
# is trusted markup built by this module.
func layout(title as string, body as string) {
    return '<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>' + $title + '</title>
<style>' + STYLE + '</style>
</head>
<body>
<header><div class="wrap">
<a class="brand" href="/">jennifer <span>decks</span></a>
<nav>
<a href="/">Decks</a>
<a href="/manual/">Manual</a>
<a href="/reference/">Reference</a>
</nav>
</div></header>
<div class="wrap">' + $body + '
<footer>The registry indexes; it does not host. Deck code stays in its own
repository, pinned to the commit it was published from.</footer>
</div>
</body>
</html>';
}

# searchForm renders the search box, pre-filled with the current query.
func searchForm(query as string) {
    return '<form class="search" action="/search" method="get">
<input type="search" name="q" placeholder="Search decks" aria-label="Search decks"
 value="' + html.escape($query) + '">
<button type="submit">Search</button>
</form>';
}

# deckUrl is the page URL for a deck, or "" for a bare name (which has no page:
# every registry deck is scoped).
func deckUrl(name as string) {
    if (not deckname.isScoped($name)) {
        return "";
    }
    return "/deck/" + deckname.scopeOf($name) + "/" + deckname.deckOf($name);
}

# hitItem renders one search result as a list item.
func hitItem(hit as search.Hit) {
    def safe as string init html.escape($hit.name);
    def url as string init deckUrl($hit.name);
    def title as string init '<span class="deckname">' + $safe + '</span>';
    if (not ($url == "")) {
        $title = '<a class="deckname" href="' + $url + '">' + $safe + '</a>';
    }
    def out as string init '<li><div class="row">' + $title;
    if (not ($hit.latest == "")) {
        $out = $out + '<span class="pill">' + html.escape($hit.latest) + '</span>';
    }
    $out = $out + '<span class="pill">' + convert.toString($hit.versions) + ' version';
    if (not ($hit.versions == 1)) {
        $out = $out + "s";
    }
    $out = $out + '</span></div>';
    if (not ($hit.description == "")) {
        $out = $out + '<p class="desc">' + html.escape($hit.description) + '</p>';
    }
    return $out + '</li>';
}

# hitList renders search results, or an explanatory panel when there are none.
func hitList(hits as list of search.Hit, emptyMessage as string) {
    if (len($hits) == 0) {
        return '<div class="empty">' + $emptyMessage + '</div>';
    }
    def out as string init '<ul class="decks">';
    for (def hit in $hits) {
        $out = $out + hitItem($hit);
    }
    return $out + '</ul>';
}

/**
 * The landing page: the search box over the whole deck listing.
 * @param db {flatdb.DB} the registry to read
 * @return {Page} a 200 page
 */
export func home(db as flatdb.DB) {
    def hits as list of search.Hit init search.find($db, "");
    def body as string init '<h1>Jennifer decks</h1>
<p class="lede">The registry jvc resolves and fetches decks from.</p>' +
        searchForm("") +
        '<h2>All decks (' + convert.toString(len($hits)) + ')</h2>' +
        hitList($hits, "No decks published yet.");
    return Page{ status: 200, body: layout("Jennifer decks", $body) };
}

/**
 * The search results page. An empty query lists everything, which is what the
 * landing page shows, so a submitted empty box is not an error.
 * @param db {flatdb.DB} the registry to read
 * @param query {string} the search query
 * @return {Page} a 200 page
 */
export func results(db as flatdb.DB, query as string) {
    def hits as list of search.Hit init search.find($db, $query);
    def q as string init strings.trim($query);
    def heading as string init "All decks";
    if (not ($q == "")) {
        $heading = convert.toString(len($hits)) + " result";
        if (not (len($hits) == 1)) {
            $heading = $heading + "s";
        }
        $heading = $heading + ' for <code>' + html.escape($q) + '</code>';
    }
    def body as string init '<h1>Search</h1>' + searchForm($q) +
        '<h2>' + $heading + '</h2>' +
        hitList($hits, 'Nothing matched <code>' + html.escape($q) + '</code>.');
    return Page{ status: 200, body: layout("Search decks", $body) };
}

# pinCell renders the integrity pin for a version, which depends on its kind.
func pinCell(v as store.DeckVersion) {
    if ($v.kind == store.KIND_GIT) {
        if ($v.commit == "") {
            return '<span class="muted">no commit recorded</span>';
        }
        return '<code>' + html.escape(strings.substring($v.commit, 0, 12)) + '</code>';
    }
    if ($v.checksum == "") {
        return '<span class="muted">no checksum recorded</span>';
    }
    return '<code>' + html.escape(strings.substring($v.checksum, 0, 19)) + '...</code>';
}

# mapCell renders a name -> constraint table as inline code, or a dash.
func mapCell(entries as map of string to string) {
    if (len($entries) == 0) {
        return "-";
    }
    def out as string init "";
    for (def key in $entries) {
        if (not ($out == "")) {
            $out = $out + " ";
        }
        $out = $out + '<code>' + html.escape($key) + " " +
            html.escape($entries[$key]) + '</code>';
    }
    return $out;
}

# listCell renders a capability list as inline code, or a dash.
func listCell(items as list of string) {
    if (len($items) == 0) {
        return "-";
    }
    def out as string init "";
    for (def item in $items) {
        if (not ($out == "")) {
            $out = $out + " ";
        }
        $out = $out + '<code>' + html.escape($item) + '</code>';
    }
    return $out;
}

# versionRows renders one table row per published version, newest first.
func versionRows(db as flatdb.DB, name as string) {
    def out as string init "";
    for (def version in store.listVersionsDescending($db, $name)) {
        def v as store.DeckVersion init store.getVersionRecord($db, $name, $version);
        $out = $out + '<tr><td class="mono">' + html.escape($v.version) + '</td>' +
            '<td class="mono">' + html.escape($v.kind) + '</td>' +
            '<td>' + pinCell($v) + '</td>' +
            '<td>' + mapCell($v.requires) + '</td>' +
            '<td>' + mapCell($v.engines) + '</td>' +
            '<td>' + listCell($v.capabilities) + '</td></tr>';
    }
    return $out;
}

/**
 * A deck's page: its description, how to depend on it, and every published
 * version with its pin, dependencies, engines, and capabilities. An unknown
 * deck is a 404 page.
 * @param db {flatdb.DB} the registry to read
 * @param name {string} the deck name
 * @return {Page} the deck page at 200, or a 404 page
 */
export func deck(db as flatdb.DB, name as string) {
    if (not store.hasDeck($db, $name)) {
        return notFound("No deck named " + html.escape($name) + " is published here.");
    }
    def safe as string init html.escape($name);
    def all as list of string init store.listVersionsDescending($db, $name);
    def body as string init '<h1><span class="deckname">' + $safe + '</span></h1>';
    def description as string init store.deckDescription($db, $name);
    if (not ($description == "")) {
        $body = $body + '<p class="lede">' + html.escape($description) + '</p>';
    }
    if (len($all) > 0) {
        $body = $body + '<h2>Depend on it</h2><pre><code>[decks]
"' + $safe + '" = "^' + html.escape($all[0]) + '"</code></pre>';
    }
    $body = $body + '<h2>Versions</h2>';
    if (len($all) == 0) {
        $body = $body + '<div class="empty">This deck has no published versions.</div>';
    } else {
        $body = $body + '<table><thead><tr><th>Version</th><th>Kind</th><th>Pin</th>' +
            '<th>Requires</th><th>Engines</th><th>Capabilities</th></tr></thead><tbody>' +
            versionRows($db, $name) + '</tbody></table>';
    }
    if (len($all) > 0) {
        def latest as store.DeckVersion init store.getVersionRecord($db, $name, $all[0]);
        if (not ($latest.license == "")) {
            $body = $body + '<h2>License</h2><p>' + html.escape($latest.license) + '</p>';
        }
    }
    $body = $body + readmeSection($db, $name);
    $body = $body + '<p class="muted" style="margin-top:2rem">' +
        '<a href="/deck?name=' + $safe + '">This deck as JSON</a></p>';
    return Page{ status: 200, body: layout($name, $body) };
}

/**
 * A deck's rendered README, or "" when it has none.
 *
 * **The source is escaped before it is rendered.** `markdown.toHtml` escapes raw
 * HTML itself as of 0.24.0-dev+29, so this is now belt and braces rather than
 * the only thing standing between a publisher and script on this origin - but it
 * stays. The floor this project declares is `>=0.25.0`, which does not by itself
 * guarantee a build new enough to have that default, and the cost of keeping it
 * is nothing: escaping first turns `<script>` into visible text while leaving
 * every markdown construct intact, because none of markdown's syntax characters
 * are HTML special characters, and the renderer does not re-escape what we
 * escaped. If you ever need raw HTML honoured, `markdown.toHtmlWith` opts into
 * it explicitly - which is exactly what a README must never get.
 *
 * Exported so the escaping has a test of its own rather than being reachable
 * only through a whole page.
 * @param db {flatdb.DB} the registry to read
 * @param name {string} the deck name
 * @return {string} the rendered section, or "" when there is no README
 */
export func readmeSection(db as flatdb.DB, name as string) {
    def source as string init store.getReadme($db, $name);
    if (strings.trim($source) == "") {
        return "";
    }
    return '<h2>Readme</h2><div class="readme">' +
        markdown.toHtml(html.escape($source)) + '</div>';
}

/**
 * A 404 page carrying a human explanation.
 * @param message {string} the explanation, already escaped
 * @return {Page} a 404 page
 */
export func notFound(message as string) {
    def body as string init '<h1>Not found</h1><p class="lede">' + $message + '</p>' +
        searchForm("");
    return Page{ status: 404, body: layout("Not found", $body) };
}

/**
 * The placeholder shown for a static section that has not been built. Serving a
 * bare 404 there would look like a broken site rather than a missing build step,
 * so it names the command that produces it.
 * @param title {string} the section's name, e.g. "Reference"
 * @param root {string} the directory it is served from, e.g. "public/reference"
 * @param config {string} the grimoire config to build it ("" for the default)
 * @return {Page} a 404 page explaining how to build that section
 */
export func sectionMissing(title as string, root as string, config as string) {
    def flag as string init "";
    if (not ($config == "")) {
        $flag = " --config " + html.escape($config);
    }
    def body as string init '<h1>' + html.escape($title) + ' not built</h1>
<p class="lede">The site serves this section from <code>' + html.escape($root) +
        '/</code>, which this deployment does not have yet. Build it with:</p>
<pre><code>docker run --rm --user "$(id -u):$(id -g)" \\
    -v "$PWD:/work" ghcr.io/jennifer-language/grimoire build' + $flag + '</code></pre>
<p class="muted">The Markdown sources are in the repository either way.</p>';
    return Page{ status: 404, body: layout($title + " not built", $body) };
}
