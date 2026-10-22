# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Deck search over the registry store: a case-insensitive substring scan of the
 * deck names and descriptions, which is exact and needs no text index.
 *
 * What does need building once is the **summary** of each deck the scan and
 * every listing show: its newest live version, how many it has, its tags. That
 * means sorting each deck's versions, which at 5,000 decks was about 0.9 s of
 * every search, browse, tag and scope page. `index` builds the summaries once
 * as a JSON list, `select` scans it, and the server keeps one index per version
 * of the file, shared by every reader the way the store itself is.
 *
 * A selection is a `list of int`, positions in the index, which is cheaper to
 * keep and slice than a JSON list. Where a JSON list is needed, `entries` and
 * `index` collect the parts and convert them once with `json.list`.
 *
 * Pure over `store`, so the whole thing is testable without a server, and the
 * HTML and JSON views share one implementation.
 * @module search
 * @example
 * import "./search.j" as search;
 * def index as json.Value init search.index($db);
 * def found as list of int init search.select($index, "router");
 * def hits as list of search.Hit init search.hits($index, $found, 0, 20);
 */

use strings;
use lists;
use json;
use convert;
import "flatdb.j" as flatdb;
import "./store.j" as store;

/**
 * The longest query a search accepts, in characters. A query is echoed back on
 * the results page, so an unbounded one turned a 1 MB request into a 3 MB page.
 */
export def const MAX_QUERY as int init 200;

/**
 * One search result: a deck, summarised.
 * @field name {string} the deck name
 * @field description {string} the deck's description ("" when it has none)
 * @field latest {string} the highest published version ("" when none are)
 * @field versions {int} how many versions are published
 * @field live {bool} whether any version is installable, i.e. not yanked. A
 *     listing that shows a yanked version as a deck's "latest" is telling a
 *     reader the opposite of what a resolver will do with it.
 */
export def struct Hit {
    name as string,
    description as string,
    latest as string,
    versions as int,
    live as bool
};

# entryFor summarises one deck as an index entry: the Hit fields, plus the
# newest version's keywords, which the tag pages group by.
#
# `latest` is the newest **live** version where there is one, because that is the
# version a reader would install. A deck whose every version is yanked still
# reports its newest, with `live` false to say what it is: hiding it would make
# the deck look unpublished rather than withdrawn. The keywords come from the
# newest version whatever its state, because a tag describes what a deck is now.
func entryFor(db as flatdb.DB, name as string) {
    # One sort, and the live versions filtered out of it: the order is the same,
    # and sorting twice per deck doubled the cost of every listing.
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
 * Summarise every deck, ordered by name: the list every listing and search
 * reads. Each entry is an object with `name`, `description`, `latest`,
 * `versions`, `live` and `keywords`, the shape `GET /search` answers with.
 *
 * This is the expensive step, so a caller serving many requests builds it once
 * per version of the store and passes it around; see `select`.
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
 * an empty query does not count as a description match, so the two ranks stay
 * distinct when everything matches.
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

/**
 * The positions of the entries whose name or description contains `query`,
 * case-insensitively. An **empty query selects every deck**.
 *
 * Name matches come before description-only matches, alphabetically within each
 * group because the index is, so the likeliest target is first.
 * @param index {json.Value} an index from `index`
 * @param query {string} the search query ("" for everything)
 * @return {list of int} positions in the index, best first
 */
export func select(index as json.Value, query as string) {
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
 * The selected entries as one JSON list, in selection order: what a JSON reply
 * carries.
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
 * The entries one listing page shows, as Hits: `count` of the selected ones from
 * `from` on, fewer at the end. Only these are converted, so a page of a large
 * listing costs the page, not the listing.
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
 * case-insensitively, as Hits: `select` over a fresh `index`, for a caller with
 * one store and one question. An **empty query matches every deck**.
 * @param db {flatdb.DB} the registry to read
 * @param query {string} the search query ("" for everything)
 * @return {list of Hit} the matching decks, best first
 */
export func find(db as flatdb.DB, query as string) {
    def all as json.Value init index($db);
    def found as list of int init select($all, $query);
    return hits($all, $found, 0, len($found));
}
