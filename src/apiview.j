# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The deck-repository HTTP responses, as pure data. Each function maps a
 * registry (`store`) plus request inputs to a `Reply` - an HTTP status and a
 * `json.Value` body - with no dependency on the web engine, so the response
 * logic is unit-testable without booting a server. The thin handler layer in
 * `bin/serve` calls these and hands the result to `web.sendJson`. The endpoints
 * are the minimum the CLI needs: an index, a health check, a deck listing, a
 * deck record, a version record, and the resolve query the CLI uses to turn a
 * name + constraint into a fetch URL.
 * @module apiview
 * @example
 * import "./apiview.j" as apiview;
 * def reply as apiview.Reply init apiview.resolve($db, "ansi", "^1.2.0");
 * # web.sendJson($ctx, reply.status, reply.body);
 */

use json;
use strings;
use convert;
import "flatdb.j" as flatdb;
import "./store.j" as store;
import "./search.j" as search;
import "./deckcatalog.j" as deckcatalog;

# ptrEscape encodes a name as one JSON Pointer token ("~"->"~0", "/"->"~1") so a
# scoped root key like "@jennifer/routeros" reads as a single key.
func ptrEscape(token as string) {
    def out as string init strings.replace($token, "~", "~0");
    return strings.replace($out, "/", "~1");
}

# The service name and version reported by the index endpoint. SERVICE_NAME is
# also the `registry` label in the discovery document, so it is exported for the
# entry script to pass to `webapi.discovery`.
export def const SERVICE_NAME as string init "jennifer-registry";
def const SERVICE_VERSION as string init "0.1.0";

# The registry specification version this server implements. This tracks
# specs/specs-server.md, not the API major: a *document* can change shape
# without breaking an endpoint, and `apis[].version` is what carries the API
# major.
#
# It is a full SemVer string and it stays **below 1.0.0 until the registry is
# tagged 1.0.0**, at which point the specification is tagged 1.0.0 with it. That
# is what a leading zero is for: the document is still being reshaped, and
# saying so is more useful to a client implementer than a version number that
# looks settled. The specification and the server share the number from 1.0.0
# onward, so "which spec does this registry implement" has one answer.
export def const SPEC_VERSION as string init "0.2.0";

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
    return Reply{ status: $status, body: $body };
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
 * The index response: service identity plus the routes the repository exposes.
 * @return {Reply} a 200 reply describing the service
 */
export func index() {
    def endpoints as list of string init [
        "GET /health",
        "GET /decks",
        "GET /deck?name=<deck>",
        "GET /decks/:name",
        "GET /decks/:name/:version",
        "GET /resolve?name=<deck>&constraint=<range>",
        "GET /resolve-graph?roots=<json>"
    ];
    def body as json.Value init json.map();
    $body = json.set($body, "/service", SERVICE_NAME);
    $body = json.set($body, "/version", SERVICE_VERSION);
    $body = json.set($body, "/description", "deck repository for jennifer-lang");
    $body = json.set($body, "/endpoints", stringList($endpoints));
    return Reply{ status: 200, body: $body };
}

/**
 * The discovery document: which API versions this registry serves and which
 * optional operations it offers, so a client can verify compatibility before it
 * calls anything. Served at the fixed, unversioned
 * `/.well-known/jennifer-registry`, which is the one path a client may
 * hard-code; everything else hangs off the base paths advertised here.
 *
 * `base` is the document `webapi.discovery` derives from the route table, so the
 * advertised versions and features cannot drift from what is actually served.
 * Taking the base as an argument rather than building it keeps this module free
 * of any dependency on the web engine.
 *
 * The `auth` members are **whatever the caller supplies** - `provider`, `flow`,
 * and the endpoint URLs - so this module never learns which identity provider is
 * configured and a new one needs no change here.
 *
 * **An empty `authUrls` emits no `auth` object, and that is a meaningful
 * answer.** The specification makes the object optional and gives its absence a
 * meaning: this registry accepts no logins, so a client says so plainly instead
 * of guessing an endpoint. Advertising a provider without the endpoints behind
 * it would be the exact ambiguity discovery exists to prevent - a client would
 * learn that identity is GitHub and still have nowhere to send the exchange.
 *
 * The URLs are absolute paths used verbatim, which is the one exception to
 * prefixing requests with a version's base path (specification 4.1).
 * **`url` is what the registry calls itself**, and is omitted when a deployment
 * has not declared one. A registry usually cannot work its own address out: it
 * sees a listen address and a `Host` header, both of which describe how *this*
 * request arrived rather than what the registry is called. Behind a proxy, in a
 * container, or on a private network, those are routinely not the public name.
 * So it is configured, and its absence means "I do not know", which is honest -
 * a guess would be recorded in somebody's lockfile as this registry's identity.
 * @param base {json.Value} the document from `webapi.discovery`
 * @param canonicalUrl {string} the registry's public base URL ("" to omit)
 * @param authUrls {map of string to string} the `auth` members: `provider`,
 *     `flow`, `deviceUrl`, `tokenUrl`, `refreshUrl`; empty when the registry
 *     accepts no logins
 * @return {Reply} a 200 reply with the discovery document
 */
export func discovery(base as json.Value, canonicalUrl as string,
        authUrls as map of string to string) {
    def body as json.Value init $base;
    if (not (strings.trim($canonicalUrl) == "")) {
        $body = json.set($body, "/url", strings.trim($canonicalUrl));
    }
    if (len($authUrls) == 0) {
        return Reply{ status: 200, body: $body };
    }
    def auth as json.Value init json.map();
    for (def name in $authUrls) {
        $auth = json.set($auth, "/" + $name, $authUrls[$name]);
    }
    $body = json.set($body, "/auth", $auth);
    return Reply{ status: 200, body: $body };
}

/**
 * The health-check response.
 * @return {Reply} a 200 reply with `{ "status": "ok" }`
 */
export func health() {
    def body as json.Value init json.map();
    $body = json.set($body, "/status", "ok");
    return Reply{ status: 200, body: $body };
}

/**
 * The deck-listing response: every deck name in the registry.
 * @param db {flatdb.DB} the registry to read
 * @return {Reply} a 200 reply with `{ "decks": [names...] }`
 */
export func listDecks(db as flatdb.DB) {
    def body as json.Value init json.map();
    $body = json.set($body, "/decks", stringList(store.listDecks($db)));
    return Reply{ status: 200, body: $body };
}

/**
 * The search response: decks whose name or description matches `query`, best
 * first. An **empty query lists every deck**, so this is also the machine-
 * readable form of the landing page. Always a 200: no match is an empty list,
 * not an error.
 * @param db {flatdb.DB} the registry to read
 * @param query {string} the search query ("" for everything)
 * @return {Reply} a 200 reply with `{ query, count, results }`
 */
export func search(db as flatdb.DB, query as string) {
    def hits as list of search.Hit init search.find($db, $query);
    def arr as json.Value init json.list();
    for (def hit in $hits) {
        def elem as json.Value init json.map();
        $elem = json.set($elem, "/name", $hit.name);
        $elem = json.set($elem, "/description", $hit.description);
        $elem = json.set($elem, "/latest", $hit.latest);
        $elem = json.set($elem, "/versions", $hit.versions);
        $arr = json.append($arr, "", $elem);
    }
    def body as json.Value init json.map();
    $body = json.set($body, "/query", $query);
    $body = json.set($body, "/count", len($hits));
    $body = json.set($body, "/results", $arr);
    return Reply{ status: 200, body: $body };
}

/**
 * A single deck's full record (name, description, versions), or 404 when the
 * deck is unknown.
 * @param db {flatdb.DB} the registry to read
 * @param name {string} the deck name
 * @return {Reply} the deck record at 200, or a 404 error reply
 */
export func getDeck(db as flatdb.DB, name as string) {
    if ($name == "") {
        return errorReply(400, "missing deck name");
    }
    if (not store.hasDeck($db, $name)) {
        return errorReply(404, "no such deck: " + $name);
    }
    return Reply{ status: 200, body: store.getDeckJson($db, $name) };
}

/**
 * A single deck version's record, or 404 when the deck or version is unknown.
 * @param db {flatdb.DB} the registry to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {Reply} the version record at 200, or a 404 error reply
 */
export func getVersion(db as flatdb.DB, name as string, version as string) {
    if ($name == "" or $version == "") {
        return errorReply(400, "missing deck name or version");
    }
    if (not store.hasVersion($db, $name, $version)) {
        return errorReply(404, "no such version: " + $name + "@" + $version);
    }
    return Reply{ status: 200, body: store.getVersionJson($db, $name, $version) };
}

/**
 * The resolve query the CLI uses: given a deck name and a version constraint
 * (empty constraint means "*"), return the best matching version and how to
 * fetch it. On success the body is
 * `{ found, name, version, kind, url, ref, commit, checksum, description }`,
 * where `ref` / `commit` pin a `git` version and `checksum` pins a `tar.gz`
 * one (the pair the kind does not use is empty); when nothing matches it is a
 * 404 with `{ found: false, name, error }`.
 * @param db {flatdb.DB} the registry to read
 * @param name {string} the deck name
 * @param constraintExpr {string} the version constraint ("" is treated as "*")
 * @return {Reply} the resolution at 200, or a 404 not-found reply
 */
export func resolve(db as flatdb.DB, name as string, constraintExpr as string) {
    if ($name == "") {
        return errorReply(400, "missing 'name' query parameter");
    }
    def expr as string init $constraintExpr;
    if ($expr == "") {
        $expr = "*";
    }
    def r as store.Resolution init store.resolve($db, $name, $expr);
    if (not $r.found) {
        def miss as json.Value init json.map();
        $miss = json.set($miss, "/found", false);
        $miss = json.set($miss, "/name", $name);
        $miss = json.set($miss, "/error", "no version of " + $name + " satisfies " + $expr);
        return Reply{ status: 404, body: $miss };
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
    return Reply{ status: 200, body: $body };
}

/**
 * The transitive-resolve query the CLI uses at install: `rootsJson` is a JSON
 * object of root requirements (deck name -> constraint). Returns the flattened,
 * version-locked graph as `{ ok: true, resolved: [ {name, version, kind, url,
 * ref, commit, checksum, engines, capabilities, description}, ... ] }`, or
 * `{ ok: false, error }` when the graph cannot be satisfied. A malformed
 * `roots` object is a 400.
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
    def g as deckcatalog.GraphResult init deckcatalog.resolveGraph($db, $roots);
    def body as json.Value init json.map();
    if (not $g.ok) {
        $body = json.set($body, "/ok", false);
        $body = json.set($body, "/error", $g.error);
        return Reply{ status: 200, body: $body };
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
    return Reply{ status: 200, body: $body };
}

/**
 * The API major a request path is asking for, or 0 when it names none.
 *
 * Only a leading `/v<digits>/` segment counts. `/v1/decks` is version 1;
 * `/deck` is the unversioned root alias; `/version` and `/v1x/y` are not
 * version segments at all, and reading them as one would turn an ordinary
 * 404 into a confusing complaint about protocol versions.
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
    return convert.toInt($digits);
}

/**
 * The `400` for a path under an API version this registry does not serve
 * (specification 4.5).
 *
 * A bare `404` here is indistinguishable from a missing deck, which sends the
 * user looking for a typo in a name when the real problem is that their client
 * is newer or older than the registry. `status` 0 means the path is not a
 * version mismatch and the caller should carry on with its own handling.
 * @param path {string} the request path
 * @param supported {list of int} the majors this registry serves
 * @return {Reply} a 400 naming the supported versions, or status 0
 */
export func unsupportedVersion(path as string, supported as list of int) {
    def asked as int init versionOfPath($path);
    if ($asked == 0) {
        return Reply{ status: 0, body: json.map() };
    }
    for (def v in $supported) {
        if ($v == $asked) {
            return Reply{ status: 0, body: json.map() };
        }
    }
    def body as json.Value init json.map();
    $body = json.set($body, "/error", "unsupported API version");
    def majors as json.Value init json.list();
    for (def v in $supported) {
        $majors = json.append($majors, "", $v);
    }
    $body = json.set($body, "/apis", $majors);
    return Reply{ status: 400, body: $body };
}
