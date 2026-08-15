# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Transitive dependency resolution: given a set of root requirements (deck name
 * -> version constraint), walk the whole dependency graph and return the
 * flattened, version-locked set to install. Each chosen version contributes its
 * own requirements, so a deck reached only through a dependency is resolved too.
 *
 * Resolution is a fixpoint. Each round rebuilds the per-deck constraint set from
 * the roots plus the requirements of the currently-chosen versions, then picks
 * the highest known version satisfying *all* constraints on each deck. The loop
 * ends when the choice set stops changing, so a diamond (`A -> B`, `A -> C`,
 * `B -> D`, `C -> D`) unifies `D` under both constraints, and a cycle
 * (`A -> B -> A`) terminates once the constraints stabilise rather than
 * recursing forever.
 *
 * The resolver is **pure**: it reads a `catalog` of candidates and never
 * fetches. A deck it has never heard of is reported in `GraphResult.missing`
 * rather than failing, which is what lets a caller run the fetch loop:
 *
 *     resolve -> missing? -> fetch those decks into the catalog -> resolve again
 *
 * The CLI fills the catalog over HTTP, the server fills it from its store, and
 * both share this one implementation. A caller that cannot supply a missing deck
 * treats `missing` as "no such deck".
 * @module resolver
 * @example
 * import "./resolver.j" as resolver;
 * def g as resolver.GraphResult init resolver.resolveGraph($cat, {"@jennifer/routeros": "^0.1.0"});
 * # if ($g.ok) { for (def c in $g.resolved) { ... } }
 */

use maps;
import "./catalog.j" as catalog;
import "./constraint.j" as constraint;

# The most resolution rounds before declaring non-convergence (a safety bound far
# above any real graph; each round either changes a choice or terminates).
def const MAX_ROUNDS as int init 1000;

/**
 * The outcome of a transitive resolution.
 *
 * Exactly one of three shapes: `ok` with the locked set; not-ok with a non-empty
 * `missing` (the catalog lacks those decks, so fetch them and retry); or not-ok
 * with an `error` (the graph is genuinely unsatisfiable and retrying will not
 * help).
 * @field ok {bool} true when the whole graph resolved
 * @field resolved {list of catalog.Candidate} the locked set (empty unless ok)
 * @field missing {list of string} decks absent from the catalog (empty unless retryable)
 * @field error {string} the failure reason ("" when ok or when missing is set)
 */
export def struct GraphResult {
    ok as bool,
    resolved as list of catalog.Candidate,
    missing as list of string,
    error as string
};

# listContains reports whether a string list already holds a value.
func listContains(items as list of string, value as string) {
    for (def it in $items) {
        if ($it == $value) {
            return true;
        }
    }
    return false;
}

# addConstraint returns cons with value appended to name's constraint list (kept
# duplicate-free). Maps are value-semantic, so this returns a fresh map.
func addConstraint(cons as map of string to list of string, name as string, value as string) {
    def out as map of string to list of string init $cons;
    def cur as list of string init [];
    if (maps.has($out, $name)) {
        $cur = $out[$name];
    }
    if (not listContains($cur, $value)) {
        $cur[] = $value;
    }
    $out[$name] = $cur;
    return $out;
}

# joinConstraints renders a constraint list as "a, b, c" for error messages.
func joinConstraints(items as list of string) {
    def out as string init "";
    for (def c in $items) {
        if ($out == "") {
            $out = $c;
        } else {
            $out = $out + ", " + $c;
        }
    }
    return $out;
}

# bestSatisfyingAll returns the highest known version satisfying *every*
# constraint in the list, or "" when none does.
func bestSatisfyingAll(versions as list of string, constraints as list of string) {
    def kept as list of string init [];
    for (def v in $versions) {
        def all as bool init true;
        for (def c in $constraints) {
            if (not constraint.satisfies($v, $c)) {
                $all = false;
            }
        }
        if ($all) {
            $kept[] = $v;
        }
    }
    return constraint.best($kept, "*");
}

# accumulate builds the per-deck constraint set for one round: the roots, plus
# the requirements contributed by every currently-chosen (deck, version).
func accumulate(cat as catalog.Catalog, roots as map of string to string,
    chosen as map of string to string) {
    def cons as map of string to list of string init {};
    for (def name in $roots) {
        $cons = addConstraint($cons, $name, $roots[$name]);
    }
    for (def name in $chosen) {
        def reqs as map of string to string init catalog.requires($cat, $name, $chosen[$name]);
        for (def dep in $reqs) {
            $cons = addConstraint($cons, $dep, $reqs[$dep]);
        }
    }
    return $cons;
}

# sameChoice reports whether two name -> version maps are identical.
func sameChoice(a as map of string to string, b as map of string to string) {
    if (len($a) != len($b)) {
        return false;
    }
    for (def k in $a) {
        if (not maps.has($b, $k)) {
            return false;
        }
        if (not ($a[$k] == $b[$k])) {
            return false;
        }
    }
    return true;
}

# failed builds a GraphResult for an unsatisfiable graph (retrying will not help).
func failed(message as string) {
    def noDecks as list of catalog.Candidate init [];
    def noNames as list of string init [];
    return GraphResult{ ok: false, resolved: $noDecks, missing: $noNames, error: $message };
}

# needsFetch builds a GraphResult reporting decks the catalog does not hold yet.
func needsFetch(names as list of string) {
    def noDecks as list of catalog.Candidate init [];
    return GraphResult{ ok: false, resolved: $noDecks, missing: $names, error: "" };
}

# buildResolutions turns the chosen name -> version map into the locked candidate
# list, in the catalog's own deck order so the output is deterministic.
func buildResolutions(cat as catalog.Catalog, chosen as map of string to string) {
    def out as list of catalog.Candidate init [];
    for (def name in catalog.names($cat)) {
        if (maps.has($chosen, $name)) {
            $out[] = catalog.get($cat, $name, $chosen[$name]);
        }
    }
    return $out;
}

/**
 * Resolve a set of root requirements (deck name -> constraint) into the full
 * transitive, version-locked set, against the versions the catalog holds.
 *
 * Returns `ok` with one candidate per deck in the graph, unified so every deck
 * satisfies all constraints placed on it; or a retryable result naming the decks
 * the catalog is missing; or a hard error.
 * @param cat {catalog.Catalog} the known candidate versions
 * @param roots {map of string to string} the root requirements (name -> constraint)
 * @return {GraphResult} the resolution outcome
 */
export func resolveGraph(cat as catalog.Catalog, roots as map of string to string) {
    def chosen as map of string to string init {};
    for (def round as int init 0; $round < MAX_ROUNDS; $round = $round + 1) {
        def cons as map of string to list of string init accumulate($cat, $roots, $chosen);
        # Report every unknown deck at once, so a caller's fetch loop needs one
        # round trip per level of the graph rather than one per deck.
        def missing as list of string init [];
        for (def name in $cons) {
            if (not catalog.hasDeck($cat, $name)) {
                $missing[] = $name;
            }
        }
        if (len($missing) > 0) {
            return needsFetch($missing);
        }
        def next as map of string to string init {};
        for (def name in $cons) {
            def pick as string init bestSatisfyingAll(catalog.versions($cat, $name), $cons[$name]);
            if ($pick == "") {
                return failed("no version of " + $name + " satisfies " +
                    joinConstraints($cons[$name]));
            }
            $next[$name] = $pick;
        }
        if (sameChoice($chosen, $next)) {
            def locked as list of catalog.Candidate init buildResolutions($cat, $next);
            def noNames as list of string init [];
            return GraphResult{ ok: true, resolved: $locked, missing: $noNames, error: "" };
        }
        $chosen = $next;
    }
    return failed("dependency resolution did not converge");
}
