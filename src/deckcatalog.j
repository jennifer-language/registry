# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The adapter between the registry store and the shared resolver: it reads decks
 * out of a `flatdb`-backed `store` and adds them to a `catalog`, which is the
 * only thing `cli/resolver.j` knows how to read.
 *
 * The server resolves through exactly the same resolver the CLI does. It fills
 * the catalog **lazily**, seeding only the decks the resolver asks for, so a
 * `/resolve-graph` call costs one store read per deck in the graph rather than a
 * walk of the whole registry.
 * @module deckcatalog
 * @example
 * import "./deckcatalog.j" as deckcatalog;
 * def g as deckcatalog.GraphResult init deckcatalog.resolveGraph($db, {"ansi": "^1.2.0"});
 */

use maps;
use convert;
import "flatdb.j" as flatdb;
import "./store.j" as store;
import "./catalog.j" as catalog;
import "./resolver.j" as resolver;
import "./deckname.j" as deckname;

# The most decks one resolution may draw in. Without a bound, one anonymous
# request decides how much of the registry the server walks and re-resolves: a
# chain of decks published under a single scope made one `/resolve-graph` cost
# minutes of CPU. The resolver needs a round per level of a chain, so the worst
# case grows with this; at 256 it is about a second. A real dependency graph is
# a small fraction of it, and a wide one settles in a few rounds whatever its size.
export def const MAX_GRAPH_DECKS as int init 256;

/**
 * The outcome of a server-side transitive resolution. Re-exported from the
 * shared resolver so `apiview` does not need to import both modules.
 * @field ok {bool} true when the whole graph resolved
 * @field resolved {list of catalog.Candidate} the locked set (empty on failure)
 * @field missing {list of string} decks absent from the registry (empty on success)
 * @field error {string} the failure reason ("" on success)
 */
export def struct GraphResult {
    ok as bool,
    resolved as list of catalog.Candidate,
    missing as list of string,
    error as string
};

/**
 * The catalog candidates for every version of a deck, or none when the store
 * does not hold it. A yanked version is passed with `yanked` set, and the
 * resolver never chooses one (`catalog.selectableVersions`); passing it at all
 * is what lets the resolver say a deck exists but has nothing selectable,
 * rather than that it does not exist. A lockfile that pins a yanked version
 * installs from its recorded pin and never asks the catalog.
 *
 * Dependency names are folded as they are read. Records written before publish
 * folded them could spell one deck two ways, which the resolver would treat as
 * two decks and resolve at two versions.
 * @param db {flatdb.DB} the registry to read
 * @param name {string} the deck name, folded
 * @return {list of catalog.Candidate} one candidate per version
 */
func candidatesOf(db as flatdb.DB, name as string) {
    def out as list of catalog.Candidate init [];
    if (not store.hasDeck($db, $name)) {
        return $out;
    }
    for (def version in store.listVersions($db, $name)) {
        def v as store.DeckVersion init store.getVersionRecord($db, $name, $version);
        def requires as map of string to string init {};
        for (def dep in $v.requires) {
            $requires[deckname.fold($dep)] = $v.requires[$dep];
        }
        $out[] = catalog.Candidate{
            name: $name,
            version: $v.version,
            url: $v.url,
            checksum: $v.checksum,
            kind: $v.kind,
            ref: $v.ref,
            commit: $v.commit,
            description: $v.description,
            requires: $requires,
            engines: $v.engines,
            capabilities: $v.capabilities,
            yanked: $v.yanked,
            registry: ""
        };
    }
    return $out;
}

/**
 * Add every live version of a deck to a catalog.
 * @param db {flatdb.DB} the registry to read
 * @param cat {catalog.Catalog} the catalog to extend
 * @param name {string} the deck name
 * @return {catalog.Catalog} the catalog with that deck's live versions added
 */
export func addDeck(db as flatdb.DB, cat as catalog.Catalog, name as string) {
    def entries as list of catalog.Candidate init $cat.entries;
    for (def c in candidatesOf($db, deckname.fold($name))) {
        $entries[] = $c;
    }
    return catalog.Catalog{entries: $entries};
}

# failure is a resolution that did not succeed, with the reason.
func failure(message as string) {
    def noDecks as list of catalog.Candidate init [];
    def noNames as list of string init [];
    return GraphResult{ok: false, resolved: $noDecks, missing: $noNames, error: $message};
}

/**
 * Resolve root requirements against the store, transitively.
 *
 * Everything the roots can reach - through **any** live version, since which
 * version is chosen is not known yet - is gathered in one breadth-first pass and
 * the resolver runs once over it. It used to grow the catalog a level at a time
 * and re-run the whole resolver after each, which made a deep graph cost its
 * depth times a full resolution, every round of which re-copied the catalog.
 * The pass stops at `MAX_GRAPH_DECKS`.
 * @param db {flatdb.DB} the registry to read
 * @param roots {map of string to string} deck name to constraint
 * @return {GraphResult} the version-locked set, or why there is none
 */
export func resolveGraph(db as flatdb.DB, roots as map of string to string) {
    # Store names are folded, so the roots are too: `@Acme/Tool` is `@acme/tool`.
    def folded as map of string to string init {};
    for (def name in $roots) {
        $folded[deckname.fold($name)] = $roots[$name];
    }
    def entries as list of catalog.Candidate init [];
    def queue as list of string init maps.keys($folded);
    def seen as map of string to bool init {};
    def held as int init 0;
    def at as int init 0;
    while ($at < len($queue)) {
        def name as string init $queue[$at];
        $at = $at + 1;
        if (maps.has($seen, $name)) {
            continue;
        }
        $seen[$name] = true;
        def found as list of catalog.Candidate init candidatesOf($db, $name);
        if (len($found) == 0) {
            continue;
        }
        $held = $held + 1;
        if ($held > MAX_GRAPH_DECKS) {
            return failure("the dependency graph reaches more than " +
                convert.toString(MAX_GRAPH_DECKS) + " decks, more than one resolution " +
                "here may draw in");
        }
        for (def c in $found) {
            $entries[] = $c;
            for (def dep in $c.requires) {
                $queue[] = $dep;
            }
        }
    }
    def g as resolver.GraphResult init resolver.resolveGraph(
        catalog.Catalog{entries: $entries},
        $folded);
    if ($g.ok) {
        return GraphResult{ok: true, resolved: $g.resolved, missing: $g.missing, error: ""};
    }
    # Everything reachable is already in the catalog, so a name the resolver
    # still asks for is one the store does not hold.
    if (len($g.missing) > 0) {
        return GraphResult{
            ok: false,
            resolved: $g.resolved,
            missing: $g.missing,
            error: "no such deck in registry: " + $g.missing[0]
        };
    }
    return failure($g.error);
}
