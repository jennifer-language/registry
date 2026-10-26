# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Deck search over the registry store: a case-insensitive substring scan of
 * deck names and descriptions, with no text index.
 *
 * `index` builds a summary of each deck (newest live version, version count,
 * tags) once as a JSON list; `select` scans it. Building it sorts each deck's
 * versions, about 0.7 s at 5,000 decks, so the server keeps one index per
 * version of the file, shared by every reader like the store.
 *
 * A selection is a `list of int` of positions in the index, cheaper to keep and
 * slice than a JSON list. `entries` and `index` collect parts and convert them
 * once with `json.list`.
 *
 * Three derived values are built from the index once per version of the file
 * as well, so the pages that used to scan it per request do a lookup instead:
 * `lowered` (the search text of every entry, folded to lower case), `tagMap`
 * (tag to positions) and `scopeMap` (scope to positions). Measured at 5,000
 * decks: a scan took 13 to 44 ms, a lookup under a millisecond.
 *
 * Pure over `store`; the HTML and JSON views share it.
 * @module search
 * @example
 * import "./search.j" as search;
 * def index as json.Value init search.index($db);
 * def found as list of int init search.select($index, "router");
 * def hits as list of search.Hit init search.hits($index, $found, 0, 20);
 */

use strings;
use lists;
use maps;
use json;
use convert;
import "flatdb.j" as flatdb;
import "./store.j" as store;

/**
 * The longest query a search accepts, in characters. The results page echoes
 * the query, so without a bound a 1 MB request produced a 3 MB page.
 */
export def const MAX_QUERY as int init 200;

/**
 * One search result: a deck, summarised.
 * @field name {string} the deck name
 * @field description {string} the deck's description ("" when it has none)
 * @field latest {string} the newest live version, or the newest when every
 *     version is yanked ("" when none are published)
 * @field versions {int} how many versions are published
 * @field live {bool} whether any version is not yanked, so a listing does not
 *     present a version the resolver refuses as "latest"
 */
export def struct Hit {
    name as string,
    description as string,
    latest as string,
    versions as int,
    live as bool
};

# entryFor summarises one deck as an index entry: the Hit fields plus the
# newest version's keywords, which the tag pages group by.
#
# `latest` is the newest live version, the one a reader would install. A deck
# with every version yanked reports its newest with `live` false, so it reads
# as withdrawn rather than unpublished. Keywords come from the newest version
# whatever its state.
func entryFor(db as flatdb.DB, name as string) {
    # Sort once and filter the live versions from it; a second sort per deck
    # doubled the cost of every listing.
    def all as list of string init store.listVersionsDescending($db, $name);
    def live as list of string init [];
    for (def v in $all) {
        if (not store.isYanked($db, $name, $v)) {
            $live[] = $v;
        }
    }
    def latest as string init "";
    if (len($live) > 0) {
        $latest = $live[0];
    } elseif (len($all) > 0) {
        $latest = $all[0];
    }
    def tags as list of string init [];
    if (len($all) > 0) {
        $tags = store.versionKeywords($db, $name, $all[0]);
    }
    def out as json.Value init json.map();
    $out = json.set($out, "/name", $name);
    $out = json.set($out, "/description", store.deckDescription($db, $name));
    $out = json.set($out, "/latest", $latest);
    $out = json.set($out, "/versions", len($all));
    $out = json.set($out, "/live", len($live) > 0);
    return json.set($out, "/keywords", json.list($tags));
}

/**
 * Summarise every deck, ordered by name. Each entry has `name`, `description`,
 * `latest`, `versions`, `live` and `keywords`, the shape `GET /search` answers
 * with. Expensive: a server builds it once per version of the store.
 * @param db {flatdb.DB} the registry to read
 * @return {json.Value} a list of deck entries, alphabetical
 */
export func index(db as flatdb.DB) {
    def parts as list of json.Value init [];
    for (def name in lists.sort(store.listDecks($db))) {
        $parts[] = entryFor($db, $name);
    }
    return json.list($parts);
}

/**
 * Report whether a deck matches a query in its name. Case-insensitive; an empty
 * query matches everything.
 * @param name {string} the deck name
 * @param query {string} the search query
 * @return {bool} true when the name matches
 */
export func matchesName(name as string, query as string) {
    if (strings.trim($query) == "") {
        return true;
    }
    return strings.contains(strings.lower($name), strings.lower(strings.trim($query)));
}

/**
 * Report whether a deck matches a query in its description. Case-insensitive;
 * an empty query never matches, so the two ranks stay distinct.
 * @param description {string} the deck's description
 * @param query {string} the search query
 * @return {bool} true when the description matches
 */
export func matchesDescription(description as string, query as string) {
    def q as string init strings.trim($query);
    if ($q == "" or $description == "") {
        return false;
    }
    return strings.contains(strings.lower($description), strings.lower($q));
}

# at is the pointer to one entry of an index or a selection.
func at(i as int) {
    return "/" + convert.toString($i);
}

# ptrEscape encodes a key as one JSON Pointer token ("~" -> "~0", "/" -> "~1").
# Tags and scopes admit neither character, so this is belt and braces.
func ptrEscape(token as string) {
    def out as string init strings.replace($token, "~", "~0");
    return strings.replace($out, "/", "~1");
}

# SEP separates the lowered name from the lowered description in `lowered`.
# A query is never allowed to contain it, so a match cannot straddle the two.
def const SEP as string init "\n";

/**
 * The search text of every index entry, lower-cased once: the name, `SEP`, the
 * description, in index order. `selectIn` scans this instead of the entries.
 * @param index {json.Value} an index from `index`
 * @return {json.Value} a list of strings, one per entry
 */
export func lowered(index as json.Value) {
    def parts as list of string init [];
    for (def i in 0..json.length($index, "")) {
        def entry as json.Value init json.get($index, at($i));
        $parts[] = strings.lower(json.asString($entry, "/name")) + SEP +
            strings.lower(json.asString($entry, "/description"));
    }
    return json.list($parts);
}

/**
 * The positions whose name or description matches `query`, name matches first,
 * read from `lowered` rather than the entries. An empty query selects
 * everything in index order; a query carrying a newline selects nothing.
 * @param lowered {json.Value} from `lowered`
 * @param query {string} the search query
 * @return {list of int} positions in the index, best first
 */
export func selectIn(lowered as json.Value, query as string) {
    def total as int init json.length($lowered, "");
    def q as string init strings.lower(strings.trim($query));
    if ($q == "") {
        return lists.range(0, $total);
    }
    def byName as list of int init [];
    def byDescription as list of int init [];
    if (strings.contains($q, SEP)) {
        return $byName;
    }
    for (def i in 0..$total) {
        def text as string init json.asString($lowered, at($i));
        def found as int init strings.indexOf($text, $q);
        if ($found < 0) {
            continue;
        }
        if ($found < strings.indexOf($text, SEP)) {
            $byName[] = $i;
        } else {
            $byDescription[] = $i;
        }
    }
    for (def i in $byDescription) {
        $byName[] = $i;
    }
    return $byName;
}

/**
 * Tag to the positions of the decks whose newest version carries it, in index
 * order. `json.length` of a member is the deck count the tag page shows.
 * @param index {json.Value} an index from `index`
 * @return {json.Value} an object of tag to list of positions
 */
export func tagMap(index as json.Value) {
    def groups as map of string to list of int init {};
    for (def i in 0..json.length($index, "")) {
        for (def tag in keywordsAt($index, $i)) {
            if (not maps.has($groups, $tag)) {
                def none as list of int init [];
                $groups[$tag] = $none;
            }
            $groups[$tag][] = $i;
        }
    }
    return groupsJson($groups);
}

/**
 * Scope (without its "@") to the positions of the decks under it, in index
 * order. A bare name belongs to no scope.
 * @param index {json.Value} an index from `index`
 * @return {json.Value} an object of scope to list of positions
 */
export func scopeMap(index as json.Value) {
    def groups as map of string to list of int init {};
    for (def i in 0..json.length($index, "")) {
        def name as string init json.asString($index, at($i) + "/name");
        def slash as int init strings.indexOf($name, "/");
        if (not strings.startsWith($name, "@") or $slash < 0) {
            continue;
        }
        def scope as string init strings.substring($name, 1, $slash);
        if (not maps.has($groups, $scope)) {
            def none as list of int init [];
            $groups[$scope] = $none;
        }
        $groups[$scope][] = $i;
    }
    return groupsJson($groups);
}

# groupsJson converts a map of positions into a JSON object of lists.
func groupsJson(groups as map of string to list of int) {
    def out as json.Value init json.map();
    for (def key in $groups) {
        $out = json.set($out, "/" + ptrEscape($key), json.list($groups[$key]));
    }
    return $out;
}

/**
 * The positions filed under `key` in a `tagMap` or `scopeMap`, or none.
 * @param groups {json.Value} from `tagMap` or `scopeMap`
 * @param key {string} the tag, or the scope without its "@"
 * @return {list of int} positions in the index
 */
export func positionsIn(groups as json.Value, key as string) {
    def out as list of int init [];
    def ptr as string init "/" + ptrEscape($key);
    if (not json.has($groups, $ptr)) {
        return $out;
    }
    for (def k in 0..json.length($groups, $ptr)) {
        $out[] = json.asInt($groups, $ptr + at($k));
    }
    return $out;
}

/**
 * How many positions each key of a `tagMap` or `scopeMap` holds.
 * @param groups {json.Value} from `tagMap` or `scopeMap`
 * @return {map of string to int} key to count
 */
export func countsIn(groups as json.Value) {
    def out as map of string to int init {};
    for (def key in json.keys($groups, "")) {
        $out[$key] = json.length($groups, "/" + ptrEscape($key));
    }
    return $out;
}

/**
 * The positions of the entries whose name or description contains `query`,
 * case-insensitively. An empty query selects every deck. Name matches come
 * before description-only matches, each group in index (alphabetical) order.
 * @param index {json.Value} an index from `index`
 * @param query {string} the search query ("" for everything)
 * @return {list of int} positions in the index, best first
 */
export func select(index as json.Value, query as string) {
    # The scan the server replaces with `selectIn` over a shared `lowered`.
    def total as int init json.length($index, "");
    if (strings.trim($query) == "") {
        return lists.range(0, $total);
    }
    def byName as list of int init [];
    def byDescription as list of int init [];
    for (def i in 0..$total) {
        def entry as json.Value init json.get($index, at($i));
        if (matchesName(json.asString(json.get($entry, "/name")), $query)) {
            $byName[] = $i;
        } elseif (matchesDescription(json.asString(json.get($entry, "/description")), $query)) {
            $byDescription[] = $i;
        }
    }
    for (def i in $byDescription) {
        $byName[] = $i;
    }
    return $byName;
}

/**
 * The selected entries as one JSON list, in selection order.
 * @param index {json.Value} an index from `index`
 * @param positions {list of int} a selection from it
 * @return {json.Value} the entries
 */
export func entries(index as json.Value, positions as list of int) {
    def parts as list of json.Value init [];
    for (def i in $positions) {
        $parts[] = json.get($index, at($i));
    }
    return json.list($parts);
}

/**
 * One listing page as Hits: up to `count` selected entries from `from` on. Only
 * these are converted, so the cost is per page.
 * @param index {json.Value} an index from `index`
 * @param positions {list of int} a selection from it
 * @param from {int} the first of the selection to show, 0-based
 * @param count {int} how many at most
 * @return {list of Hit} the entries as Hits
 */
export func hits(index as json.Value, positions as list of int, from as int, count as int) {
    def out as list of Hit init [];
    def i as int init $from;
    if ($i < 0) {
        $i = 0;
    }
    while ($i < len($positions) and $i < $from + $count) {
        def entry as json.Value init json.get($index, at($positions[$i]));
        $out[] = Hit{
            name: json.asString(json.get($entry, "/name")),
            description: json.asString(json.get($entry, "/description")),
            latest: json.asString(json.get($entry, "/latest")),
            versions: json.asInt(json.get($entry, "/versions")),
            live: json.asBool(json.get($entry, "/live"))
        };
        $i = $i + 1;
    }
    return $out;
}

/**
 * The newest version's keywords of the entry at `i`.
 * @param index {json.Value} an index from `index`
 * @param i {int} the entry's position
 * @return {list of string} its keywords, possibly none
 */
export func keywordsAt(index as json.Value, i as int) {
    def out as list of string init [];
    def ptr as string init at($i) + "/keywords";
    for (def k in 0..json.length($index, $ptr)) {
        $out[] = json.asString(json.get($index, $ptr + at($k)));
    }
    return $out;
}

/**
 * The positions of the decks whose newest version carries `tag`, in index order.
 * @param index {json.Value} an index from `index`
 * @param tag {string} the keyword, already folded
 * @return {list of int} positions in the index
 */
export func tagged(index as json.Value, tag as string) {
    def out as list of int init [];
    for (def i in 0..json.length($index, "")) {
        if (lists.contains(keywordsAt($index, $i), $tag)) {
            $out[] = $i;
        }
    }
    return $out;
}

/**
 * The positions of the decks under one scope, in index order.
 * @param index {json.Value} an index from `index`
 * @param scope {string} the scope, folded and without its "@"
 * @return {list of int} positions in the index
 */
export func under(index as json.Value, scope as string) {
    def prefix as string init "@" + $scope + "/";
    def out as list of int init [];
    for (def i in 0..json.length($index, "")) {
        if (strings.startsWith(json.asString(json.get($index, at($i) + "/name")), $prefix)) {
            $out[] = $i;
        }
    }
    return $out;
}

/**
 * Find every deck whose name or description contains `query`,
 * case-insensitively, as Hits: `select` over a fresh `index`. An empty query
 * matches every deck.
 * @param db {flatdb.DB} the registry to read
 * @param query {string} the search query ("" for everything)
 * @return {list of Hit} the matching decks, best first
 */
export func find(db as flatdb.DB, query as string) {
    def all as json.Value init index($db);
    def found as list of int init select($all, $query);
    return hits($all, $found, 0, len($found));
}
