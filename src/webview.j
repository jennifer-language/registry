# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The website's HTML responses as pure data. Each function maps a registry plus
 * request inputs to a `Page` (HTTP status and HTML string), with no dependency
 * on the web engine.
 *
 * The web surface is read-only: no form writes anything, and there is no
 * session and no account UI. Publishing is a CLI action.
 *
 * Every interpolated value goes through `esc`: deck names and descriptions are
 * publisher input and land inside markup and attributes.
 * @module webview
 * @example
 * import "./webview.j" as webview;
 * def page as webview.Page init webview.deck($db, "@acme/routeros", $now);
 * # web.html($ctx, $page.status, $page.body);
 */

use strings;
use convert;
use json;
use lists;
use maps;
use hash;
use encoding;
import "flatdb.j" as flatdb;
import "html.j" as html;
import "markdown.j" as markdown;
import "./store.j" as store;
import "./search.j" as search;
import "./deckname.j" as deckname;
import "./stats.j" as stats;
import "./keywords.j" as keywords;
import "uri.j" as uri;

/**
 * An HTML response as pure data: a status code and a rendered body.
 * @field status {int} the HTTP status code
 * @field body {string} the rendered HTML document
 */
export def struct Page {
    status as int,
    body as string
};

/**
 * The Content-Security-Policy for every page this module renders. Only the theme
 * switch runs, admitted by its hash, so an escaping slip has no script to run;
 * only images load from elsewhere (a README may show them from https); no other
 * site may frame a page.
 *
 * Styles are `unsafe-inline` because the stylesheet is inline, and a style
 * cannot run code.
 * @return {string} the header value
 */
export func contentSecurityPolicy() {
    def digest as bytes init hash.compute(convert.bytesFromString(THEME_SCRIPT, "utf-8"), "sha256");
    return "default-src 'none'; script-src 'sha256-" + encoding.toText($digest, "base64") +
        "'; style-src 'unsafe-inline'; img-src 'self' https: data:; " +
        "form-action 'self'; base-uri 'none'; frame-ancestors 'none'";
}

# esc escapes text for element content and quoted attribute values alike, so it
# must cover both quotes (`html.escape` does since 0.24.0-dev+167; without them
# the search box's `value` attribute was a reflected XSS). Every page calls this
# one escaper, and `webview_test.j` asserts the quotes are covered.
func esc(s as string) {
    return html.escape($s);
}

# The theme switch, inlined beside the stylesheet so a page stays one request
# with no CDN and no build step.
#
# It runs in `head`, before the body paints; applied later, a stored choice
# shows the wrong theme for a frame. It removes the `no-js` class, which is what
# shows the switch: with scripting off the button stays hidden and the page
# follows the system setting.
#
# `light` and `dark` are the only stored values; an unstamped page follows the
# system, so there is no third "clear" state.
#
# The button is wired by a document listener, not an `onclick` attribute: the
# Content-Security-Policy admits this script by its hash, and an inline handler
# would need `unsafe-inline`, which admits any injected script.
def const THEME_SCRIPT as string init '
(function () {
  var root = document.documentElement;
  root.classList.remove("no-js");
  try {
    var saved = localStorage.getItem("jvc-theme");
    if (saved === "light" || saved === "dark") { root.dataset.theme = saved; }
  } catch (e) {}
  window.jvcTheme = function () {
    var dark = root.dataset.theme
      ? root.dataset.theme === "dark"
      : matchMedia("(prefers-color-scheme: dark)").matches;
    root.dataset.theme = dark ? "light" : "dark";
    try { localStorage.setItem("jvc-theme", root.dataset.theme); } catch (e) {}
  };
  document.addEventListener("click", function (e) {
    if (e.target.closest && e.target.closest("button.theme")) { window.jvcTheme(); }
  });
})();
';

# The site's stylesheet, inline so a page is one request with nothing fetched.
# Colours are custom properties redefined per theme, so dark mode is the same
# markup.
#
# The two themes use different oranges for the accent: burnt orange reads as
# text on near-white, a light orange on the dark ground. `--on-accent` is the
# colour of text on the accent (the search button), so it contrasts in both.
def const STYLE as string init '
:root {
  --bg: #fdfdfc; --fg: #1a1a19; --muted: #6b6b66; --line: #e4e4e0;
  --card: #ffffff; --accent: #c2410c; --on-accent: #ffffff; --code-bg: #f4f4f1;
  --warn-fg: #9a3412; --warn-bg: #fff7ed; --warn-line: #fdba74;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #16161a; --fg: #e8e8e6; --muted: #9a9a95; --line: #2a2a30;
    --card: #1d1d22; --accent: #ff9e64; --on-accent: #16161a; --code-bg: #232329;
    --warn-fg: #ffb787; --warn-bg: #2a1f18; --warn-line: #7c4a24;
  }
}
:root[data-theme="dark"] {
  --bg: #16161a; --fg: #e8e8e6; --muted: #9a9a95; --line: #2a2a30;
  --card: #1d1d22; --accent: #ff9e64; --on-accent: #16161a; --code-bg: #232329;
  --warn-fg: #ffb787; --warn-bg: #2a1f18; --warn-line: #7c4a24;
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--fg);
  font: 16px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  -webkit-font-smoothing: antialiased;
}
.wrap { max-width: 72rem; margin: 0 auto; padding: 0 1.25rem 5rem; }
/* The shell is wide because the things that want width are here: a six-column
   version table, a stats row, a scope listing. Running text is not one of them,
   so prose keeps a reading measure of its own rather than stretching to the
   full width of whatever monitor is in front of it. */
.lede, .readme, .prose { max-width: 54rem; }
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
.theme {
  display: inline-flex; align-items: center; gap: 0.4rem; padding: 0.3rem 0.7rem;
  border: 1px solid var(--line); border-radius: 999px; background: var(--card);
  color: var(--muted); font: inherit; font-size: 0.85rem; cursor: pointer;
  line-height: 1;
}
.theme:hover { color: var(--accent); border-color: var(--accent); }
.theme:focus-visible {
  outline: none; border-color: var(--accent);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 18%, transparent);
}
.theme svg { width: 14px; height: 14px; fill: none; stroke: currentColor;
  stroke-width: 1.7; stroke-linecap: round; }
/* The icon and word describe what a click *gives you*, so only one shows at a
   time: the sun on a dark page, the moon on a light one. */
.theme .to-light, :root[data-theme="dark"] .theme .to-dark { display: none; }
.theme .to-dark { display: inline-flex; }
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) .theme .to-dark { display: none; }
  :root:not([data-theme="light"]) .theme .to-light { display: inline-flex; }
}
:root[data-theme="dark"] .theme .to-light { display: inline-flex; }
:root[data-theme="light"] .theme .to-dark { display: inline-flex; }
:root[data-theme="light"] .theme .to-light { display: none; }
/* No script, no switch: it would be a button that does nothing. The page still
   follows whatever the system asks for, which is what it did before. */
.no-js .theme { display: none; }
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
  background: var(--accent); color: var(--on-accent); font: inherit; font-weight: 550;
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
/* Facts about a deck that are not its versions: where the code lives, who may
   publish it. auto-fit so they sit side by side on a wide screen and stack on a
   phone without a media query. */
.facts {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(16rem, 1fr));
  gap: 0.6rem; margin: 0.5rem 0 0; padding: 0; list-style: none;
}
.fact {
  border: 1px solid var(--line); border-radius: 11px; background: var(--card);
  padding: 0.85rem 1.05rem;
}
.fact dt { color: var(--muted); font-size: 0.78rem; margin: 0 0 0.3rem; }
.fact dd { margin: 0; font-size: 0.95rem; overflow-wrap: anywhere; }
.fact a { color: var(--fg); text-decoration: none; }
.fact a:hover { color: var(--accent); }
/* Counts. Tabular figures so the numbers line up as a row of columns rather
   than drifting with the width of each digit. */
.stats {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(7.5rem, 1fr));
  gap: 0.6rem; margin: 0.5rem 0 0; padding: 0; list-style: none;
}
.stat {
  border: 1px solid var(--line); border-radius: 11px; background: var(--card);
  padding: 0.8rem 1rem;
}
.stat b {
  display: block; font-size: 1.45rem; font-weight: 600; letter-spacing: -0.02em;
  font-variant-numeric: tabular-nums; line-height: 1.2;
}
.stat span { color: var(--muted); font-size: 0.78rem; }
.note { color: var(--muted); font-size: 0.85rem; margin: 0.9rem 0 0; }
/* A yanked version is labelled, never hidden: a lockfile that pins one still
   installs it, so a reader has to be able to find it. Muting the row and
   striking the number says "not this one" without removing the evidence. */
.notice {
  border: 1px solid var(--warn-line); border-left-width: 3px; border-radius: 8px;
  background: var(--warn-bg); padding: 0.75rem 1rem; margin: 0 0 1.5rem;
  font-size: 0.9rem; max-width: 54rem;
}
tr.is-yanked td { color: var(--muted); }
tr.is-yanked td:first-child { text-decoration: line-through; }
.pill.yanked { color: var(--warn-fg); border-color: var(--warn-line); }
.ok { color: var(--muted); font-size: 0.8rem; }
/* Tags. One pill style, two contexts: inline on a deck page, and sized by use
   in the cloud. The count rides inside the pill so a tag and its weight cannot
   be separated by a line break. */
.tag {
  display: inline-flex; align-items: baseline; gap: 0.4rem; margin: 0 0.35rem 0.5rem 0;
  padding: 0.2rem 0.6rem; border: 1px solid var(--line); border-radius: 999px;
  background: var(--card); color: var(--fg); text-decoration: none;
  font-size: 0.85rem; line-height: 1.5;
}
.tag:hover { border-color: var(--accent); color: var(--accent); }
.tag .count {
  color: var(--muted); font-size: 0.75em; font-variant-numeric: tabular-nums;
}
.cloud { margin: 0.5rem 0 0; }
/* Five steps, not a continuous scale: one popular tag on a linear scale makes
   everything else unreadable. */
.cloud-1 { font-size: 0.8rem; }
.cloud-2 { font-size: 0.95rem; }
.cloud-3 { font-size: 1.1rem; }
.cloud-4 { font-size: 1.3rem; }
.cloud-5 { font-size: 1.55rem; }
/* The alphabetical list is the complete, scannable rendering: several per row,
   filling the width rather than one long column. */
.taglist {
  list-style: none; padding: 0; margin: 0.5rem 0 0; display: grid;
  grid-template-columns: repeat(auto-fill, minmax(11rem, 1fr)); gap: 0.15rem;
}
.pager { margin: 1rem 0; color: var(--muted); }
.pager a { margin: 0 0.5rem; }
';

# layout wraps a page body in the site chrome. `title` is plain text and is
# escaped here; `body` is markup with everything untrusted already escaped.
func layout(title as string, body as string) {
    return '<!doctype html>
<html lang="en" class="no-js">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>' + esc($title) + '</title>
<style>' + STYLE + '</style>
<script>' + THEME_SCRIPT +
        '</script>
</head>
<body>
<header><div class="wrap">
<a class="brand" href="/">jennifer <span>registry</span></a>
<nav>
<a href="/browse">Browse</a>
<a href="/tags">Tags</a>
<a href="/manual/">User manual</a>
<a href="/reference/">Admin manual</a>
<a href="/specs/">Specs</a>
<a href="/.well-known/jennifer-registry">API</a>
<button type="button" class="theme"
  aria-label="Switch between light and dark">
<span class="to-light"><svg viewBox="0 0 24 24" aria-hidden="true">
<circle cx="12" cy="12" r="4.2"/>
<path d="M12 2.6v2.2M12 19.2v2.2M4.2 12H2M22 12h-2.2M5.9 5.9 4.4 4.4M19.6 19.6
l-1.5-1.5M18.1 5.9l1.5-1.5M4.4 19.6l1.5-1.5"/></svg>Light</span>
<span class="to-dark"><svg viewBox="0 0 24 24" aria-hidden="true">
<path d="M20.5 14.6A8.6 8.6 0 0 1 9.4 3.5a8.6 8.6 0 1 0 11.1 11.1Z"/></svg>Dark</span>
</button>
</nav>
</div></header>
<div class="wrap">' + $body +
        '
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
 value="' + esc($query) + '">
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
    def safe as string init esc($hit.name);
    def url as string init deckUrl($hit.name);
    def title as string init '<span class="deckname">' + $safe + '</span>';
    if (not ($url == "")) {
        $title = '<a class="deckname" href="' + esc($url) + '">' + $safe + '</a>';
    }
    def out as string init '<li><div class="row">' + $title;
    if (not ($hit.latest == "")) {
        $out = $out + '<span class="pill">' + esc($hit.latest) + '</span>';
    }
    $out = $out + '<span class="pill">' + convert.toString($hit.versions) + ' version';
    if (not ($hit.versions == 1)) {
        $out = $out + "s";
    }
    $out = $out + '</span></div>';
    if (not $hit.live) {
        $out = $out + ' <span class="pill yanked">all versions yanked</span>';
    }
    if (not ($hit.description == "")) {
        $out = $out + '<p class="desc">' + esc($hit.description) + '</p>';
    }
    return $out + '</li>';
}

# hitList renders search results, or an explanatory panel when there are none.
func hitList(hits as list of search.Hit, emptyMessage as string) {
    if (len($hits) == 0) {
        return '<div class="empty">' + $emptyMessage + '</div>';
    }
    # Joined once: appending to a growing string is quadratic in the listing.
    def items as list of string init [];
    for (def hit in $hits) {
        $items[] = hitItem($hit);
    }
    return '<ul class="decks">' + strings.join($items, "") + '</ul>';
}

/**
 * The landing page: search, links to `/browse` and `/tags`, and the deck
 * count. It does not list every deck, since a full listing grows without bound
 * and is the slowest page to render and send.
 * @param db {flatdb.DB} the registry to read
 * @return {Page} a 200 page
 */
export func home(db as flatdb.DB) {
    def total as int init len(store.listDecks($db));
    def body as string init '<h1>Jennifer registry</h1>
<p class="lede">The registry jvc resolves and fetches decks from.</p>' +
        searchForm("") +
        '<ul class="facts">' +
        '<div class="fact"><dt>Browse</dt><dd><a href="/browse">All ' +
        convert.toString($total) + ' decks</a>, newest listing first</dd></div>' +
        '<div class="fact"><dt>By tag</dt><dd><a href="/tags">Tags</a>, ' +
        'grouped by what decks are for</dd></div>' +
        '<div class="fact"><dt>For clients</dt><dd><a href="/.well-known/' +
        'jennifer-registry">The API</a>, and what this server promises</dd></div>' +
        '</ul>';
    return Page{status: 200, body: layout("Jennifer registry", $body)};
}

/**
 * How many decks one page of a listing shows. Measured unpaged at 5,000 decks:
 * 1.2 MB per page and about 80 MB per request in flight.
 */
export def const PAGE_SIZE as int init 100;

/**
 * Turn a `page` query parameter into a page number: 1 for anything that is not
 * a small positive number. Past the last page is clamped where the listing is
 * known.
 * @param raw {string} the parameter as given ("" when absent)
 * @return {int} the page, 1-based
 */
export func pageNumber(raw as string) {
    if (len($raw) == 0 or len($raw) > 6) {
        return 1;
    }
    for (def ch in strings.chars($raw)) {
        if ($ch < "0" or $ch > "9") {
            return 1;
        }
    }
    def n as int init convert.toInt($raw);
    if ($n < 1) {
        return 1;
    }
    return $n;
}

# lastPage is how many pages a listing of `total` entries has; at least one, so
# an empty listing is page 1 of 1.
func lastPage(total as int) {
    if ($total == 0) {
        return 1;
    }
    return convert.toInt(($total + PAGE_SIZE - 1) / PAGE_SIZE);
}

# pageOf renders one page of a selection from the index, clamped to the
# listing, with links to its neighbours. `base` is the listing's URL up to and
# including the separator the page parameter follows ("/browse?" or
# "/search?q=x&amp;"), already escaped; `empty` is what an empty one says.
func pageOf(
    index as json.Value,
    positions as list of int,
    page as int,
    base as string,
    empty as string) {
    def total as int init len($positions);
    def last as int init lastPage($total);
    def shown as int init $page;
    if ($shown > $last) {
        $shown = $last;
    }
    def out as string init hitList(
        search.hits($index, $positions, ($shown - 1) * PAGE_SIZE, PAGE_SIZE),
        $empty);
    if ($last == 1) {
        return $out;
    }
    def nav as string init '<nav class="pager">';
    if ($shown > 1) {
        $nav = $nav + '<a rel="prev" href="' + $base + 'page=' +
            convert.toString($shown - 1) + '">Previous</a> ';
    }
    $nav = $nav + 'Page ' + convert.toString($shown) + ' of ' + convert.toString($last);
    if ($shown < $last) {
        $nav = $nav + ' <a rel="next" href="' + $base + 'page=' +
            convert.toString($shown + 1) + '">Next</a>';
    }
    return $out + $nav + '</nav>';
}

/**
 * The browse page: every deck, a page at a time.
 * @param index {json.Value} the registry's deck index, from `search.index`
 * @param page {int} which page, 1-based; past the last shows the last
 * @return {Page} a 200 page
 */
export func browse(index as json.Value, page as int) {
    def all as list of int init search.select($index, "");
    def listing as string init pageOf($index, $all, $page, "/browse?", "No decks published yet.");
    def body as string init '<h1>Browse</h1>
<p class="lede">Every deck published here.</p>' + searchForm("") +
        '<h2>All decks (' + convert.toString(len($all)) + ')</h2>' + $listing;
    return Page{status: 200, body: layout("Browse", $body)};
}

/**
 * The search results page. An empty query lists everything.
 * @param index {json.Value} the registry's deck index, from `search.index`
 * @param query {string} the search query
 * @param page {int} which page of results, 1-based
 * @return {Page} a 200 page, or a 400 for a query over `search.MAX_QUERY`
 */
export func results(index as json.Value, query as string, page as int) {
    if (len($query) > search.MAX_QUERY) {
        def body as string init '<h1>Search</h1>' + searchForm("") +
            '<p class="lede">A search can be at most ' +
            convert.toString(search.MAX_QUERY) + ' characters long.</p>';
        return Page{status: 400, body: layout("Search decks", $body)};
    }
    def found as list of int init search.select($index, $query);
    def count as int init len($found);
    def q as string init strings.trim($query);
    def heading as string init "All decks";
    if (not ($q == "")) {
        $heading = convert.toString($count) + " result";
        if (not ($count == 1)) {
            $heading = $heading + "s";
        }
        $heading = $heading + ' for <code>' + esc($q) + '</code>';
    }
    def base as string init "/search?q=" + esc(uri.encodeForm($q)) + "&amp;";
    def none as string init 'Nothing matched <code>' + esc($q) + '</code>.';
    def body as string init '<h1>Search</h1>' + searchForm($q) +
        '<h2>' + $heading + '</h2>' + pageOf($index, $found, $page, $base, $none);
    return Page{status: 200, body: layout("Search decks", $body)};
}

# pinCell renders the integrity pin for a version, which depends on its kind.
func pinCell(v as store.DeckVersion) {
    if ($v.kind == store.KIND_GIT) {
        if ($v.commit == "") {
            return '<span class="muted">no commit recorded</span>';
        }
        return '<code>' + esc(strings.substring($v.commit, 0, 12)) + '</code>';
    }
    if ($v.checksum == "") {
        return '<span class="muted">no checksum recorded</span>';
    }
    return '<code>' + esc(strings.substring($v.checksum, 0, 19)) + '...</code>';
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
        $out = $out + '<code>' + esc($key) + " " +
            esc($entries[$key]) + '</code>';
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
        $out = $out + '<code>' + esc($item) + '</code>';
    }
    return $out;
}

# versionRows renders one table row per published version, newest first.
func versionRows(db as flatdb.DB, name as string) {
    def out as string init "";
    for (def version in store.listVersionsDescending($db, $name)) {
        def v as store.DeckVersion init store.getVersionRecord($db, $name, $version);
        def status as string init '<span class="ok">live</span>';
        def rowClass as string init "";
        if ($v.yanked) {
            $status = '<span class="pill yanked">yanked</span>';
            $rowClass = ' class="is-yanked"';
        }
        $out = $out + '<tr' + $rowClass + '><td class="mono">' +
            esc($v.version) + '</td>' +
            '<td>' + $status + '</td>' +
            '<td class="mono">' + esc($v.kind) + '</td>' +
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
 * @param now {int} the current time (Unix seconds), for the count windows
 * @return {Page} the deck page at 200, or a 404 page
 */
export func deck(db as flatdb.DB, name as string, now as int) {
    if (not store.hasDeck($db, $name)) {
        return notFound("No deck named " + $name + " is published here.");
    }
    def safe as string init esc($name);
    def all as list of string init store.listVersionsDescending($db, $name);
    # Live versions drive everything a reader might act on; the table lists all,
    # with yanked versions labelled.
    def live as list of string init store.listLiveVersionsDescending($db, $name);
    def body as string init '<h1><span class="deckname">' + $safe + '</span></h1>';
    def description as string init store.deckDescription($db, $name);
    if (not ($description == "")) {
        $body = $body + '<p class="lede">' + esc($description) + '</p>';
    }
    $body = $body + tagRow($db, $name) + yankNotice($all, $live);
    if (len($live) > 0) {
        $body = $body + '<h2>Depend on it</h2><pre><code>[decks]
"' + $safe + '" = "^' + esc($live[0]) + '"</code></pre>';
    }
    $body = $body + '<h2>Versions</h2>';
    if (len($all) == 0) {
        $body = $body + '<div class="empty">This deck has no published versions.</div>';
    } else {
        $body = $body + '<table><thead><tr><th>Version</th><th>Status</th>' +
            '<th>Kind</th><th>Pin</th>' +
            '<th>Requires</th><th>Engines</th><th>Capabilities</th></tr></thead><tbody>' +
            versionRows($db, $name) + '</tbody></table>';
    }
    # The licence and source come from the newest live version, if any.
    def shown as list of string init $live;
    if (len($shown) == 0) {
        $shown = $all;
    }
    if (len($shown) > 0) {
        def latest as store.DeckVersion init store.getVersionRecord($db, $name, $shown[0]);
        if (not ($latest.license == "")) {
            $body = $body + '<h2>License</h2><p>' + esc($latest.license) + '</p>';
        }
        $body = $body + factsSection($db, $name, $latest);
    }
    $body = $body + statsSection($db, $name, $now);
    $body = $body + readmeSection($db, $name);
    $body = $body + '<p class="muted" style="margin-top:2rem">' +
        '<a href="/deck?name=' + $safe + '">This deck as JSON</a></p>';
    return Page{status: 200, body: layout($name, $body)};
}

# yankNotice warns when the versions a reader would reach for are withdrawn, so
# the page never presents as current a version the resolver refuses. Two cases:
#
#   * every version yanked: nothing to install;
#   * the newest yanked, older ones live: the snippet pins a lower version than
#     the highest in the table.
func yankNotice(all as list of string, live as list of string) {
    if (len($all) == 0 or len($all) == len($live)) {
        return "";
    }
    if (len($live) == 0) {
        return '<p class="notice">Every published version of this deck has been ' +
            '<strong>yanked</strong>. Nothing here will be chosen by a new ' +
            'install. A lockfile that already pins one of these versions keeps ' +
            'working.</p>';
    }
    if ($all[0] == $live[0]) {
        # Only older versions are yanked; the table labels them.
        return "";
    }
    return '<p class="notice">The newest version, <code>' +
        esc($all[0]) + '</code>, has been <strong>yanked</strong>. The ' +
        'newest installable version is <code>' + esc($live[0]) +
        '</code>, which is what the snippet below pins.</p>';
}

# tagRow renders a deck's own tags, linking each to the decks that share it.
func tagRow(db as flatdb.DB, name as string) {
    def tags as list of string init latestKeywords($db, $name);
    if (len($tags) == 0) {
        return "";
    }
    def out as string init '<p class="cloud">';
    for (def one in $tags) {
        $out = $out + '<a class="tag" href="/tag/' + esc($one) + '">' +
            esc($one) + '</a>';
    }
    return $out + '</p>';
}

/**
 * A deck's resolution counts, or "" when nothing has ever been counted.
 *
 * The heading says "Resolutions" and the note explains it: clients fetch code
 * from the deck's repository, so the registry counts metadata lookups, never
 * downloads. Such counts run high on CI-heavy decks and low on decks installed
 * from stable lockfiles.
 *
 * A deck never resolved renders nothing rather than six zeroes.
 * @param db {flatdb.DB} the registry to read
 * @param name {string} the deck name
 * @param now {int} the current time (Unix seconds)
 * @return {string} the rendered section, or ""
 */
export func statsSection(db as flatdb.DB, name as string, now as int) {
    def rec as json.Value init store.getStats($db, $name);
    if (stats.isEmpty($rec)) {
        return "";
    }
    def c as stats.Counts init stats.summarise($rec, $now);
    def cells as list of list of string init [
        [convert.toString($c.thisHour), "this hour"],
        [convert.toString($c.today), "today"],
        [convert.toString($c.last7Days), "last 7 days"],
        [convert.toString($c.last30Days), "last 30 days"],
        [convert.toString($c.last12Months), "last 12 months"],
        [convert.toString($c.total), "all time"]
    ];
    def out as string init '<h2>Resolutions</h2><ul class="stats">';
    for (def cell in $cells) {
        $out = $out + '<li class="stat"><b>' + $cell[0] + '</b><span>' +
            $cell[1] + '</span></li>';
    }
    return $out + '</ul><p class="note prose">Times a client asked this registry ' +
        'where to find this deck. <strong>Not downloads:</strong> the registry ' +
        'only stores metadata, and the code is fetched from its repository ' +
        'directly, so we never see an install and cannot count one. Repeated ' +
        'builds inflate these numbers; installs from an existing lockfile do ' +
        'not appear at all. Counted in UTC.</p>';
}

/**
 * A repository URL turned into something a browser can open, or "" if it is not
 * safe to link.
 *
 * A trailing `.git` is removed. The URL is publisher input, so only `http` and
 * `https` are linked: an escaped `javascript:` or `data:` href would still run.
 * @param url {string} the recorded clone or artifact URL
 * @return {string} a browsable URL, or "" when it should not be a link
 */
export func repoLink(url as string) {
    def out as string init strings.trim($url);
    if (not (strings.startsWith($out, "https://") or
        strings.startsWith($out, "http://"))) {
        return "";
    }
    if (strings.endsWith($out, ".git")) {
        $out = strings.substring($out, 0, len($out) - 4);
    }
    return $out;
}

/**
 * How a repository URL reads on the page: the host and path, without the scheme.
 * @param url {string} the browsable URL from `repoLink`
 * @return {string} the label, unescaped
 */
export func repoLabel(url as string) {
    for (def scheme in ["https://", "http://"]) {
        if (strings.startsWith($url, $scheme)) {
            return strings.substring($url, len($scheme), len($url));
        }
    }
    return $url;
}

# factsSection renders where a deck's code lives and who may publish it.
func factsSection(db as flatdb.DB, name as string, latest as store.DeckVersion) {
    def items as string init "";
    def link as string init repoLink($latest.url);
    if (not ($link == "")) {
        def safeLink as string init esc($link);
        $items = $items + '<div class="fact"><dt>Source</dt><dd><a href="' +
            $safeLink + '" rel="noopener noreferrer">' +
            esc(repoLabel($link)) + '</a></dd></div>';
    }
    if (not ($latest.ref == "")) {
        $items = $items + '<div class="fact"><dt>Released from</dt><dd><code>' +
            esc($latest.ref) + '</code></dd></div>';
    }
    $items = $items + ownerFact($db, $name);
    if ($items == "") {
        return "";
    }
    return '<h2>Source</h2><dl class="facts">' + $items + '</dl>';
}

# ownerFact renders the scope a deck belongs to and who holds it.
#
# The login is shown, never the subject id (see `listScopes`: ids are what
# ownership binds to). Co-owners are counted, not named, because the store keeps
# them as ids with no login.
func ownerFact(db as flatdb.DB, name as string) {
    def scope as string init deckname.scopeOf($name);
    if ($scope == "") {
        return "";
    }
    def safeScope as string init esc($scope);
    def link as string init '<a href="/scope/' + $safeScope + '">@' + $safeScope +
        '</a>';
    if (not store.hasNamespace($db, $scope)) {
        return '<div class="fact"><dt>Scope</dt><dd>' + $link + '</dd></div>';
    }
    def ns as store.Namespace init store.getNamespace($db, $scope);
    def who as string init $link;
    if (not ($ns.login == "")) {
        $who = $who + ' <span class="pill">' + esc($ns.login) + '</span>';
    }
    if ($ns.kind == store.SCOPE_ORG) {
        $who = $who + ' <span class="pill">organisation</span>';
    }
    def extra as int init len(store.ownersOf($db, $scope)) - 1;
    if ($extra > 0) {
        $who = $who + ' <span class="pill">+' + convert.toString($extra) +
            ' co-owner</span>';
    }
    return '<div class="fact"><dt>Published under</dt><dd>' + $who + '</dd></div>';
}

/**
 * A deck's rendered README, or "" when it has none.
 *
 * A README is untrusted publisher input, rendered with `markdown.toHtml` alone,
 * which escapes raw HTML and turns a link whose scheme is not http, https or
 * mailto into `#`. Never use `markdown.toHtmlWith`, which opts raw HTML back in.
 * Escaping the source first would double-escape code blocks; the tests fail on
 * an interpreter without safe defaults instead.
 *
 * Exported so the escaping has its own test.
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
        markdown.toHtml($source) + '</div>';
}

/**
 * A scope's page: who holds it, and every deck published under it.
 *
 * The deck page's "Published under" line links here. A registered but unowned
 * scope (a reserved name, see `reserved.j`) is shown as reserved.
 * @param db {flatdb.DB} the registry to read
 * @param index {json.Value} the registry's deck index, from `search.index`
 * @param name {string} the scope, with or without its leading "@"
 * @param page {int} which page of its decks, 1-based
 * @return {Page} the scope page at 200, or a 404 page
 */
export func scope(db as flatdb.DB, index as json.Value, name as string, page as int) {
    def folded as string init deckname.fold(strings.trim($name));
    if (strings.startsWith($folded, "@")) {
        $folded = strings.substring($folded, 1, len($folded));
    }
    def decks as list of int init search.under($index, $folded);
    def count as int init len($decks);
    if (not store.hasNamespace($db, $folded) and $count == 0) {
        return notFound("No scope named @" + $folded + " is registered here.");
    }
    def safe as string init esc($folded);
    def body as string init '<h1><span class="deckname">@' + $safe +
        '</span></h1>' + scopeFacts($db, $folded);
    $body = $body + '<h2>Decks (' + convert.toString($count) + ')</h2>';
    def none as string init "Nothing is published under this scope yet.";
    $body = $body + pageOf($index, $decks, $page, "/scope/" + $safe + "?", $none);
    return Page{status: 200, body: layout("@" + $folded, $body)};
}

# scopeFacts renders who holds a scope. Logins only, never subject ids.
func scopeFacts(db as flatdb.DB, folded as string) {
    if (not store.hasNamespace($db, $folded)) {
        return '<p class="lede">This scope is not registered. The decks below ' +
            'predate it being claimed.</p>';
    }
    def ns as store.Namespace init store.getNamespace($db, $folded);
    def items as string init "";
    if ($ns.subject == "") {
        # A reserved name: registered so nobody can claim it, bound to nobody so
        # nobody can publish under it.
        $items = $items + '<div class="fact"><dt>Status</dt><dd>Reserved by ' +
            'this registry</dd></div>';
    } else {
        def owner as string init esc($ns.login);
        if ($ns.login == "") {
            $owner = '<span class="muted">an account with no recorded login</span>';
        }
        $items = $items + '<div class="fact"><dt>Owner</dt><dd>' + $owner +
            '</dd></div>';
        def kind as string init "User scope";
        if ($ns.kind == store.SCOPE_ORG) {
            $kind = "Organisation scope: any active member may publish";
        }
        $items = $items + '<div class="fact"><dt>Kind</dt><dd>' + $kind +
            '</dd></div>';
        def extra as int init len(store.ownersOf($db, $folded)) - 1;
        if ($extra > 0) {
            $items = $items + '<div class="fact"><dt>Co-owners</dt><dd>' +
                convert.toString($extra) + '</dd></div>';
        }
    }
    if (not ($ns.provider == "")) {
        $items = $items + '<div class="fact"><dt>Identity provider</dt><dd>' +
            esc($ns.provider) + '</dd></div>';
    }
    return '<dl class="facts">' + $items + '</dl>';
}

/**
 * A 404 page carrying a human explanation.
 *
 * The message is plain text and is escaped here, not by the caller, since it
 * often carries the requested name; a caller-escapes contract was once a
 * reflected XSS.
 * @param message {string} the explanation, as plain text
 * @return {Page} a 404 page
 */
export func notFound(message as string) {
    def body as string init '<h1>Not found</h1><p class="lede">' + esc($message) +
        '</p>' + searchForm("");
    return Page{status: 404, body: layout("Not found", $body)};
}

/**
 * The placeholder shown for a static section that has not been built; it names
 * the command that builds it.
 * @param title {string} the section's name, e.g. "Admin manual"
 * @param root {string} the directory it is served from, e.g. "public/reference"
 * @param config {string} the grimoire config to build it ("" for the default)
 * @return {Page} a 404 page explaining how to build that section
 */
export func sectionMissing(title as string, root as string, config as string) {
    def flag as string init "";
    if (not ($config == "")) {
        $flag = " --config " + esc($config);
    }
    def body as string init '<h1>' + esc($title) +
        ' not built</h1>
<p class="lede">The site serves this section from <code>' + esc($root) +
        '/</code>, which this deployment does not have yet. Build it with:</p>
<pre><code>docker run --rm --user "$(id -u):$(id -g)" \\
    -v "$PWD:/work" ghcr.io/jennifer-language/grimoire build' + $flag +
        '</code></pre>
<p class="muted">The Markdown sources are in the repository either way.</p>';
    return Page{status: 404, body: layout($title + " not built", $body)};
}

/**
 * The tag index: a cloud, then every tag alphabetically.
 *
 * The cloud is weighted by how many decks carry each tag, in five size steps (a
 * linear scale makes one popular tag dominate); the list is complete and
 * scannable.
 * @param index {json.Value} the registry's deck index, from `search.index`
 * @return {Page} a 200 page
 */
export func tags(index as json.Value) {
    def counts as map of string to int init tagCounts($index);
    def names as list of string init lists.sort(maps.keys($counts));
    if (len($names) == 0) {
        return Page{
            status: 200,
            body: layout(
                "Tags",
                '<h1>Tags</h1>' +
                    '<p class="lede">Decks can carry up to ' +
                    convert.toString(keywords.LIMIT) + ' keywords. None do yet.</p>' +
                    '<div class="empty">No tags in use.</div>')
        };
    }
    def most as int init 1;
    for (def name in $names) {
        if ($counts[$name] > $most) {
            $most = $counts[$name];
        }
    }
    def body as string init '<h1>Tags</h1><p class="lede">' +
        convert.toString(len($names)) + ' tags across the registry. A deck ' +
        'carries up to ' + convert.toString(keywords.LIMIT) + '.</p>';
    $body = $body + '<h2>Cloud</h2><p class="cloud">';
    for (def name in $names) {
        $body = $body +
            tagLink(
            $name,
            $counts[$name],
            'cloud-' + convert.toString(cloudStep($counts[$name], $most)));
    }
    $body = $body + '</p><h2>All tags</h2><ul class="taglist">';
    for (def name in $names) {
        $body = $body + '<li>' + tagLink($name, $counts[$name], "") + '</li>';
    }
    return Page{status: 200, body: layout("Tags", $body + '</ul>')};
}

# cloudStep buckets a count into 1..5 for the cloud's font size.
# Relative to the most-used tag, so the scale is independent of registry size.
func cloudStep(count as int, most as int) {
    if ($most < 2) {
        return 3;
    }
    def step as int init 1 + convert.toInt((($count - 1) * 4) / ($most - 1));
    if ($step > 5) {
        return 5;
    }
    return $step;
}

# tagLink renders one tag, with the number of decks carrying it.
func tagLink(name as string, count as int, extra as string) {
    def safe as string init esc($name);
    def classes as string init "tag";
    if (not ($extra == "")) {
        $classes = $classes + " " + $extra;
    }
    return '<a class="' + $classes + '" href="/tag/' + $safe + '">' + $safe +
        '<span class="count">' + convert.toString($count) + '</span></a>';
}

# tagCounts maps each tag in use to how many decks carry it.
# Only each deck's newest version counts, so a dropped keyword stops grouping
# the deck and a deck counts once, not once per release.
func tagCounts(index as json.Value) {
    def out as map of string to int init {};
    for (def i in lists.range(0, json.length($index, ""))) {
        for (def tag in search.keywordsAt($index, $i)) {
            if (maps.has($out, $tag)) {
                $out[$tag] = $out[$tag] + 1;
            } else {
                $out[$tag] = 1;
            }
        }
    }
    return $out;
}

# latestKeywords returns the newest version's keywords, or none.
func latestKeywords(db as flatdb.DB, name as string) {
    def all as list of string init store.listVersionsDescending($db, $name);
    if (len($all) == 0) {
        return [];
    }
    return store.versionKeywords($db, $name, $all[0]);
}

/**
 * One tag's page: every deck carrying it, a page at a time.
 * @param index {json.Value} the registry's deck index, from `search.index`
 * @param name {string} the tag
 * @param page {int} which page, 1-based
 * @return {Page} the tag page at 200, or a 404 page
 */
export func tag(index as json.Value, name as string, page as int) {
    def folded as string init keywords.fold($name);
    # A refused or malformed tag cannot have been stored; a 404 also avoids
    # echoing an arbitrary string into the page.
    if (not keywords.isWellFormed($folded) or keywords.isBlocked($folded)) {
        return notFound("That is not a tag used here.");
    }
    def found as list of int init search.tagged($index, $folded);
    if (len($found) == 0) {
        return notFound("No decks are tagged " + $folded + ".");
    }
    def safe as string init esc($folded);
    def body as string init '<h1>' + $safe + '</h1><p class="lede">' +
        convert.toString(len($found)) + ' deck(s) tagged <code>' + $safe +
        '</code>. <a href="/tags">All tags</a></p>' +
        pageOf($index, $found, $page, "/tag/" + $safe + "?", "");
    return Page{status: 200, body: layout($folded, $body)};
}
