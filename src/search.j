# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Deck search over the registry store. A registry of this size does not need an
 * index: a case-insensitive substring scan of the deck names and descriptions
 * is exact, has no build step to keep in sync, and stays correct as the store
 * changes underneath it. Swap it for a real index when the scan is measurably
 * too slow, not before.
 *
 * Pure over `store`, so the whole thing is testable without a server, and the
 * HTML and JSON views share one implementation.
 * @module search
 * @example
 * import "./search.j" as search;
 * def hits as list of search.Hit init search.find($db, "router");
 */

use strings;
use lists;
import "flatdb.j" as flatdb;
import "./store.j" as store;

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

# hitFor summarises one deck into a Hit.
#
# `latest` is the newest **live** version where there is one, because that is the
# version a reader would install. A deck whose every version is yanked still
# reports its newest, with `live` false to say what it is: hiding it would make
# the deck look unpublished rather than withdrawn.
func hitFor(db as flatdb.DB, name as string) {
    def all as list of string init store.listVersionsDescending($db, $name);
    def live as list of string init store.listLiveVersionsDescending($db, $name);
    def latest as string init "";
    if (len($live) > 0) {
        $latest = $live[0];
    } elseif (len($all) > 0) {
        $latest = $all[0];
    }
    return Hit{
        name: $name,
        description: store.deckDescription($db, $name),
        latest: $latest,
        versions: len($all),
        live: len($live) > 0
    };
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

/**
 * Find every deck whose name or description contains `query`,
 * case-insensitively. An **empty query matches every deck**, so one call backs
 * both the search results and the full listing on the landing page.
 *
 * Results are ordered with name matches before description-only matches, and
 * alphabetically within each group, so the likeliest target is first.
 * @param db {flatdb.DB} the registry to read
 * @param query {string} the search query ("" for everything)
 * @return {list of Hit} the matching decks, best first
 */
export func find(db as flatdb.DB, query as string) {
    def names as list of string init lists.sort(store.listDecks($db));
    def out as list of Hit init [];
    for (def name in $names) {
        if (matchesName($name, $query)) {
            $out[] = hitFor($db, $name);
        }
    }
    for (def name in $names) {
        if (not matchesName($name, $query)) {
            def hit as Hit init hitFor($db, $name);
            if (matchesDescription($hit.description, $query)) {
                $out[] = $hit;
            }
        }
    }
    return $out;
}
