# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The candidate catalog: the published deck versions a resolution may choose
 * from, held as plain values with no idea where they came from. It is the seam
 * that lets one resolver serve two callers - the CLI fills a catalog from a
 * repository over HTTP (and, later, from a git URL), while the server fills one
 * straight from its `flatdb` store - so `resolver` never talks to a transport.
 *
 * A catalog is a flat list of `Candidate`s (one per published deck version)
 * rather than a nested map, because Jennifer maps hold a single value type and a
 * map of name to list-of-struct is clumsier than a scan. Catalogs hold tens of
 * entries, so the linear lookups here are not worth indexing.
 *
 * Every function is pure and value-semantic: `add` returns a fresh catalog and
 * never mutates its argument.
 * @module catalog
 * @example
 * import "./catalog.j" as catalog;
 * def cat as catalog.Catalog init catalog.empty();
 * $cat = catalog.add($cat, catalog.candidate("@jennifer/routeros", "0.1.0"));
 * def vs as list of string init catalog.versions($cat, "@jennifer/routeros");
 */

use maps;

/**
 * One published deck version and everything a resolution or an install needs to
 * know about it.
 *
 * A deck reaches the catalog from one of two sources, told apart by `kind`:
 * `"tar.gz"` is a repository release, pinned by its artifact `checksum`;
 * `"git"` is a git remote, pinned by `ref` (the tag resolution chose) and
 * `commit` (the SHA that tag pointed at). The unused pin is "".
 * @field name {string} the deck name (`@scope/deck` for a registry deck)
 * @field version {string} the published version (SemVer)
 * @field url {string} the artifact fetch URL, or the git remote URL
 * @field checksum {string} the artifact checksum ("sha256:<hex>"; "" for a git deck)
 * @field kind {string} the delivery kind, "tar.gz" (repository) or "git"
 * @field ref {string} the git tag this version came from ("" for a repository deck)
 * @field commit {string} the git commit the ref pinned ("" for a repository deck)
 * @field description {string} a one-line summary ("" when absent)
 * @field requires {map of string to string} this version's own deps (deck -> constraint)
 * @field engines {map of string to string} the engines that can run it (engine -> range)
 * @field capabilities {list of string} host capabilities its code needs (net / exec / sql)
 */
export def struct Candidate {
    name as string,
    version as string,
    url as string,
    checksum as string,
    kind as string,
    ref as string,
    commit as string,
    description as string,
    requires as map of string to string,
    engines as map of string to string,
    capabilities as list of string
};

/**
 * A set of candidate versions to resolve against.
 * @field entries {list of Candidate} every known deck version, in insertion order
 */
export def struct Catalog {
    entries as list of Candidate
};

/**
 * Build an empty catalog.
 * @return {Catalog} a catalog with no candidates
 */
export func empty() {
    def none as list of Candidate init [];
    return Catalog{ entries: $none };
}

/**
 * Build a minimal candidate: a name and a version, with every delivery field
 * empty and no requirements or engines. Handy in tests and for callers that only
 * resolve versions; use a `Candidate{...}` literal when the delivery fields
 * matter.
 * @param name {string} the deck name
 * @param version {string} the published version
 * @return {Candidate} the candidate
 */
export func candidate(name as string, version as string) {
    def noReqs as map of string to string init {};
    def noEngines as map of string to string init {};
    def noCaps as list of string init [];
    return Candidate{
        name: $name,
        version: $version,
        url: "",
        checksum: "",
        kind: "tar.gz",
        ref: "",
        commit: "",
        description: "",
        requires: $noReqs,
        engines: $noEngines,
        capabilities: $noCaps
    };
}

/**
 * Return a fresh catalog with one more candidate appended. A repeated
 * (name, version) is added again rather than merged; sources are expected not to
 * announce the same version twice.
 * @param cat {Catalog} the catalog to extend
 * @param cand {Candidate} the candidate to add
 * @return {Catalog} a fresh catalog including cand
 */
export func add(cat as Catalog, cand as Candidate) {
    def out as list of Candidate init $cat.entries;
    $out[] = $cand;
    return Catalog{ entries: $out };
}

/**
 * Report whether the catalog knows any version of a deck. This is the test the
 * resolver uses to decide whether a deck is genuinely absent or merely not
 * fetched yet.
 * @param cat {Catalog} the catalog to read
 * @param name {string} the deck name
 * @return {bool} true when at least one version of the deck is present
 */
export func hasDeck(cat as Catalog, name as string) {
    for (def e in $cat.entries) {
        if ($e.name == $name) {
            return true;
        }
    }
    return false;
}

/**
 * List every deck name in the catalog, deduplicated, in first-seen order.
 * @param cat {Catalog} the catalog to read
 * @return {list of string} the deck names
 */
export func names(cat as Catalog) {
    def seen as map of string to bool init {};
    def out as list of string init [];
    for (def e in $cat.entries) {
        if (not maps.has($seen, $e.name)) {
            $seen[$e.name] = true;
            $out[] = $e.name;
        }
    }
    return $out;
}

/**
 * List a deck's known version strings, in insertion order. Empty when the deck
 * is not in the catalog.
 * @param cat {Catalog} the catalog to read
 * @param name {string} the deck name
 * @return {list of string} the version strings
 */
export func versions(cat as Catalog, name as string) {
    def out as list of string init [];
    for (def e in $cat.entries) {
        if ($e.name == $name) {
            $out[] = $e.version;
        }
    }
    return $out;
}

/**
 * Report whether one specific deck version is in the catalog.
 * @param cat {Catalog} the catalog to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {bool} true when that version is present
 */
export func hasVersion(cat as Catalog, name as string, version as string) {
    for (def e in $cat.entries) {
        if ($e.name == $name and $e.version == $version) {
            return true;
        }
    }
    return false;
}

/**
 * Return one candidate by name and version. Guard with `hasVersion`: an unknown
 * version throws rather than returning a hollow candidate, so a resolver bug
 * surfaces instead of installing nothing.
 * @param cat {Catalog} the catalog to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {Candidate} the matching candidate
 * @throws {Error} when that deck version is not in the catalog
 */
export func get(cat as Catalog, name as string, version as string) {
    for (def e in $cat.entries) {
        if ($e.name == $name and $e.version == $version) {
            return $e;
        }
    }
    throw Error{
        kind: "catalog",
        message: "no such candidate: " + $name + "@" + $version,
        file: "", line: 0, col: 0
    };
}

/**
 * Return a version's own requirements (deck name -> constraint), or an empty map
 * when the version is unknown or declares none.
 * @param cat {Catalog} the catalog to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {map of string to string} the version's requirements
 */
export func requires(cat as Catalog, name as string, version as string) {
    for (def e in $cat.entries) {
        if ($e.name == $name and $e.version == $version) {
            return $e.requires;
        }
    }
    def none as map of string to string init {};
    return $none;
}
