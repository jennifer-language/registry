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
 * the highest selectable version (not yanked, `catalog.selectableVersions`)
 * satisfying *all* constraints on each deck. The loop ends when the choice set
 * stops changing, so a diamond (`A -> B`, `A -> C`, `B -> D`, `C -> D`) unifies
 * `D` under both constraints, and a cycle (`A -> B -> A`) terminates once the
 * constraints stabilise rather than recursing forever.
 *
 * **A choice the constraints have overtaken does not fail the graph.** A
 * chosen version that no longer satisfies the constraints now on its deck is
 * *stale*: it is about to be replaced. Its own requirements still steer this
 * round's picks (dropped, the decks they held down spring back up and the
 * rounds cycle), but they belong to a version that will not be installed, so
 * they may not end the resolution:
 *
 *   - **a failure waits until the round is settled**, meaning no choice is
 *     stale and no deck was reached for the first time this round (that deck's
 *     requirements are not counted yet). Until then a deck with no version that
 *     fits is left unchosen and the rounds go on; once settled, it is the hard
 *     error it always was;
 *   - **`missing` names what the settled graph needs**, judged without the
 *     stale versions' requirements, and is only returned from a settled round
 *     (or when the rounds cycle), so the caller is not sent to fetch a deck
 *     that only a version on its way out asked for.
 *
 * **There is no backtracking.** Every pick is the highest version that fits
 * the constraints the current choices place on its deck, and nothing ever
 * tries a lower one to see whether that would help elsewhere. A graph whose
 * only solutions need some deck held *below* the highest version that fits it
 * is therefore not found: the resolver either fails on a deck with no version
 * left, or notices it has met the same state twice and reports the
 * alternation, rather than searching. A failure is therefore "this resolver
 * found no solution", not a proof that none exists. Finding those would take
 * backtracking or a SAT-style solver.
 *
 * The resolver is **pure**: it reads a `catalog` of candidates and never
 * fetches. A deck it has never heard of is reported in `GraphResult.missing`
 * rather than failing, which is what lets a caller run the fetch loop:
 *
 *     resolve -> missing? -> fetch those decks into the catalog -> resolve again
 *
 * The CLI fills the catalog over HTTP and from git (`cli.resolveRoots`). A
 * caller that cannot supply a missing deck treats `missing` as "no such deck".
 * The registry (`../app-registry`) resolves with its own copy of this module.
 * Keep the copies identical, and diff both ways before changing either.
 * @module resolver
 * @example
 * import "./resolver.j" as resolver;
 * def g as resolver.GraphResult init resolver.resolveGraph($cat, {"@jennifer/routeros": "^0.1.0"});
 * # if ($g.ok) { for (def c in $g.resolved) { ... } }
 */

use maps;
use lists;
use strings;
use convert;
import "./catalog.j" as catalog;
import "./constraint.j" as constraint;
import "./deckname.j" as deckname;

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

# pickKeyOf is a deck and its constraint set as one pick-cache key. Each part is
# prefixed with its length, so no two different sets can share a key whatever
# characters they hold. Joining them with ", " let the single invalid
# constraint "^1.0.0, >=1.0.0" reuse the pick of that valid pair.
func pickKeyOf(name as string, items as list of string) {
    def out as string init convert.toString(len($name)) + ":" + $name;
    for (def c in $items) {
        $out = $out + "|" + convert.toString(len($c)) + ":" + $c;
    }
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

# satisfiesAll reports whether a version satisfies *every* constraint in the
# list, stopping at the first one it fails.
func satisfiesAll(version as string, constraints as list of string) {
    for (def c in $constraints) {
        if (not constraint.satisfies($version, $c)) {
            return false;
        }
    }
    return true;
}

# bestSatisfyingAll returns the highest known version satisfying *every*
# constraint in the list, or "" when none does.
func bestSatisfyingAll(versions as list of string, constraints as list of string) {
    def kept as list of string init [];
    for (def v in $versions) {
        if (satisfiesAll($v, $constraints)) {
            $kept[] = $v;
        }
    }
    # The filter above is the whole test, prerelease opt-in included. Asking
    # `best` for the top of the survivors under `*` re-applied the prerelease
    # rule with nothing to opt in, so `=1.0.0-rc.1` kept 1.0.0-rc.1 and then
    # threw it away.
    return constraint.highest($kept);
}

# Index is the catalog read once into maps for the rounds to look things up in.
# Scanning the list per lookup (and copying it per call into `catalog`) made a
# round cost depth x size squared.
def struct Index {
    versions as map of string to list of string,
    present as map of string to bool,
    requires as map of string to map of string to string
};

# indexOf reads a catalog into an Index in one pass. `versions` holds only the
# selectable ones (not yanked), as `catalog.selectableVersions` does; `present`
# records every deck the catalog knows, yanked or not, for the missing check.
#
# Names are folded, here and wherever a name enters a round (`foldReqs`), since
# a deck name is case-insensitive: a root spelled `@Acme/App` against a catalog
# the registry filled as `@acme/app` otherwise stays missing however many times
# it is fetched. A (name, version) seen before is skipped, so the first entry
# wins, as it does in `catalog.get`; letting a later duplicate's requirements
# overwrite the first one's made the round and the locked set disagree.
func indexOf(cat as catalog.Catalog) {
    def versions as map of string to list of string init {};
    def present as map of string to bool init {};
    def requires as map of string to map of string to string init {};
    for (def e in $cat.entries) {
        def name as string init deckname.fold($e.name);
        def key as string init $name + "@" + $e.version;
        if (maps.has($requires, $key)) {
            continue;
        }
        $present[$name] = true;
        $requires[$key] = foldReqs($e.requires);
        if ($e.yanked) {
            continue;
        }
        def cur as list of string init [];
        if (maps.has($versions, $name)) {
            $cur = $versions[$name];
        }
        $cur[] = $e.version;
        $versions[$name] = $cur;
    }
    return Index{versions: $versions, present: $present, requires: $requires};
}

# foldReqs returns a requirements map with every deck name folded. Two keys
# that fold together both constrain the one deck; the map keeps one, which is
# no worse than a manifest that names a deck once, and a manifest is refused at
# parse when it does this.
func foldReqs(reqs as map of string to string) {
    def out as map of string to string init {};
    for (def name in $reqs) {
        $out[deckname.fold($name)] = $reqs[$name];
    }
    return $out;
}

# accumulate builds the per-deck constraint set for one round: the roots, plus
# the requirements of every chosen (deck, version) **reachable from the roots**
# through the current choices. A deck chosen last round that nothing reachable
# requires any more contributes nothing: counting its requirements anyway kept a
# dropped deck imposing constraints, which could fail a graph that has a
# solution, or keep two decks swapping in and out of it forever.
#
# A deck named in `skip` is constrained like any other but its chosen version's
# requirements are not followed: that is how the decks a stale choice alone
# asks for are told apart (see the module docblock).
func accumulate(
    idx as Index,
    roots as map of string to string,
    chosen as map of string to string,
    skip as map of string to bool) {
    def cons as map of string to list of string init {};
    def queue as list of string init [];
    for (def name in $roots) {
        $cons[$name] = [$roots[$name]];
        $queue[] = $name;
    }
    def visited as map of string to bool init {};
    def at as int init 0;
    while ($at < len($queue)) {
        def name as string init $queue[$at];
        $at = $at + 1;
        if (maps.has($visited, $name) or not maps.has($chosen, $name) or maps.has($skip, $name)) {
            continue;
        }
        $visited[$name] = true;
        def key as string init $name + "@" + $chosen[$name];
        if (not maps.has($idx.requires, $key)) {
            continue;
        }
        def reqs as map of string to string init $idx.requires[$key];
        for (def dep in $reqs) {
            # Appended in place. Returning an edited copy of the map from a helper,
            # once per requirement, made each round quadratic in its size.
            if (not maps.has($cons, $dep)) {
                $cons[$dep] = [$reqs[$dep]];
            } elseif (not listContains($cons[$dep], $reqs[$dep])) {
                def cur as list of string init $cons[$dep];
                $cur[] = $reqs[$dep];
                $cons[$dep] = $cur;
            }
            $queue[] = $dep;
        }
    }
    return $cons;
}

# invalidHint names the constraints in a set that are outside the grammar, or
# returns "". Such a constraint matches nothing, so without this the failure
# would read as "no version is new enough" when the real fault is a typo.
func invalidHint(items as list of string) {
    def bad as list of string init [];
    for (def c in $items) {
        if (not constraint.isValidConstraint($c)) {
            $bad[] = "\"" + $c + "\"";
        }
    }
    if (len($bad) == 0) {
        return "";
    }
    return " (not a valid constraint: " + joinConstraints($bad) + ")";
}

# choiceKey is a set of choices as one comparable string, in a fixed order, so a
# set seen before is recognised whatever order it was built in. Joined once.
func choiceKey(chosen as map of string to string) {
    def parts as list of string init [];
    for (def name in lists.sort(maps.keys($chosen))) {
        $parts[] = $name + "@" + $chosen[$name];
    }
    return strings.join($parts, " ");
}

# stateKey is everything the next round is computed from: the choices, and the
# decks this round reached (a deck reached for the first time keeps a round
# unsettled, so two rounds with equal choices but different reach are different
# states). Meeting a state again therefore really does mean a cycle.
func stateKey(chosen as map of string to string, reached as list of string) {
    return choiceKey($chosen) + " | " + strings.join(lists.sort($reached), " ");
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
    return GraphResult{ok: false, resolved: $noDecks, missing: $noNames, error: $message};
}

# needsFetch builds a GraphResult reporting decks the catalog does not hold yet.
func needsFetch(names as list of string) {
    def noDecks as list of catalog.Candidate init [];
    return GraphResult{ok: false, resolved: $noDecks, missing: $names, error: ""};
}

# buildResolutions turns the chosen name -> version map into the locked candidate
# list, in the catalog's own deck order (the order each deck first appears) so
# the output is deterministic, in one pass over the entries. The first entry for
# a (name, version) is the one taken, as in
# `catalog.get`, and its name is written folded, as the resolution knew it.
func buildResolutions(cat as catalog.Catalog, chosen as map of string to string) {
    def order as list of string init [];
    def found as map of string to catalog.Candidate init {};
    def listed as map of string to bool init {};
    for (def e in $cat.entries) {
        def name as string init deckname.fold($e.name);
        if (not maps.has($chosen, $name)) {
            continue;
        }
        if (not maps.has($listed, $name)) {
            $listed[$name] = true;
            $order[] = $name;
        }
        if (not maps.has($found, $name) and $e.version == $chosen[$name]) {
            def c as catalog.Candidate init $e;
            $c.name = $name;
            $found[$name] = $c;
        }
    }
    def out as list of catalog.Candidate init [];
    for (def name in $order) {
        $out[] = $found[$name];
    }
    return $out;
}

# hasNewDeck reports whether a round reached a known deck the round before it
# did not. Such a deck has no choice yet, so its requirements are not counted
# and the round is not settled.
func hasNewDeck(
    present as map of string to bool,
    cons as map of string to list of string,
    reached as map of string to list of string) {
    for (def name in $cons) {
        if (maps.has($present, $name) and not maps.has($reached, $name)) {
            return true;
        }
    }
    return false;
}

# missingFrom names the decks in a constraint set that the catalog lacks.
func missingFrom(present as map of string to bool, cons as map of string to list of string) {
    def out as list of string init [];
    for (def name in $cons) {
        if (not maps.has($present, $name)) {
            $out[] = $name;
        }
    }
    return $out;
}

# noPick is the result for a settled round in which a deck has no version that
# fits. Fetch first: a missing deck's requirements are not known yet, and
# knowing them may change the round.
func noPick(
    name as string,
    cons as list of string,
    open as list of string,
    missing as list of string) {
    if (len($missing) > 0) {
        return needsFetch($missing);
    }
    return failed("no version of " + $name + " satisfies " + joinConstraints($cons) +
        invalidHint($cons) + constraint.prereleaseHint($open));
}

# settledResult is the result once the choices have stopped changing: the
# locked set, or, while the catalog still lacks decks the graph needs, all of
# them at once, so a caller's fetch loop needs one round trip per level of the
# graph rather than one per deck.
func settledResult(
    cat as catalog.Catalog,
    chosen as map of string to string,
    missing as list of string) {
    if (len($missing) > 0) {
        return needsFetch($missing);
    }
    def locked as list of catalog.Candidate init buildResolutions($cat, $chosen);
    def noNames as list of string init [];
    return GraphResult{ok: true, resolved: $locked, missing: $noNames, error: ""};
}

# cycleResult is the result once a state comes round again: this resolver takes
# the highest version that fits and does not backtrack, so a graph whose only
# solutions need a lower version somewhere ends here. A deck still missing is
# asked for first, since its requirements may break the cycle.
func cycleResult(chosen as map of string to string, missing as list of string) {
    if (len($missing) > 0) {
        return needsFetch($missing);
    }
    return failed("the requirements conflict: resolution keeps alternating " +
        "between choices and never settles on one (" + choiceKey($chosen) + ")");
}

/**
 * Resolve a set of root requirements (deck name -> constraint) into the full
 * transitive, version-locked set, against the versions the catalog holds.
 *
 * Returns `ok` with one candidate per deck in the graph, unified so every deck
 * satisfies all constraints placed on it; or a retryable result naming the decks
 * the catalog is missing; or a hard error. `missing` names only decks the
 * settled graph needs: a requirement of a version the resolution has already
 * moved away from is not one. Every deck missing from the settled graph is
 * named at once.
 *
 * Highest-first and without backtracking; the module docblock says what that
 * cannot find.
 *
 * Deck names are compared folded (`deckname.fold`) throughout: the roots, every
 * requirement key, and the catalog's own names. Names in `missing` and in the
 * locked set are folded too, whatever spelling the roots or the catalog used.
 * @param cat {catalog.Catalog} the known candidate versions
 * @param roots {map of string to string} the root requirements (name -> constraint)
 * @return {GraphResult} the resolution outcome
 */
export func resolveGraph(cat as catalog.Catalog, roots as map of string to string) {
    def rootReqs as map of string to string init foldReqs($roots);
    def chosen as map of string to string init {};
    def reached as map of string to list of string init {};
    def seen as map of string to bool init {};
    def idx as Index init indexOf($cat);
    def picked as map of string to string init {};
    def noSkip as map of string to bool init {};
    for (def round as int init 0; $round < MAX_ROUNDS; $round = $round + 1) {
        def cons as map of string to list of string init accumulate(
            $idx,
            $rootReqs,
            $chosen,
            $noSkip);
        # A stale choice's requirements still count (see the module docblock),
        # but a stale choice keeps the round unsettled, and only a settled round
        # may fail.
        def stale as map of string to bool init {};
        def keys as map of string to string init {};
        for (def name in $cons) {
            $keys[$name] = pickKeyOf($name, $cons[$name]);
            if (not maps.has($chosen, $name)) {
                continue;
            }
            # The pick for this very constraint set fits by construction, and is
            # what an unchanged deck holds, so only a different choice is tested.
            if (maps.has($picked, $keys[$name]) and $picked[$keys[$name]] == $chosen[$name]) {
                continue;
            }
            if (not satisfiesAll($chosen[$name], $cons[$name])) {
                $stale[$name] = true;
            }
        }
        def settled as bool init len($stale) == 0 and not hasNewDeck($idx.present, $cons, $reached);
        # What is missing is judged without the stale versions' requirements:
        # they belong to versions that will not be installed, and counting them
        # sent the caller to fetch decks no settled graph needed.
        def needed as map of string to list of string init $cons;
        if (len($stale) > 0) {
            $needed = accumulate($idx, $rootReqs, $chosen, $stale);
        }
        def missing as list of string init missingFrom($idx.present, $needed);
        def next as map of string to string init {};
        def deferred as bool init false;
        for (def name in $cons) {
            if (not maps.has($idx.present, $name)) {
                continue;
            }
            def open as list of string init [];
            if (maps.has($idx.versions, $name)) {
                $open = $idx.versions[$name];
            }
            # A pick depends only on the deck and its constraint set, which seldom
            # changes between rounds, so each distinct pair is worked out once.
            if (not maps.has($picked, $keys[$name])) {
                $picked[$keys[$name]] = bestSatisfyingAll($open, $cons[$name]);
            }
            def pick as string init $picked[$keys[$name]];
            # Unsettled, a deck with nothing that fits is left unchosen for now:
            # what rules every version out may be a stale choice's requirement,
            # or one a newly reached deck is about to add the remedy for.
            if ($pick == "" and not $settled) {
                $deferred = true;
                continue;
            }
            if ($pick == "") {
                return noPick($name, $cons[$name], $open, $missing);
            }
            $next[$name] = $pick;
        }
        if (not $deferred and sameChoice($chosen, $next)) {
            return settledResult($cat, $next, $missing);
        }
        # Each round is a function of the last round's choices and reach, so
        # meeting a state again means the rounds will cycle through the same
        # states for ever. Say so now rather than after every remaining round.
        def key as string init stateKey($next, maps.keys($cons));
        if (maps.has($seen, $key)) {
            return cycleResult($next, $missing);
        }
        $seen[$key] = true;
        $chosen = $next;
        $reached = $cons;
    }
    return failed("dependency resolution did not converge");
}
