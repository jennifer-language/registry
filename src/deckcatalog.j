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

import "flatdb.j" as flatdb;
import "./store.j" as store;
import "./catalog.j" as catalog;
import "./resolver.j" as resolver;

# The most fetch rounds before giving up. Each round adds at least one deck to
# the catalog, so this bounds the depth of the dependency graph, not its size.
def const MAX_FETCH_ROUNDS as int init 1000;

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
 * Add every published version of one deck to a catalog, returning a fresh
 * catalog. A deck that is not in the registry adds nothing, which is how the
 * resolver learns it is genuinely absent rather than merely unfetched.
 * @param db {flatdb.DB} the registry to read
 * @param cat {catalog.Catalog} the catalog to extend
 * @param name {string} the deck name
 * @return {catalog.Catalog} a fresh catalog including that deck's versions
 */
export func addDeck(db as flatdb.DB, cat as catalog.Catalog, name as string) {
    def out as catalog.Catalog init $cat;
    if (not store.hasDeck($db, $name)) {
        return $out;
    }
    # Yanked versions are left out of the candidate set, so transitive resolution
    # cannot land on one. A lockfile that pins a yanked version installs from its
    # recorded pin and never asks the catalog.
    for (def version in store.listLiveVersions($db, $name)) {
        def v as store.DeckVersion init store.getVersionRecord($db, $name, $version);
        $out = catalog.add($out, catalog.Candidate{
            name: $name,
            version: $v.version,
            url: $v.url,
            checksum: $v.checksum,
            kind: $v.kind,
            ref: $v.ref,
            commit: $v.commit,
            description: $v.description,
            requires: $v.requires,
            engines: $v.engines,
            capabilities: $v.capabilities
        });
    }
    return $out;
}

/**
 * Resolve a set of root requirements against the registry, running the shared
 * resolver's fetch loop with the store as the source: resolve, seed whatever the
 * resolver reported missing, resolve again. A deck the store cannot supply ends
 * the loop with a "no such deck" error.
 * @param db {flatdb.DB} the registry to read
 * @param roots {map of string to string} the root requirements (name -> constraint)
 * @return {GraphResult} the resolution outcome
 */
export func resolveGraph(db as flatdb.DB, roots as map of string to string) {
    def cat as catalog.Catalog init catalog.empty();
    for (def round as int init 0; $round < MAX_FETCH_ROUNDS; $round = $round + 1) {
        def g as resolver.GraphResult init resolver.resolveGraph($cat, $roots);
        if ($g.ok) {
            return GraphResult{ ok: true, resolved: $g.resolved, missing: $g.missing, error: "" };
        }
        if (len($g.missing) == 0) {
            return GraphResult{
                ok: false,
                resolved: $g.resolved,
                missing: $g.missing,
                error: $g.error
            };
        }
        # Seed what the resolver asked for. A deck the store does not hold adds
        # nothing, so it comes back as missing next round and we stop there.
        def added as int init 0;
        for (def name in $g.missing) {
            if (store.hasDeck($db, $name)) {
                $cat = addDeck($db, $cat, $name);
                $added = $added + 1;
            } else {
                return GraphResult{
                    ok: false,
                    resolved: $g.resolved,
                    missing: $g.missing,
                    error: "no such deck in registry: " + $name
                };
            }
        }
        if ($added == 0) {
            def noNames as list of string init [];
            return GraphResult{
                ok: false,
                resolved: $g.resolved,
                missing: $noNames,
                error: "dependency resolution made no progress"
            };
        }
    }
    def noDecks as list of catalog.Candidate init [];
    def noNames as list of string init [];
    return GraphResult{
        ok: false,
        resolved: $noDecks,
        missing: $noNames,
        error: "dependency resolution did not converge"
    };
}
