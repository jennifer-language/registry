# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.28.0

/**
 * The feed of new and updated decks, as pure data: `GET /feed.atom` (Atom 1.0),
 * `GET /feed.rss` (RSS 2.0) and the same per scope (`/feed/@scope.atom`). One
 * item per published version that is not yanked, newest first.
 *
 * Three steps, so the server can answer a revalidation before it renders:
 *
 *   * `collect` turns the store into every item, sorted, once per change of the
 *     file (the server shares it like the search index);
 *   * `prepare` validates the request, picks the items (scope, time and count
 *     cuts) and computes the validators (`etag`, `lastModified`);
 *   * `render` builds the XML.
 *
 * The bundled `feed` module is not used: its Atom output has no feed `id` and
 * no `rel="self"` link, its RSS output no channel `description`, and it writes
 * an RSS item's author as `<author>`, which RSS 2.0 requires to be an email
 * address. All three fail the W3C feed validator. The XML is built here as
 * `xml` trees instead, so every value is escaped by the encoder.
 * @module feedview
 * @example
 * import "./feedview.j" as feedview;
 * def out as feedview.FeedReply init feedview.prepare($db, feedview.collect($db),
 *     "atom", "", "", $now, "https://registry.example");
 * def xml as string init feedview.render($out);
 */

use json;
use strings;
use convert;
use lists;
use time;
use xml;
use hash;
use encoding;
import "flatdb.j" as flatdb;
import "uri.j" as uri;
import "./store.j" as store;
import "./deckname.j" as deckname;
import "./webview.j" as webview;

/** The newest items a feed shows when `?limit=` is absent. */
export def const DEFAULT_LIMIT as int init 50;
/** The largest `?limit=` accepted. */
export def const MAX_LIMIT as int init 100;
/** The window, in days, a feed shows when `?days=` is absent. */
export def const DEFAULT_DAYS as int init 30;
/** The largest `?days=` accepted. */
export def const MAX_DAYS as int init 365;
/**
 * The fewest items a feed shows whatever their age (never more than the limit),
 * so a quiet registry's feed is not empty.
 */
export def const MIN_ITEMS as int init 10;
/** How long a cache may keep a feed, in seconds (`Cache-Control: max-age`). */
export def const MAX_AGE_SECONDS as int init 300;

/** The two formats, as `prepare` takes them. */
export def const ATOM as string init "atom";
export def const RSS as string init "rss";

def const DAY_SECONDS as int init 86400;
def const ATOM_NS as string init "http://www.w3.org/2005/Atom";
def const DC_NS as string init "http://purl.org/dc/elements/1.1/";
def const XML_DECLARATION as string init '<?xml version="1.0" encoding="utf-8"?>' + "\n";
def const REGISTRY_NAME as string init "Jennifer registry";
# Large enough that `INVERT - publishedAt` stays positive for any real time,
# padded to a fixed width so the sort keys compare as numbers.
def const INVERT as int init 99999999999;
def const KEY_DIGITS as int init 11;
def const VERSION_DIGITS as int init 10;

/**
 * One feed item: a published version that is not yanked.
 * @field name {string} the folded deck name
 * @field version {string} the version
 * @field scope {string} the folded scope without "@", "" for a bare name
 * @field publishedAt {int} when it was published (Unix seconds)
 * @field summary {string} the version's description, else the deck's
 * @field url {string} the recorded clone or artifact URL
 * @field first {bool} true for the deck's first published version ("new")
 */
export def struct Item {
    name as string,
    version as string,
    scope as string,
    publishedAt as int,
    summary as string,
    url as string,
    first as bool
};

/**
 * The validated query parameters. `status` is 200, or 400 with `message`.
 * @field status {int} 200 when valid, 400 otherwise
 * @field message {string} why the parameters were refused ("" when valid)
 * @field limit {int} the most items to show
 * @field days {int} the window, in days
 * @field query {string} the parameters as they are echoed in the self link
 *     ("" for the defaults, else "?limit=..&days=..")
 */
export def struct Params {
    status as int,
    message as string,
    limit as int,
    days as int,
    query as string
};

/**
 * A scoped feed's file name, `@scope.atom` or `@scope.rss`, taken apart.
 * @field ok {bool} true when the name has that shape and a legal scope
 * @field scope {string} the folded scope without "@"
 * @field format {string} ATOM or RSS
 */
export def struct ScopeFile {
    ok as bool,
    scope as string,
    format as string
};

/**
 * A feed request, answered up to the body: the status, the items, and the
 * validators. `render` builds the body from it.
 * @field status {int} 200, 400 (bad parameters) or 404 (unknown scope)
 * @field message {string} why it was refused ("" at 200)
 * @field format {string} ATOM or RSS
 * @field scope {string} the folded scope, "" for the whole registry
 * @field base {string} the registry's public base URL, without a trailing "/"
 * @field params {Params} the validated parameters
 * @field items {list of Item} the items to show, newest first
 * @field lastModified {int} when the feed last changed (Unix seconds; 0 when
 *     it has no items)
 * @field etag {string} the entity tag, unquoted
 * @field contentType {string} the media type to answer with
 */
export def struct FeedReply {
    status as int,
    message as string,
    format as string,
    scope as string,
    base as string,
    params as Params,
    items as list of Item,
    lastModified as int,
    etag as string,
    contentType as string
};

# ---- collecting ----

/**
 * Every published version that is not yanked, newest first, as a JSON list of
 * items (`name`, `version`, `scope`, `publishedAt`, `summary`, `url`, `first`).
 * Equal times are ordered by deck name, then version (numeric runs compared as
 * numbers), so the order is the same for the same store. A version whose
 * `publishedAt` is not a positive number of seconds has no place in a feed
 * ordered by time and is left out.
 *
 * `first` marks a deck's first published version (the earliest, yanked ones
 * included, so yanking a deck's first version does not turn its second into
 * a "new" deck). JSON rather than `Item` structs so the server can share one
 * copy between requests (`kv.setValue`).
 * @param db {flatdb.DB} the registry to read
 * @return {json.Value} the items, a JSON list
 */
export func collect(db as flatdb.DB) {
    def keys as list of string init [];
    def found as list of Item init [];
    for (def name in store.listDecks($db)) {
        def deck as json.Value init store.getDeckJson($db, $name);
        if (not json.has($deck, "/versions") or not (json.typeOf($deck, "/versions") == "map")) {
            continue;
        }
        def deckSummary as string init stringAt($deck, "/description");
        def folded as string init deckname.fold($name);
        def firstKey as string init "";
        def firstVersion as string init "";
        def live as list of Item init [];
        for (def v in json.keys($deck, "/versions")) {
            def rec as json.Value init json.get($deck, "/versions/" + deckname.ptrEscape($v));
            def at as int init secondsOf(stringAt($rec, "/publishedAt"));
            if ($at <= 0) {
                continue;
            }
            # The earliest: lowest time, then lowest version.
            def order as string init padded($at, KEY_DIGITS) + " " + versionKey($v);
            if ($firstKey == "" or $order < $firstKey) {
                $firstKey = $order;
                $firstVersion = $v;
            }
            if (json.has($rec, "/yanked") and json.typeOf($rec, "/yanked") == "bool" and
                json.asBool($rec, "/yanked")) {
                continue;
            }
            def summary as string init stringAt($rec, "/description");
            if ($summary == "") {
                $summary = $deckSummary;
            }
            $live[] = Item{
                name: $folded,
                version: $v,
                scope: deckname.scopeOf($folded),
                publishedAt: $at,
                summary: $summary,
                url: stringAt($rec, "/url"),
                first: false
            };
        }
        for (def it in $live) {
            $it.first = $it.version == $firstVersion;
            $keys[] = padded(INVERT - $it.publishedAt, KEY_DIGITS) + " " + $it.name + " " +
                versionKey($it.version) + " " + convert.toString(len($found));
            $found[] = $it;
        }
    }
    # Sorted as strings, each ending in its position: `lists.sort` takes no
    # callback, so nothing is copied per comparison.
    def out as json.Value init json.list();
    for (def key in lists.sort($keys)) {
        def at as int init convert.toInt($key[strings.lastIndexOf($key, " ") + 1..len($key)]);
        $out = json.append($out, "", itemJson($found[$at]));
    }
    return $out;
}

# stringAt reads an optional string member, "" when absent or not a string.
func stringAt(v as json.Value, pointer as string) {
    if (json.has($v, $pointer) and json.typeOf($v, $pointer) == "string") {
        return json.asString($v, $pointer);
    }
    return "";
}

# secondsOf reads `publishedAt`: decimal digits only, else 0 (left out).
func secondsOf(s as string) {
    if (len($s) == 0 or len($s) > KEY_DIGITS) {
        return 0;
    }
    for (def ch in strings.chars($s)) {
        if ($ch < "0" or $ch > "9") {
            return 0;
        }
    }
    return convert.toInt($s);
}

# padded writes a non-negative int with leading zeros to `width` digits.
func padded(n as int, width as int) {
    def s as string init convert.toString($n);
    while (len($s) < $width) {
        $s = "0" + $s;
    }
    return $s;
}

# versionKey makes versions sort by their numbers: each run of digits is padded
# to a fixed width, so "1.10.0" sorts after "1.9.0".
func versionKey(v as string) {
    def out as list of string init [];
    def digits as string init "";
    for (def ch in strings.chars($v)) {
        if ($ch >= "0" and $ch <= "9") {
            $digits = $digits + $ch;
            continue;
        }
        if (not ($digits == "")) {
            $out[] = padDigits($digits);
            $digits = "";
        }
        $out[] = $ch;
    }
    if (not ($digits == "")) {
        $out[] = padDigits($digits);
    }
    return strings.join($out, "");
}

# padDigits pads a digit run; one longer than the width is kept as is.
func padDigits(digits as string) {
    def s as string init $digits;
    while (len($s) < VERSION_DIGITS) {
        $s = "0" + $s;
    }
    return $s;
}

# itemJson is one item as a JSON object.
func itemJson(it as Item) {
    def out as json.Value init json.map();
    $out = json.set($out, "/name", $it.name);
    $out = json.set($out, "/version", $it.version);
    $out = json.set($out, "/scope", $it.scope);
    $out = json.set($out, "/publishedAt", $it.publishedAt);
    $out = json.set($out, "/summary", $it.summary);
    $out = json.set($out, "/url", $it.url);
    $out = json.set($out, "/first", $it.first);
    return $out;
}

# itemAt reads item `i` of a collected list.
func itemAt(items as json.Value, i as int) {
    def p as string init "/" + convert.toString($i);
    return Item{
        name: json.asString($items, $p + "/name"),
        version: json.asString($items, $p + "/version"),
        scope: json.asString($items, $p + "/scope"),
        publishedAt: json.asInt($items, $p + "/publishedAt"),
        summary: json.asString($items, $p + "/summary"),
        url: json.asString($items, $p + "/url"),
        first: json.asBool($items, $p + "/first")
    };
}

# ---- the request ----

/**
 * Validate the query string: `limit` (1 to `MAX_LIMIT`) and `days` (1 to
 * `MAX_DAYS`), each a plain decimal number without sign or leading zero, given
 * at most once. Anything else is a 400. Other parameters are ignored, so a
 * reader that adds its own (a cache buster) still gets the feed.
 * @param rawQuery {string} the query string as sent, without the "?"
 * @return {Params} the parameters, or a 400 with the reason
 */
export func params(rawQuery as string) {
    def out as Params init Params{
        status: 200,
        message: "",
        limit: DEFAULT_LIMIT,
        days: DEFAULT_DAYS,
        query: ""
    };
    def seen as list of string init [];
    if ($rawQuery == "") {
        return $out;
    }
    for (def pair in strings.split($rawQuery, "&")) {
        def eq as int init strings.indexOf($pair, "=");
        def key as string init $pair;
        def value as string init "";
        if ($eq >= 0) {
            $key = $pair[..$eq];
            $value = $pair[$eq + 1..len($pair)];
        }
        if (not ($key == "limit" or $key == "days")) {
            continue;
        }
        if (lists.contains($seen, $key)) {
            return refused($out, $key + " is given more than once");
        }
        $seen[] = $key;
        if ($key == "limit") {
            def n as int init boundedNumber($value, MAX_LIMIT);
            if ($n == 0) {
                return refused(
                    $out,
                    "limit must be a whole number from 1 to " + convert.toString(MAX_LIMIT));
            }
            $out.limit = $n;
        } else {
            def n as int init boundedNumber($value, MAX_DAYS);
            if ($n == 0) {
                return refused(
                    $out,
                    "days must be a whole number from 1 to " + convert.toString(MAX_DAYS));
            }
            $out.days = $n;
        }
    }
    def echoed as list of string init [];
    if (not ($out.limit == DEFAULT_LIMIT)) {
        $echoed[] = "limit=" + convert.toString($out.limit);
    }
    if (not ($out.days == DEFAULT_DAYS)) {
        $echoed[] = "days=" + convert.toString($out.days);
    }
    if (len($echoed) > 0) {
        $out.query = "?" + strings.join($echoed, "&");
    }
    return $out;
}

# refused turns parameters into a 400 with its reason.
func refused(p as Params, message as string) {
    $p.status = 400;
    $p.message = $message;
    return $p;
}

# boundedNumber reads 1..most written plainly (no sign, no leading zero, no
# space, no escape), or 0 for anything else.
func boundedNumber(s as string, most as int) {
    if (len($s) == 0 or len($s) > 3) {
        return 0;
    }
    def chars as list of string init strings.chars($s);
    if ($chars[0] == "0") {
        return 0;
    }
    for (def ch in $chars) {
        if ($ch < "0" or $ch > "9") {
            return 0;
        }
    }
    def n as int init convert.toInt($s);
    if ($n > $most) {
        return 0;
    }
    return $n;
}

/**
 * Take a scoped feed's file name apart: `@scope.atom` or `@scope.rss`, the
 * scope folded. Anything else is not ok.
 * @param file {string} the last path segment, as routed
 * @return {ScopeFile} the scope and format, or not ok
 */
export func scopeFile(file as string) {
    def out as ScopeFile init ScopeFile{ok: false, scope: "", format: ""};
    if (not strings.startsWith($file, "@")) {
        return $out;
    }
    def dot as int init strings.lastIndexOf($file, ".");
    if ($dot < 2) {
        return $out;
    }
    def format as string init $file[$dot + 1..len($file)];
    if (not ($format == ATOM or $format == RSS)) {
        return $out;
    }
    def scope as string init deckname.fold($file[1..$dot]);
    if (not deckname.isScopeIdent($scope)) {
        return $out;
    }
    $out.ok = true;
    $out.scope = $scope;
    $out.format = $format;
    return $out;
}

/**
 * Answer a feed request up to its body: validate the parameters, pick the
 * items and compute the validators. `render` builds the body.
 *
 * The items are those of `scope` ("" for every scope), newest first, cut to
 * those published within `days` of `now`, but never fewer than `MIN_ITEMS`
 * when there are that many, and never more than `limit`.
 *
 * `lastModified` is the newest item's time, or, when the window has since
 * pushed an older item out, the moment it did: the feed changed then too.
 * `etag` hashes the format and every item's id, time, kind and summary.
 * @param db {flatdb.DB} the registry, to tell an unknown scope from an empty one
 * @param items {json.Value} the items, from `collect`
 * @param format {string} ATOM or RSS
 * @param scope {string} the folded scope without "@", "" for the whole registry
 * @param rawQuery {string} the query string as sent
 * @param now {int} the current time (Unix seconds)
 * @param base {string} the registry's public base URL
 * @return {FeedReply} the reply: 200, 400 or 404
 */
export func prepare(
    db as flatdb.DB,
    items as json.Value,
    format as string,
    scope as string,
    rawQuery as string,
    now as int,
    base as string) {
    def p as Params init params($rawQuery);
    def empty as list of Item init [];
    def out as FeedReply init FeedReply{
        status: $p.status,
        message: $p.message,
        format: $format,
        scope: $scope,
        base: trimSlash($base),
        params: $p,
        items: $empty,
        lastModified: 0,
        etag: "",
        contentType: "application/atom+xml; charset=utf-8"
    };
    if ($format == RSS) {
        $out.contentType = "application/rss+xml; charset=utf-8";
    }
    if (not ($p.status == 200)) {
        return $out;
    }
    if (not ($scope == "") and not scopeKnown($db, $scope)) {
        $out.status = 404;
        $out.message = "no scope named @" + $scope + " is registered here";
        return $out;
    }
    def window as int init $p.days * DAY_SECONDS;
    def cutoff as int init $now - $window;
    def floor as int init MIN_ITEMS;
    if ($p.limit < $floor) {
        $floor = $p.limit;
    }
    def picked as list of Item init [];
    def next as int init -1;
    def total as int init json.length($items, "");
    for (def i in 0..$total) {
        def it as Item init itemAt($items, $i);
        if (not ($scope == "" or $it.scope == $scope)) {
            continue;
        }
        if (len($picked) >= $p.limit or ($it.publishedAt < $cutoff and len($picked) >= $floor)) {
            $next = $it.publishedAt;
            break;
        }
        $picked[] = $it;
    }
    $out.items = $picked;
    if (len($picked) > 0) {
        $out.lastModified = $picked[0].publishedAt;
    }
    # Cut by the window rather than the limit: the item that fell out of the
    # window changed the feed when it did.
    if ($next >= 0 and len($picked) < $p.limit and $next + $window > $out.lastModified) {
        $out.lastModified = $next + $window;
    }
    $out.etag = etagOf($out);
    return $out;
}

# scopeKnown reports whether a scope is registered or has decks.
func scopeKnown(db as flatdb.DB, scope as string) {
    if (store.hasNamespace($db, $scope)) {
        return true;
    }
    for (def name in store.listDecks($db)) {
        if (deckname.scopeOf($name) == $scope) {
            return true;
        }
    }
    return false;
}

# trimSlash drops trailing slashes from the base URL.
func trimSlash(s as string) {
    def out as string init strings.trim($s);
    while (strings.endsWith($out, "/")) {
        $out = $out[..len($out) - 1];
    }
    return $out;
}

# etagOf hashes what the body shows of each item, so equal tags mean equal
# feeds for one URL.
func etagOf(r as FeedReply) {
    def parts as list of string init [$r.format, convert.toString($r.lastModified)];
    for (def it in $r.items) {
        $parts[] = entryId($r.base, $it) + " " + convert.toString($it.publishedAt) + " " +
            kindOf($it) + " " + $it.summary;
    }
    def digest as bytes init hash.compute(
        "sha256",
        encoding.encode("utf-8", strings.join($parts, "\n")));
    return encoding.toText("hex", $digest)[..32];
}

# ---- conditional requests ----

/**
 * An instant as an HTTP date (RFC 9110 IMF-fixdate), for `Last-Modified`.
 * @param seconds {int} Unix seconds
 * @return {string} e.g. "Fri, 13 Nov 2026 23:27:33 GMT"
 */
export func httpDate(seconds as int) {
    return time.format(time.fromUnix($seconds), "%a, %d %b %Y %H:%M:%S GMT");
}

/**
 * Whether an `If-Modified-Since` header shows the client's copy is current: it
 * parses as an HTTP date no earlier than `lastModified`. An empty or malformed
 * header is not a match (RFC 9110 says to ignore it), and neither is a feed
 * with no items. The server consults it only when the request has no
 * `If-None-Match`, which takes precedence.
 * @param header {string} the header value ("" when absent)
 * @param lastModified {int} the feed's `lastModified`
 * @return {bool} true when a 304 may be answered
 */
export func unchangedSince(header as string, lastModified as int) {
    if ($header == "" or $lastModified <= 0) {
        return false;
    }
    def since as int init 0;
    try {
        $since = time.unix(time.parse(strings.trim($header), "%a, %d %b %Y %H:%M:%S GMT"));
    } catch (err) {
        return false;
    }
    return $since >= $lastModified;
}

# ---- rendering ----

/**
 * The feed document of a 200 reply, Atom 1.0 or RSS 2.0, with its XML
 * declaration. Every value goes into the tree as text or an attribute, so the
 * encoder escapes it; characters XML cannot carry at all (C0 controls other
 * than tab and line ends) are dropped.
 * @param r {FeedReply} a reply from `prepare` with status 200
 * @return {string} the document
 */
export func render(r as FeedReply) {
    if ($r.format == RSS) {
        return XML_DECLARATION + xml.encode(rssTree($r));
    }
    return XML_DECLARATION + xml.encode(atomTree($r));
}

# feedTitle names the feed.
func feedTitle(r as FeedReply) {
    if ($r.scope == "") {
        return REGISTRY_NAME + ": new and updated decks";
    }
    return "@" + $r.scope + " on the " + REGISTRY_NAME + ": new and updated decks";
}

# feedSubtitle says what the feed holds.
func feedSubtitle(r as FeedReply) {
    def where as string init "the " + REGISTRY_NAME;
    if (not ($r.scope == "")) {
        $where = "@" + $r.scope + " on the " + REGISTRY_NAME;
    }
    return "Every version published to " + $where + ", newest first. " +
        "A deck's first version is marked new, later ones updated.";
}

# homeOf is the page the feed is about: the site, or the scope's page.
func homeOf(r as FeedReply) {
    if ($r.scope == "") {
        return $r.base + "/";
    }
    return $r.base + "/scope/" + $r.scope;
}

# selfPath is the feed's own URL, with the parameters it was read with.
func selfOf(r as FeedReply) {
    def path as string init "/feed." + $r.format;
    if (not ($r.scope == "")) {
        $path = "/feed/@" + $r.scope + "." + $r.format;
    }
    return $r.base + $path + $r.params.query;
}

# feedId is the Atom feed's id: its URL without the parameters, which choose a
# view of the same feed.
func feedId(r as FeedReply) {
    def path as string init "/feed.atom";
    if (not ($r.scope == "")) {
        $path = "/feed/@" + $r.scope + ".atom";
    }
    return $r.base + $path;
}

/**
 * An item's title: `@scope/deck 1.2.0`.
 * @param it {Item} the item
 * @return {string} the title
 */
export func entryTitle(it as Item) {
    return $it.name + " " + $it.version;
}

/**
 * An item's link: the deck's page here, or for a bare name (which has none) its
 * repository, or failing that its JSON record.
 * @param base {string} the registry's public base URL
 * @param it {Item} the item
 * @return {string} the absolute URL
 */
export func entryLink(base as string, it as Item) {
    if (deckname.isScoped($it.name)) {
        return $base + "/deck/" + $it.scope + "/" + deckname.deckOf($it.name);
    }
    def repo as string init webview.repoLink($it.url);
    if (not ($repo == "")) {
        return $repo;
    }
    return $base + "/deck?name=" + uri.encode($it.name);
}

/**
 * An item's stable id, a `tag:` URI (RFC 4151) of the registry's host, the day
 * the version was published, and the deck and version:
 * `tag:registry.example,2026-11-13:@scope/deck/1.2.0`.
 * @param base {string} the registry's public base URL
 * @param it {Item} the item
 * @return {string} the id
 */
export func entryId(base as string, it as Item) {
    def day as string init time.format(time.fromUnix($it.publishedAt), "%Y-%m-%d");
    return "tag:" + hostOf($base) + "," + $day + ":" + $it.name + "/" + $it.version;
}

# hostOf is the host of a base URL, without scheme, port or path, lowercased.
func hostOf(base as string) {
    def host as string init $base;
    def scheme as int init strings.indexOf($host, "://");
    if ($scheme >= 0) {
        $host = $host[$scheme + 3..len($host)];
    }
    for (def stop in ["/", ":"]) {
        def at as int init strings.indexOf($host, $stop);
        if ($at >= 0) {
            $host = $host[..$at];
        }
    }
    return strings.lower($host);
}

/**
 * Whether an item is a deck's first version ("new") or a later one ("updated").
 * @param it {Item} the item
 * @return {string} "new" or "updated"
 */
export func kindOf(it as Item) {
    if ($it.first) {
        return "new";
    }
    return "updated";
}

# authorOf is an item's author: its scope, "" for a bare name.
func authorOf(it as Item) {
    if ($it.scope == "") {
        return "";
    }
    return "@" + $it.scope;
}

/**
 * Text as XML can carry it: C0 control characters other than tab, line feed
 * and carriage return, and U+FFFE / U+FFFF, are dropped. `xml` refuses them,
 * and a description is publisher input.
 * @param s {string} the text
 * @return {string} the text without them
 */
export func xmlSafe(s as string) {
    def out as list of string init [];
    def dropped as bool init false;
    for (def ch in strings.chars($s)) {
        if (($ch < " " and not ($ch == "\t" or $ch == "\n" or $ch == "\r")) or
            $ch == "￾" or $ch == "￿") {
            $dropped = true;
            continue;
        }
        $out[] = $ch;
    }
    if (not $dropped) {
        return $s;
    }
    return strings.join($out, "");
}

# textEl is an element holding one text child.
func textEl(tag as string, s as string) {
    return xml.setText(xml.element($tag), xmlSafe($s));
}

# linkEl is an Atom link element.
func linkEl(tag as string, rel as string, type as string, href as string) {
    def out as xml.Value init xml.element($tag);
    $out = xml.setAttr($out, "rel", $rel);
    if (not ($type == "")) {
        $out = xml.setAttr($out, "type", $type);
    }
    return xml.setAttr($out, "href", xmlSafe($href));
}

# atomTime is an instant in RFC 3339, UTC.
func atomTime(seconds as int) {
    return time.iso(time.fromUnix($seconds));
}

# rssTime is an instant in RFC 822 (with a four-digit year, as RSS 2.0 allows).
func rssTime(seconds as int) {
    return time.format(time.fromUnix($seconds), "%a, %d %b %Y %H:%M:%S +0000");
}

# atomTree builds the Atom 1.0 document.
func atomTree(r as FeedReply) {
    def root as xml.Value init xml.setAttr(xml.element("feed"), "xmlns", ATOM_NS);
    $root = xml.append($root, textEl("title", feedTitle($r)));
    $root = xml.append($root, textEl("subtitle", feedSubtitle($r)));
    $root = xml.append($root, linkEl("link", "alternate", "text/html", homeOf($r)));
    $root = xml.append($root, linkEl("link", "self", "application/atom+xml", selfOf($r)));
    $root = xml.append($root, textEl("id", feedId($r)));
    $root = xml.append($root, textEl("updated", atomTime($r.lastModified)));
    $root = xml.append($root, xml.append(xml.element("author"), textEl("name", REGISTRY_NAME)));
    for (def it in $r.items) {
        def entry as xml.Value init xml.element("entry");
        $entry = xml.append($entry, textEl("title", entryTitle($it)));
        $entry = xml.append(
            $entry,
            linkEl("link", "alternate", "text/html", entryLink($r.base, $it)));
        $entry = xml.append($entry, textEl("id", entryId($r.base, $it)));
        $entry = xml.append($entry, textEl("published", atomTime($it.publishedAt)));
        $entry = xml.append($entry, textEl("updated", atomTime($it.publishedAt)));
        def author as string init authorOf($it);
        if (not ($author == "")) {
            $entry = xml.append($entry, xml.append(xml.element("author"), textEl("name", $author)));
        }
        def kind as string init kindOf($it);
        def category as xml.Value init xml.setAttr(xml.element("category"), "term", $kind);
        $category = xml.setAttr($category, "label", categoryLabel($kind));
        $entry = xml.append($entry, $category);
        if (not ($it.summary == "")) {
            $entry = xml.append($entry, textEl("summary", $it.summary));
        }
        $root = xml.append($root, $entry);
    }
    return $root;
}

# categoryLabel is how a reader shows the kind.
func categoryLabel(kind as string) {
    if ($kind == "new") {
        return "New deck";
    }
    return "Updated deck";
}

# rssTree builds the RSS 2.0 document. The self link is Atom's (`atom:link`),
# as the RSS Advisory Board recommends, and the author is Dublin Core's
# `dc:creator`: RSS's own `<author>` must be an email address.
func rssTree(r as FeedReply) {
    def channel as xml.Value init xml.element("channel");
    $channel = xml.append($channel, textEl("title", feedTitle($r)));
    $channel = xml.append($channel, textEl("link", homeOf($r)));
    $channel = xml.append($channel, textEl("description", feedSubtitle($r)));
    $channel = xml.append($channel, linkEl("atom:link", "self", "application/rss+xml", selfOf($r)));
    if ($r.lastModified > 0) {
        $channel = xml.append($channel, textEl("lastBuildDate", rssTime($r.lastModified)));
    }
    for (def it in $r.items) {
        def item as xml.Value init xml.element("item");
        $item = xml.append($item, textEl("title", entryTitle($it)));
        $item = xml.append($item, textEl("link", entryLink($r.base, $it)));
        def guid as xml.Value init xml.setAttr(xml.element("guid"), "isPermaLink", "false");
        $item = xml.append($item, xml.setText($guid, xmlSafe(entryId($r.base, $it))));
        $item = xml.append($item, textEl("pubDate", rssTime($it.publishedAt)));
        def author as string init authorOf($it);
        if (not ($author == "")) {
            $item = xml.append($item, textEl("dc:creator", $author));
        }
        $item = xml.append($item, textEl("category", kindOf($it)));
        if (not ($it.summary == "")) {
            $item = xml.append($item, textEl("description", $it.summary));
        }
        $channel = xml.append($channel, $item);
    }
    def root as xml.Value init xml.setAttr(xml.element("rss"), "version", "2.0");
    $root = xml.setAttr($root, "xmlns:atom", ATOM_NS);
    $root = xml.setAttr($root, "xmlns:dc", DC_NS);
    return xml.append($root, $channel);
}
