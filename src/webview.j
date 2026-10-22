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
 * Every interpolated value goes through `esc`, because deck names and
 * descriptions are publisher input and end up inside markup, attributes included.
 * @module webview
 * @example
 * import "./webview.j" as webview;
 * def page as webview.Page init webview.deck($db, "@acme/routeros");
 * # web.html($ctx, page.status, page.body);
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
 * The Content-Security-Policy for every page this module renders. No script
 * runs but the theme switch, admitted by its hash, so a value that escapes its
 * escaping still cannot execute; nothing loads from elsewhere but images, which
 * a README may show from https; and no other site may frame a page.
 *
 * Styles stay `unsafe-inline`: the stylesheet is inline by design (one request
 * per page), and a style cannot run code.
 * @return {string} the header value
 */
export func contentSecurityPolicy() {
    def digest as bytes init hash.compute(convert.bytesFromString(THEME_SCRIPT, "utf-8"), "sha256");
    return "default-src 'none'; script-src 'sha256-" + encoding.toText($digest, "base64") +
        "'; style-src 'unsafe-inline'; img-src 'self' https: data:; " +
        "form-action 'self'; base-uri 'none'; frame-ancestors 'none'";
}

# esc escapes text for any place on a page, element content and quoted attribute
# values alike, which is why it must cover both quotes. `html.escape` does since
# 0.24.0-dev+167; before that it covered only `& < >`, and a search for
# `" autofocus onfocus=...` came back inside the search box's `value` attribute
# as live markup. Pages still call this one name, so the escaper stays one
# choice in one place, and `webview_test.j` asserts the quotes are covered.
func esc(s as string) {
    return html.escape($s);
}

# The site's stylesheet. Inline, so a page is one request and nothing is fetched
# from anywhere: no CDN, no font download, no build step. Colours are custom
# properties redefined under prefers-color-scheme, so dark mode is the same
# markup.
#
# The accent is orange, and the two themes take **different** oranges rather than
# one: a deep burnt orange has the contrast to be read as text on near-white,
# while a light warm orange is what reads on the dark ground. Each pairs with
# `--on-accent`, the colour of text placed *on* the accent - the search button is
# the only such surface, and hardcoding white there would leave black-on-white
# contrast in one theme and white-on-light-orange in the other.
# The theme switch. Kept to these few lines and inlined beside the stylesheet,
# so the page keeps its "one request, no CDN, no build step" property; what it
# gives up is the older claim that there is no JavaScript at all.
#
# It runs in `head`, before the body paints, because applying a stored choice
# afterwards shows the wrong theme for a frame. The `no-js` class is removed by
# the same script, which is what hides the switch when scripting is off: a button
# that cannot work is worse than no button, and the page still follows the system
# setting exactly as it did before.
#
# `light` and `dark` are the only stored values. Clearing the choice is not
# offered, because "follow my system" is what an unstamped page already does and
# a third state in a two-state control is a puzzle rather than a feature.
#
# The button is wired from here, by a listener on the document, rather than by an
# `onclick` attribute: the Content-Security-Policy admits this one script by its
# hash, and an inline handler would need `unsafe-inline`, which admits any
# script an injection manages to place in a page.
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
# escaped here, since it routinely carries a deck or scope name; `body` is markup
# this module built, with everything untrusted in it already escaped.
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
    # Joined once at the end: adding each item to a growing string re-copies all
    # of it, which made a listing of thousands of decks quadratic in its size.
    def items as list of string init [];
    for (def hit in $hits) {
        $items[] = hitItem($hit);
    }
    return '<ul class="decks">' + strings.join($items, "") + '</ul>';
}

/**
 * The landing page.
 *
 * It deliberately **does not list every deck**. A full listing is the right
 * front page for a registry with twenty decks and the wrong one for a registry
 * that succeeds: it grows without bound, it is the slowest page to render and
 * the heaviest to send, and it answers a question nobody arrives with. Somebody
 * landing here either knows what they want, in which case they want the search
 * box, or does not, in which case an alphabetical wall of names is not browsing.
 *
 * So the front door is: search, or one of two ways in - everything, or by tag.
 * The count is still here, because "how big is this registry" is a fair question
 * and one number answers it.
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
 * How many decks one page of a listing shows. Every listing is paged: a page of
 * all 5,000 decks of a large registry was 1.2 MB, and rendering it took about
 * 80 MB per request in flight.
 */
export def const PAGE_SIZE as int init 100;

/**
 * Turn a `page` query parameter into a page number: 1 for anything that is not
 * a small positive number, so a malformed link shows the first page rather than
 * an error. Past the last page is clamped where the listing is known.
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
 * The browse page: every deck, a page at a time, which is what the landing page
 * used to be.
 *
 * Kept as its own page rather than deleted, because "show me everything" is a
 * real request - it is just not the thing to greet somebody with.
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
 * The search results page. An empty query lists everything, which is what the
 * landing page shows, so a submitted empty box is not an error.
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
    # Live versions drive everything a reader might act on. The full list still
    # drives the table, because a yanked version is not hidden - it is labelled.
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
    # The licence and the source describe the version somebody would install, so
    # they come from the newest **live** one where there is one.
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

# yankNotice warns when the versions a reader would reach for are withdrawn.
#
# Silence here was the bug: a yanked version stopped satisfying resolutions and
# the page went on presenting it as the current release, so the registry told a
# browser one thing and a resolver another. Two cases are worth distinguishing,
# because the advice differs:
#
#   * **every** version yanked - there is nothing to install, and saying so is
#     the only honest thing the page can do;
#   * the **newest** yanked but older ones live - the deck is fine, the latest
#     release is not, and the reader needs to know the number below is not the
#     highest one on the page.
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
        # An older version was yanked and the newest is fine: the table says so
        # row by row and a banner would be noise.
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
 * **The heading says "Resolutions", not "Downloads", and the note under it says
 * why.** The registry never sees a download: a client fetches a deck's code
 * straight from its repository, so the only thing countable here is a client
 * asking where that repository is. Labelling that "downloads" would be a number
 * everyone would reasonably misread, and it would misread *high* on CI-heavy
 * decks and *low* on popular ones with stable lockfiles.
 *
 * A deck nobody has resolved yet renders nothing at all, rather than six zeroes.
 * A wall of zeroes on a day-old deck reads as failure; absence reads as new.
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
 * Two jobs, and the second is the one that matters. A clone URL ends in `.git`,
 * which most forges also serve as a browsable page but none of them show a human
 * that way, so the suffix comes off. And the URL is **publisher input** that
 * reaches this page from a manifest: only `http` and `https` are linked, so a
 * `javascript:` or `data:` URL recorded on a version becomes visible text rather
 * than a working link on this origin. Escaping alone would not do that, because
 * an escaped `javascript:` href still runs.
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
#
# Both answers were missing from this page entirely, which made it a dead end:
# somebody deciding whether to depend on a deck could not reach its source, and
# could not see who stands behind it. The two belong together because they are
# the same question asked twice - what is this, and who says so.
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
# The **login** is shown and the subject id is not, for the reason `listScopes`
# gives: an id is what ownership binds to, and publishing a list of them hands
# out exactly what an impersonation needs. A co-owner is counted, not named,
# because the store keeps co-owners as ids with no login recorded alongside -
# naming them would mean either showing an id or inventing a name.
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
 * A README is untrusted publisher input, and it is rendered with
 * `markdown.toHtml` alone, which is **safe by default**: raw HTML in the source
 * is escaped, and a link whose scheme is not http, https or mailto becomes `#`.
 * Never render one with `markdown.toHtmlWith`, which opts raw HTML back in.
 *
 * It used to be escaped with `html.escape` first, as a guard for interpreters
 * older than that default. That guard cost more than it bought: the renderer
 * escapes text again, so a code block showing `a < b` reached the reader as
 * `a &lt; b`, and quotes and alerts (`>`) stopped being markup. The tests now
 * carry the guarantee instead - an interpreter without safe defaults fails them
 * rather than serving a publisher's script.
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
        markdown.toHtml($source) + '</div>';
}

/**
 * A scope's page: who holds it, and every deck published under it.
 *
 * This is the other half of the deck page's "Published under" line. Without it,
 * an owner's name was a dead end - you could see that `@mplx` published a deck
 * and had no way to ask what else `@mplx` publishes, which is the obvious next
 * question and the one that makes a registry browsable rather than a lookup
 * table.
 *
 * A **registered but unowned** scope is a real state and gets its own answer:
 * reserved names are registered to nobody on purpose (`reserved.j`), so the page
 * says the name is held rather than pretending somebody holds it.
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
        # A reserved name: registered precisely so nobody can claim it, and bound
        # to nobody so nobody can publish under it.
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
 * The message is plain text and is escaped here, not by the caller: it routinely
 * carries the requested path or name, and a contract of "arrives escaped" was
 * forgotten once already, which made every HTML 404 a reflected XSS.
 * @param message {string} the explanation, as plain text
 * @return {Page} a 404 page
 */
export func notFound(message as string) {
    def body as string init '<h1>Not found</h1><p class="lede">' + esc($message) +
        '</p>' + searchForm("");
    return Page{status: 404, body: layout("Not found", $body)};
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
 * Two renderings of one list because they answer different questions. The cloud
 * is weighted by how many decks carry each tag, so it says *what this registry
 * is mostly for* at a glance - which is the question somebody who does not know
 * what they want actually has. The alphabetical list is for somebody who does
 * know, and it is complete and scannable in a way a cloud never is.
 *
 * The cloud is sized by count, in five steps rather than continuously: a linear
 * scale makes one popular tag enormous and everything else unreadable, and five
 * buckets keep the smallest tag legible while still showing the shape.
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
#
# Relative to the most-used tag rather than to an absolute number, so the cloud
# looks the same on a registry with ten decks and one with ten thousand.
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
#
# Read from each deck's **newest** version, because a tag describes what a deck
# is now: a keyword dropped two releases ago should stop grouping the deck, and
# summing every version would count a long-lived deck once per release.
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
    # A refused or malformed tag can never have been stored, so there is nothing
    # to look up and nothing to render: answering 404 keeps the registry from
    # echoing an arbitrary string back inside its own page at all.
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
