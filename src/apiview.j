# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The registry's JSON responses as pure data. Each function maps a registry
 * (`store`) plus request inputs to a `Reply` (HTTP status and `json.Value`
 * body), with no dependency on the web engine. `bin/serve` hands the result to
 * `webapi.sendJson`. The endpoints: index, health, deck listing, deck record,
 * version record, search, discovery, and the resolve queries.
 * @module apiview
 * @example
 * import "./apiview.j" as apiview;
 * def reply as apiview.Reply init apiview.resolve($db, "ansi", "^1.2.0");
 * # webapi.sendJson($ctx, $reply.status, $reply.body);
 */

use json;
use strings;
use convert;
use maps;
use lists;
import "flatdb.j" as flatdb;
import "./store.j" as store;
import "./search.j" as search;
import "./deckcatalog.j" as deckcatalog;
import "./constraint.j" as constraint;
import "./deckname.j" as deckname;

# The most roots one `/resolve-graph` request may name, so one anonymous request
# cannot ask for the whole registry.
export def const MAX_GRAPH_ROOTS as int init 64;

# ptrEscape encodes a name as one JSON Pointer token ("~"->"~0", "/"->"~1") so a
# scoped root key like "@jennifer/routeros" reads as a single key.
func ptrEscape(token as string) {
    def out as string init strings.replace($token, "~", "~0");
    return strings.replace($out, "/", "~1");
}

# The service name and version reported by the index endpoint. SERVICE_NAME is
# exported because it is also the discovery document's `registry` label.
export def const SERVICE_NAME as string init "jennifer-registry";
def const SERVICE_VERSION as string init "0.1.0";

# The version of specs/specs-server.md this server implements, a SemVer string.
# It is separate from the API major (`apis[].version`): the document can change
# shape without breaking an endpoint. It stays below 1.0.0 until the registry is
# tagged 1.0.0; both are then tagged 1.0.0 together and move in step.
export def const SPEC_VERSION as string init "0.1.0";

/**
 * An HTTP response as pure data: a status code and a JSON body.
 * @field status {int} the HTTP status code
 * @field body {json.Value} the JSON response body
 */
export def struct Reply {
    status as int,
    body as json.Value
};

# errorReply builds a Reply with a JSON `{ "error": message }` body.
func errorReply(status as int, message as string) {
    def body as json.Value init json.map();
    $body = json.set($body, "/error", $message);
    return Reply{status: $status, body: $body};
}

# stringList builds a JSON array from a Jennifer list of string.
func stringList(items as list of string) {
    def out as json.Value init json.list();
    for (def item in $items) {
        $out = json.append($out, "", $item);
    }
    return $out;
}

/**
 * The index response: service identity plus every API route served, under
 * both `/v1` and the bare root.
 * @param authOn {bool} whether logins are configured, which adds the routes
 *     gated on them
 * @return {Reply} a 200 reply describing the service
 */
export func index(authOn as bool) {
    def endpoints as list of string init [
        "GET /health",
        "GET /decks",
        "GET /deck?name=<deck>",
        "GET /decks/:name",
        "GET /decks/:name/:version",
        "GET /resolve?name=<deck>&constraint=<range>",
        "GET /resolve-graph?roots=<json>",
        "GET /search?q=<query>",
        "GET /scopes",
        "POST /publish"
    ];
    if ($authOn) {
        def gated as list of string init [
            "POST /claim",
            "POST /owners",
            "POST /publishers",
            "POST /yank",
            "POST /unyank",
            "POST /auth/device",
            "POST /auth/token",
            "POST /auth/refresh"
        ];
        $endpoints = lists.concat($endpoints, $gated);
    }
    def body as json.Value init json.map();
    $body = json.set($body, "/service", SERVICE_NAME);
    $body = json.set($body, "/version", SERVICE_VERSION);
    $body = json.set($body, "/description", "deck repository for jennifer-lang");
    $body = json.set($body, "/endpoints", stringList($endpoints));
    return Reply{status: 200, body: $body};
}

# scopeList splits a space-separated scope string, dropping empty parts.
func scopeList(scopes as string) {
    def out as list of string init [];
    for (def part in strings.split($scopes, " ")) {
        if (not (strings.trim($part) == "")) {
            $out[] = strings.trim($part);
        }
    }
    return $out;
}

/**
 * The `auth.trustedPublishing` members of the discovery document (specification
 * 4.1, 8.9).
 * @field audience {string} the `aud` a CI job must request; "" when trusted
 *     publishing is off
 * @field providers {list of string} the accepted issuers, e.g. `github-actions`
 * @field url {string} where to present the token, an absolute path
 */
export def struct TrustedPublishing {
    audience as string,
    providers as list of string,
    url as string
};

/**
 * The discovery document: the API versions and optional operations this
 * registry serves. Served at the fixed, unversioned
 * `/.well-known/jennifer-registry`, the one path a client may hard-code.
 *
 * `base` is the document `webapi.discovery` derives from the route table, so
 * the advertised versions and features match what is served; taking it as an
 * argument keeps this module independent of the web engine.
 *
 * The `auth` members (`provider`, `flow`, endpoint URLs) are copied from the
 * caller, so a new identity provider needs no change here. An empty `authUrls`
 * emits no `auth` object, which the specification defines as "accepts no
 * logins"; a provider without its endpoints would leave a client nowhere to
 * send the exchange.
 *
 * The URLs are absolute paths used verbatim, the one exception to prefixing
 * requests with a version's base path (specification 4.1). `url` is the
 * registry's configured public name, omitted when none is declared: the listen
 * address and `Host` header describe how a request arrived, not the public
 * name, and a guess would be recorded in lockfiles as the registry's identity.
 * @param base {json.Value} the document from `webapi.discovery`
 * @param canonicalUrl {string} the registry's public base URL ("" to omit)
 * @param authUrls {map of string to string} the `auth` members: `provider`,
 *     `flow`, `deviceUrl` or (`authcode`) `authorizeUrl`, `clientId` and `scopes`
 *     (space-separated, written as an array), `tokenUrl`, `refreshUrl`; empty when
 *     the registry accepts no logins
 * @param trusted {TrustedPublishing} the trusted-publishing members; an empty
 *     `audience` omits `auth.trustedPublishing`
 * @return {Reply} a 200 reply with the discovery document
 */
export func discovery(
    base as json.Value,
    canonicalUrl as string,
    authUrls as map of string to string,
    trusted as TrustedPublishing) {
    def body as json.Value init $base;
    if (not (strings.trim($canonicalUrl) == "")) {
        $body = json.set($body, "/url", strings.trim($canonicalUrl));
    }
    def tpOn as bool init not ($trusted.audience == "");
    if (len($authUrls) == 0 and not $tpOn) {
        return Reply{status: 200, body: $body};
    }
    def auth as json.Value init json.map();
    for (def name in $authUrls) {
        if ($name == "scopes") {
            # 12.2: an array, from the provider's space-separated form
            $auth = json.set($auth, "/scopes", stringList(scopeList($authUrls[$name])));
        } else {
            $auth = json.set($auth, "/" + $name, $authUrls[$name]);
        }
    }
    if ($tpOn) {
        def tp as json.Value init json.map();
        $tp = json.set($tp, "/audience", $trusted.audience);
        $tp = json.set($tp, "/providers", stringList($trusted.providers));
        $tp = json.set($tp, "/url", $trusted.url);
        $auth = json.set($auth, "/trustedPublishing", $tp);
    }
    $body = json.set($body, "/auth", $auth);
    return Reply{status: 200, body: $body};
}

/**
 * The health-check response.
 * @return {Reply} a 200 reply with `{ "status": "ok" }`
 */
export func health() {
    def body as json.Value init json.map();
    $body = json.set($body, "/status", "ok");
    return Reply{status: 200, body: $body};
}

/** Deck names per page of `GET /decks` (specification 5.2). */
export def const DECKS_PAGE_SIZE as int init 1000;

/**
 * The deck-listing response: one page of deck names, sorted.
 * @param db {flatdb.DB} the registry to read
 * @param page {int} the 1-based page; past the last one gives an empty list
 * @return {Reply} a 200 reply with `{ "decks": [...], "page", "pages", "total" }`
 */
export func listDecks(db as flatdb.DB, page as int) {
    return listDecksFrom(search.index($db), $page);
}

/**
 * The deck-listing response read from the deck index, which is already sorted,
 * so a page costs only its own entries. The server passes its shared index.
 * @param index {json.Value} the registry's deck index, from `search.index`
 * @param page {int} the 1-based page; past the last one gives an empty list
 * @return {Reply} a 200 reply with `{ "decks": [...], "page", "pages", "total" }`
 */
export func listDecksFrom(index as json.Value, page as int) {
    def total as int init json.length($index, "");
    def pages as int init convert.toInt(($total + DECKS_PAGE_SIZE - 1) / DECKS_PAGE_SIZE);
    if ($pages < 1) {
        $pages = 1;
    }
    def slice as list of string init [];
    def from as int init ($page - 1) * DECKS_PAGE_SIZE;
    if ($from < $total) {
        def upto as int init $from + DECKS_PAGE_SIZE;
        if ($upto > $total) {
            $upto = $total;
        }
        for (def i in $from..$upto) {
            $slice[] = json.asString($index, "/" + convert.toString($i) + "/name");
        }
    }
    def body as json.Value init json.map();
    $body = json.set($body, "/decks", stringList($slice));
    $body = json.set($body, "/page", $page);
    $body = json.set($body, "/pages", $pages);
    $body = json.set($body, "/total", $total);
    return Reply{status: 200, body: $body};
}

/**
 * The search response: decks whose name or description matches `query`, best
 * first. An empty query lists every deck. No match is a 200 with an empty
 * list; a query over `search.MAX_QUERY` characters is a 400.
 *
 * Each result is the index entry as it stands (`name`, `description`, `latest`,
 * `versions`, `live`, `keywords`).
 * @param index {json.Value} the registry's deck index, from `search.index`
 * @param query {string} the search query ("" for everything)
 * @return {Reply} a 200 reply with `{ query, count, results }`, or a 400
 */
export func search(index as json.Value, query as string) {
    return searchIn($index, search.lowered($index), $query);
}

/**
 * The search response from a prebuilt `search.lowered`, which the server shares
 * between requests instead of lower-casing every entry per query.
 * @param index {json.Value} the registry's deck index, from `search.index`
 * @param lowered {json.Value} from `search.lowered` over that index
 * @param query {string} the search query ("" for everything)
 * @return {Reply} a 200 reply with `{ query, count, results }`, or a 400
 */
export func searchIn(index as json.Value, lowered as json.Value, query as string) {
    if (len($query) > search.MAX_QUERY) {
        return errorReply(
            400,
            "query longer than " + convert.toString(search.MAX_QUERY) +
                " characters");
    }
    def found as list of int init search.selectIn($lowered, $query);
    # everything, in index order: the index itself is the answer, uncopied
    def results as json.Value init $index;
    if (not (strings.trim($query) == "")) {
        $results = search.entries($index, $found);
    }
    def body as json.Value init json.map();
    $body = json.set($body, "/query", $query);
    $body = json.set($body, "/count", len($found));
    $body = json.set($body, "/results", $results);
    return Reply{status: 200, body: $body};
}

/**
 * A single deck's full record (name, description, versions), 404 when the deck
 * is unknown, 400 when no name is given.
 * @param db {flatdb.DB} the registry to read
 * @param name {string} the deck name
 * @return {Reply} the deck record at 200, or a 404 or 400 error reply
 */
export func getDeck(db as flatdb.DB, name as string) {
    if ($name == "") {
        return errorReply(400, "missing deck name");
    }
    if (not store.hasDeck($db, $name)) {
        return errorReply(404, "no such deck: " + $name);
    }
    return Reply{status: 200, body: store.getDeckJson($db, $name)};
}

/**
 * A single deck version's record, 404 when the deck or version is unknown, 400
 * when either is missing.
 * @param db {flatdb.DB} the registry to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {Reply} the version record at 200, or a 404 or 400 error reply
 */
export func getVersion(db as flatdb.DB, name as string, version as string) {
    if ($name == "" or $version == "") {
        return errorReply(400, "missing deck name or version");
    }
    if (not store.hasVersion($db, $name, $version)) {
        return errorReply(404, "no such version: " + $name + "@" + $version);
    }
    return Reply{status: 200, body: store.getVersionJson($db, $name, $version)};
}

/**
 * The resolve query the CLI uses: given a deck name and a version constraint
 * (empty constraint means "*"), return the best matching version and how to
 * fetch it. On success the body is
 * `{ found, name, version, kind, url, ref, commit, checksum, description }`,
 * where `ref` / `commit` pin a `git` version and `checksum` pins a `tar.gz`
 * one (the pair the kind does not use is empty); when nothing matches it is a
 * 404 with `{ found: false, name, error }`. A missing name or a constraint
 * outside the grammar is a 400 with `{ error }`.
 * @param db {flatdb.DB} the registry to read
 * @param name {string} the deck name
 * @param constraintExpr {string} the version constraint ("" is treated as "*")
 * @return {Reply} the resolution at 200, a 404 not-found reply, or a 400
 */
export func resolve(db as flatdb.DB, name as string, constraintExpr as string) {
    if ($name == "") {
        return errorReply(400, "missing 'name' query parameter");
    }
    def expr as string init $constraintExpr;
    if ($expr == "") {
        $expr = "*";
    }
    # A constraint outside the grammar is a malformed request (400), not a 404.
    if (not constraint.isValidConstraint($expr)) {
        return errorReply(400, "not a valid version constraint: " + $expr);
    }
    def r as store.Resolution init store.resolve($db, $name, $expr);
    if (not $r.found) {
        def miss as json.Value init json.map();
        $miss = json.set($miss, "/found", false);
        $miss = json.set($miss, "/name", $name);
        $miss = json.set($miss, "/error", "no version of " + $name + " satisfies " + $expr);
        return Reply{status: 404, body: $miss};
    }
    def body as json.Value init json.map();
    $body = json.set($body, "/found", true);
    $body = json.set($body, "/name", $r.name);
    $body = json.set($body, "/version", $r.version);
    $body = json.set($body, "/kind", $r.kind);
    $body = json.set($body, "/url", $r.url);
    $body = json.set($body, "/ref", $r.ref);
    $body = json.set($body, "/commit", $r.commit);
    $body = json.set($body, "/checksum", $r.checksum);
    $body = json.set($body, "/description", $r.description);
    return Reply{status: 200, body: $body};
}

/**
 * The transitive-resolve query the CLI uses at install: `rootsJson` is a JSON
 * object of root requirements (deck name -> constraint). Returns the flattened,
 * version-locked graph as `{ ok: true, resolved: [ {name, version, kind, url,
 * ref, commit, checksum, engines, capabilities, description}, ... ] }`, or
 * `{ ok: false, error }` (still a 200) when the graph cannot be satisfied. A
 * malformed `roots` object, or one `rootsProblem` refuses, is a 400.
 * @param db {flatdb.DB} the registry to read
 * @param rootsJson {string} a JSON object of name -> constraint
 * @return {Reply} the flattened resolution, or an error reply
 */
export func resolveGraph(db as flatdb.DB, rootsJson as string) {
    def roots as map of string to string init {};
    try {
        def doc as json.Value init json.decode($rootsJson);
        for (def key in json.keys($doc, "")) {
            $roots[$key] = json.asString($doc, "/" + ptrEscape($key));
        }
    } catch (err) {
        return errorReply(400, "invalid 'roots' JSON object");
    }
    def problem as string init rootsProblem($roots);
    if (not ($problem == "")) {
        return errorReply(400, $problem);
    }
    def g as deckcatalog.GraphResult init deckcatalog.resolveGraph($db, $roots);
    def body as json.Value init json.map();
    if (not $g.ok) {
        $body = json.set($body, "/ok", false);
        $body = json.set($body, "/error", $g.error);
        return Reply{status: 200, body: $body};
    }
    $body = json.set($body, "/ok", true);
    def arr as json.Value init json.list();
    for (def r in $g.resolved) {
        def elem as json.Value init json.map();
        $elem = json.set($elem, "/name", $r.name);
        $elem = json.set($elem, "/version", $r.version);
        $elem = json.set($elem, "/kind", $r.kind);
        $elem = json.set($elem, "/url", $r.url);
        $elem = json.set($elem, "/ref", $r.ref);
        $elem = json.set($elem, "/commit", $r.commit);
        $elem = json.set($elem, "/checksum", $r.checksum);
        def ej as json.Value init json.map();
        for (def eng in $r.engines) {
            $ej = json.set($ej, "/" + ptrEscape($eng), $r.engines[$eng]);
        }
        $elem = json.set($elem, "/engines", $ej);
        def cj as json.Value init json.list();
        for (def cap in $r.capabilities) {
            $cj = json.append($cj, "", $cap);
        }
        $elem = json.set($elem, "/capabilities", $cj);
        $elem = json.set($elem, "/description", $r.description);
        $arr = json.append($arr, "", $elem);
    }
    $body = json.set($body, "/resolved", $arr);
    return Reply{status: 200, body: $body};
}

/**
 * Why a set of resolution roots cannot be resolved as asked, or "". Pure.
 *
 * Refuses too many roots, invalid names, two spellings of one folded name
 * (they would resolve as two decks at two versions), and constraints outside
 * the grammar. The caller answers each with a `400`.
 * @param roots {map of string to string} deck name to constraint, as sent
 * @return {string} the complaint, or ""
 */
export func rootsProblem(roots as map of string to string) {
    if (len($roots) > MAX_GRAPH_ROOTS) {
        return "too many roots: at most " + convert.toString(MAX_GRAPH_ROOTS) +
            " may be resolved in one request";
    }
    def seen as map of string to bool init {};
    for (def name in $roots) {
        def folded as string init deckname.fold($name);
        if (not deckname.isValid($folded)) {
            return "not a valid deck name: " + $name;
        }
        if (maps.has($seen, $folded)) {
            return $name + " is named twice, under two spellings";
        }
        $seen[$folded] = true;
        if (not constraint.isValidConstraint($roots[$name])) {
            return "not a valid version constraint for " + $name + ": " + $roots[$name];
        }
    }
    return "";
}

/**
 * The API major a request path is asking for, or 0 when it names none.
 *
 * Only a leading `/v<digits>/` segment counts: `/v1/decks` is version 1;
 * `/deck`, `/version` and `/v1x/y` name none, so they stay ordinary 404s.
 * @param path {string} the request path
 * @return {int} the major asked for, or 0
 */
export func versionOfPath(path as string) {
    if (not strings.startsWith($path, "/v")) {
        return 0;
    }
    def rest as string init strings.substring($path, 2, len($path));
    def slash as int init strings.indexOf($rest, "/");
    def digits as string init $rest;
    if ($slash >= 0) {
        $digits = strings.substring($rest, 0, $slash);
    }
    if ($digits == "") {
        return 0;
    }
    for (def ch in strings.chars($digits)) {
        if ($ch < "0" or $ch > "9") {
            return 0;
        }
    }
    # Too long for an int; a never-supported major keeps it a 400, not a 500.
    if (len($digits) > 9) {
        return 999999999;
    }
    return convert.toInt($digits);
}

/**
 * The `400` for a path under an API version this registry does not serve
 * (specification 4.5).
 *
 * A `404` would be indistinguishable from a missing deck. `status` 0 means the
 * path is not a version mismatch and the caller carries on.
 * @param path {string} the request path
 * @param supported {list of int} the majors this registry serves
 * @return {Reply} a 400 naming the supported versions, or status 0
 */
export func unsupportedVersion(path as string, supported as list of int) {
    def asked as int init versionOfPath($path);
    if ($asked == 0) {
        return Reply{status: 0, body: json.map()};
    }
    for (def v in $supported) {
        if ($v == $asked) {
            return Reply{status: 0, body: json.map()};
        }
    }
    def body as json.Value init json.map();
    $body = json.set($body, "/error", "unsupported API version");
    def majors as json.Value init json.list();
    for (def v in $supported) {
        $majors = json.append($majors, "", $v);
    }
    $body = json.set($body, "/apis", $majors);
    return Reply{status: 400, body: $body};
}

/**
 * Whether a request may be answered `304` from a tag of the database alone,
 * before anything reads it (see `cacheTag`). Pure.
 *
 * Only pages and listings that are a function of the database qualify. The
 * three lookups that are counted (`GET /deck`, `GET /decks/:name`,
 * `GET /resolve`) are excluded, since a `304` would skip the count; so are
 * writes, the documentation books (served with their own validators), and
 * everything else.
 * @param method {string} the request method
 * @param path {string} the request path, with or without the `/v1` prefix
 * @return {bool} true when a matching tag may be answered with `304`
 */
export func isConditional(method as string, path as string) {
    if (not ($method == "GET" or $method == "HEAD")) {
        return false;
    }
    def p as string init $path;
    if (strings.startsWith($p, "/v1/")) {
        $p = strings.substring($p, 3, len($p));
    }
    for (def exact in ["/", "/browse", "/tags", "/search", "/decks", "/scopes", "/resolve-graph"]) {
        if ($p == $exact) {
            return true;
        }
    }
    for (def prefix in ["/deck/", "/tag/", "/scope/"]) {
        if (strings.startsWith($p, $prefix)) {
            return true;
        }
    }
    return false;
}

/**
 * The validator for a conditional read: the database file's size and change
 * time, the hour, and which representation was asked for. Pure.
 *
 * Every write changes the file, so any edit makes a new tag. The hour bounds
 * how stale the clock-relative counts on deck pages can be. The representation
 * is included because one URL serves both HTML and JSON.
 * @param sizeBytes {int} the database file's size
 * @param mtimeNanos {int} its modification time
 * @param now {int} the current time (Unix seconds)
 * @param kind {string} the representation, as `webapi.wants` names it
 * @return {string} the tag, unquoted
 */
export func cacheTag(sizeBytes as int, mtimeNanos as int, now as int, kind as string) {
    return convert.toString($sizeBytes) + "-" + convert.toString($mtimeNanos) + "-" +
        convert.toString($now // 3600) + "-" + $kind;
}

