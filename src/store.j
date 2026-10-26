# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The deck-registry store over a `flatdb` JSON document. A registry holds many
 * decks; each deck holds many published versions; each version records where
 * its code lives, how to pin it, a description, and when it was published. The
 * deck schema is:
 *
 *     { "decks": { "<name>": {
 *         "name": "...", "description": "...", "readme": "...",
 *         "versions": { "<version>": {
 *             "version": "...", "kind": "git" | "tar.gz", "url": "...",
 *             "ref": "...", "commit": "...", "checksum": "...",
 *             "requires": { ... }, "engines": { ... }, "capabilities": [ ... ],
 *             "keywords": [ ... ], "license": "...", "yanked": false,
 *             "description": "...", "publishedAt": "..." } } } } }
 *
 * Beside `decks`, created on first write: `namespaces`, `refreshTokens`,
 * `forgeTokens`, `publishers`, `ciTokens` and `stats`.
 *
 * `kind` selects the delivery. A `"git"` version is pinned by `commit`, the SHA
 * its `ref` tag pointed at when published; git verifies object hashes on fetch,
 * so the commit is the integrity boundary and `checksum` is unused. A
 * `"tar.gz"` version is an uploaded artifact pinned by `checksum`, and `ref` /
 * `commit` are unused. A record with no `kind` reads as `"tar.gz"`.
 *
 * Writers return a fresh DB (flatdb value semantics); `store.save` persists.
 * @module store
 * @example
 * import "./store.j" as store;
 * def db as flatdb.DB init store.open("decks.json");
 * def r as store.Resolution init store.resolve($db, "ansi", "^1.2.0");
 */

use json;
use strings;
use convert;
use fs;
import "flatdb.j" as flatdb;
import "semver.j" as semver;
import "./constraint.j" as constraint;
import "./deckname.j" as deckname;
import "./trustpub.j" as trustpub;
import "./citoken.j" as citoken;

# ptrEscape / ptrUnescape encode a name as one JSON Pointer reference token
# (RFC 6901: "~" -> "~0", "/" -> "~1"), so a scoped deck name such as
# "@jennifer/routeros" is a single key. The pointer builders escape; listing
# unescapes.
func ptrEscape(token as string) {
    def out as string init strings.replace($token, "~", "~0");
    return strings.replace($out, "/", "~1");
}

func ptrUnescape(token as string) {
    def out as string init strings.replace($token, "~1", "/");
    return strings.replace($out, "~0", "~");
}

# The two delivery kinds a version record may declare.
export def const KIND_GIT as string init "git";
export def const KIND_TARGZ as string init "tar.gz";

# The characters a commit SHA and a sha256 digest are written in, the lengths
# each must have, and the prefix a checksum names its algorithm with.
def const HEXDIGITS as string init "0123456789abcdef";
def const COMMIT_LEN as int init 40;
def const SHA256_LEN as int init 64;
def const CHECKSUM_PREFIX as string init "sha256:";

# The shortest hex run git reads as an abbreviated object id, and the longest
# object id (SHA-256). Bounds for `isObjectIdLike`.
def const ABBREV_MIN as int init 7;
def const OBJECT_ID_MAX as int init 64;

# isLowerHex reports whether s is exactly n lowercase hex digits.
func isLowerHex(s as string, n as int) {
    if (not (len($s) == $n)) {
        return false;
    }
    for (def ch in strings.chars($s)) {
        if (strings.indexOf(HEXDIGITS, $ch) < 0) {
            return false;
        }
    }
    return true;
}

/**
 * Report whether a string is a full git commit SHA: exactly 40 lowercase hex
 * digits. An abbreviated SHA is rejected because a short prefix can become
 * ambiguous as a repository grows.
 * @param s {string} the candidate SHA
 * @return {bool} true when s is a full commit SHA
 */
export func isCommit(s as string) {
    return isLowerHex($s, COMMIT_LEN);
}

/**
 * Report whether a string could be read as a git object id: 7 to 64 hex
 * digits, in either case. A `ref` must never have this shape.
 *
 * Where a name resolves before an object (the `?ref=` parameter on every forge
 * API, `git fetch <remote> <name>`), a ref called `4a3b...` shadows the commit
 * of that id. GitHub refuses such names at creation; GitLab, Gitea, Forgejo and
 * self-hosted servers do not, so the registry refuses them on the way in.
 *
 * Both cases are rejected because git's hex parsing accepts either. 7 is git's
 * shortest abbreviation; 64 is the longest object id. A false positive costs a
 * publisher one tag rename.
 * @param s {string} the candidate ref name
 * @return {bool} true when the name could be read as an object id
 */
export func isObjectIdLike(s as string) {
    if (len($s) < ABBREV_MIN or len($s) > OBJECT_ID_MAX) {
        return false;
    }
    def lowered as string init strings.lower($s);
    for (def ch in strings.chars($lowered)) {
        if (strings.indexOf(HEXDIGITS, $ch) < 0) {
            return false;
        }
    }
    return true;
}

/**
 * Report whether a string is a well-formed artifact checksum: `sha256:` followed
 * by 64 lowercase hex digits.
 * @param s {string} the candidate checksum
 * @return {bool} true when s is a well-formed checksum
 */
export func isChecksum(s as string) {
    if (not strings.startsWith($s, CHECKSUM_PREFIX)) {
        return false;
    }
    def digest as string init strings.substring($s, len(CHECKSUM_PREFIX), len($s));
    return isLowerHex($digest, SHA256_LEN);
}

/**
 * One published deck version's record, as stored under a deck's `versions`
 * table and returned to a client. The pin fields unused by `kind` are stored
 * empty, never omitted.
 * @field version {string} the version string (SemVer)
 * @field kind {string} the delivery kind, KIND_GIT or KIND_TARGZ
 * @field url {string} the git clone URL (git) or the artifact URL (tar.gz)
 * @field ref {string} the tag this version was published from, git only ("" otherwise)
 * @field commit {string} the 40-hex SHA that tag pointed at, git only ("" otherwise)
 * @field checksum {string} `sha256:<hex>` of the artifact, tar.gz only ("" otherwise)
 * @field requires {map of string to string} this version's runtime deps (deck name -> constraint)
 * @field engines {map of string to string} the Jennifer engines that can run it (engine -> range)
 * @field capabilities {list of string} host capabilities its code needs (net / exec / sql)
 * @field description {string} a one-line summary of this version ("" when absent)
 * @field publishedAt {string} when the version was published (Unix seconds as text)
 * @field yanked {bool} true when withdrawn from new resolutions but still
 *     fetchable
 * @field license {string} the SPDX identifier from the manifest ("" when absent)
 * @field keywords {list of string} the deck's tags, normalised by
 *     `keywords.normalise` at publish time; absent reads as empty
 */
export def struct DeckVersion {
    version as string,
    kind as string,
    url as string,
    ref as string,
    commit as string,
    checksum as string,
    requires as map of string to string,
    engines as map of string to string,
    capabilities as list of string,
    description as string,
    publishedAt as string,
    yanked as bool,
    license as string,
    keywords as list of string
};

/**
 * The outcome of resolving a deck + constraint against the registry: whether a
 * matching version was found and, if so, where to fetch it.
 * @field found {bool} true when a version satisfying the constraint exists
 * @field name {string} the deck name that was resolved
 * @field version {string} the matched version ("" when not found)
 * @field kind {string} the delivery kind, KIND_GIT or KIND_TARGZ
 * @field url {string} the external fetch URL ("" when not found)
 * @field ref {string} the matched version's git tag ("" when not found or not git)
 * @field commit {string} the matched version's commit SHA ("" when not found or not git)
 * @field checksum {string} the matched version's checksum ("" when not found or not tar.gz)
 * @field description {string} the matched version's description ("" when not found)
 */
export def struct Resolution {
    found as bool,
    name as string,
    version as string,
    kind as string,
    url as string,
    ref as string,
    commit as string,
    checksum as string,
    description as string
};

# Every pointer builder folds the deck name first, so the store is
# case-insensitive: `@Netflix/Foo` and `@netflix/foo` address one record
# (specification 2.1).
#
# deckPtr is the JSON Pointer of a deck record.
func deckPtr(name as string) {
    return "/decks/" + ptrEscape(deckname.fold($name));
}

# versionsPtr is the JSON Pointer of a deck's versions table.
func versionsPtr(name as string) {
    return deckPtr($name) + "/versions";
}

# versionPtr is the JSON Pointer of one version record.
func versionPtr(name as string, version as string) {
    return versionsPtr($name) + "/" + ptrEscape($version);
}

/**
 * Ensure the document has a top-level `decks` table, returning a DB that has
 * one. A no-op when it is already present.
 * @param db {flatdb.DB} the store to normalize
 * @return {flatdb.DB} a store whose `decks` table exists
 */
export func ensureSchema(db as flatdb.DB) {
    if (not flatdb.has($db, "/decks")) {
        return flatdb.set($db, "/decks", json.map());
    }
    return $db;
}

/**
 * Open the registry document at path and ensure its schema. A missing file
 * yields an empty registry, so first run never fails.
 * @param path {string} the backing file path
 * @return {flatdb.DB} the opened, schema-normalized store
 */
export func open(path as string) {
    return ensureSchema(flatdb.open($path));
}

/**
 * Persist the registry document to its backing file (crash-atomic).
 * @param db {flatdb.DB} the store to write
 * @throws {Error} on a filesystem write failure
 */
export func save(db as flatdb.DB) {
    flatdb.save($db);
}

/**
 * List every deck name in the registry, in document order.
 * @param db {flatdb.DB} the store to read
 * @return {list of string} the deck names (empty when the registry is empty)
 */
export func listDecks(db as flatdb.DB) {
    if (not flatdb.has($db, "/decks")) {
        def none as list of string init [];
        return $none;
    }
    def out as list of string init [];
    for (def k in flatdb.keys($db, "/decks")) {
        $out[] = ptrUnescape($k);
    }
    return $out;
}

/**
 * Report whether a deck exists in the registry.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @return {bool} true when the deck is present
 */
export func hasDeck(db as flatdb.DB, name as string) {
    return flatdb.has($db, deckPtr($name));
}

/**
 * Return a deck's whole record as a json.Value (its name, description, and
 * versions table). The caller should check `hasDeck` first.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @return {json.Value} the deck record
 * @throws {Error} when the deck does not exist
 */
export func getDeckJson(db as flatdb.DB, name as string) {
    return flatdb.get($db, deckPtr($name));
}

/**
 * Return a deck's description, or "" when the deck is absent or has none.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @return {string} the deck description, or ""
 */
export func deckDescription(db as flatdb.DB, name as string) {
    def ptr as string init deckPtr($name) + "/description";
    if (flatdb.has($db, $ptr)) {
        return json.asString(flatdb.get($db, $ptr));
    }
    return "";
}

/**
 * List a deck's published version strings, in document order. Empty when the
 * deck is absent or has no versions.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @return {list of string} the version strings
 */
export func listVersions(db as flatdb.DB, name as string) {
    if (not flatdb.has($db, versionsPtr($name))) {
        def none as list of string init [];
        return $none;
    }
    return flatdb.keys($db, versionsPtr($name));
}

# plainCore reads a version that is only MAJOR.MINOR.PATCH (no prerelease, no
# build, no leading zero, no number too long to hold) as its three numbers, and
# anything else as none. Comparing three ints is much cheaper than a SemVer
# parse, which dominated listing time.
func plainCore(v as string) {
    def none as list of int init [];
    def parts as list of string init strings.split($v, ".");
    if (not (len($parts) == 3)) {
        return $none;
    }
    def out as list of int init [];
    for (def part in $parts) {
        if (len($part) == 0 or len($part) > 18 or
            (len($part) > 1 and strings.startsWith($part, "0"))) {
            return $none;
        }
        for (def ch in strings.chars($part)) {
            if ($ch < "0" or $ch > "9") {
                return $none;
            }
        }
        $out[] = convert.toInt($part);
    }
    return $out;
}

# coreAbove reports whether one plainCore sorts above another.
func coreAbove(a as list of int, b as list of int) {
    for (def i in 0..3) {
        if (not ($a[$i] == $b[$i])) {
            return $a[$i] > $b[$i];
        }
    }
    return false;
}

# plainOrder is the positions of `cores` highest first, by selection: each pass
# takes the highest not yet taken, the earliest of equals first, so the sort is
# stable and moves ints only; the cores stay where they were.
func plainOrder(cores as list of list of int) {
    def taken as list of bool init [];
    for (def c in $cores) {
        $taken[] = false;
    }
    def order as list of int init [];
    for (def k in 0..len($cores)) {
        def best as int init -1;
        for (def i in 0..len($cores)) {
            if (not $taken[$i] and ($best < 0 or coreAbove($cores[$i], $cores[$best]))) {
                $best = $i;
            }
        }
        $taken[$best] = true;
        $order[] = $best;
    }
    return $order;
}

# plainDescending orders versions that are all plainCore, highest first, or
# returns none when any is not, for the general path to handle.
func plainDescending(all as list of string) {
    def none as list of string init [];
    def cores as list of list of int init [];
    for (def v in $all) {
        def core as list of int init plainCore($v);
        if (len($core) == 0) {
            return $none;
        }
        $cores[] = $core;
    }
    def out as list of string init [];
    for (def i in plainOrder($cores)) {
        $out[] = $all[$i];
    }
    return $out;
}

# semverOrder is `plainOrder` over parsed versions, by SemVer precedence.
func semverOrder(parsed as list of semver.Version) {
    def taken as list of bool init [];
    for (def p in $parsed) {
        $taken[] = false;
    }
    def order as list of int init [];
    for (def k in 0..len($parsed)) {
        def best as int init -1;
        for (def i in 0..len($parsed)) {
            if (not $taken[$i] and
                ($best < 0 or semver.compare($parsed[$i], $parsed[$best]) > 0)) {
                $best = $i;
            }
        }
        $taken[$best] = true;
        $order[] = $best;
    }
    return $order;
}

/**
 * List a deck's published versions, highest first by SemVer precedence, so
 * `[0]` is the latest release. A version that is not usable SemVer sorts last,
 * in document order, so a malformed record stays visible.
 *
 * Each version is parsed once, then positions are sorted; parsing inside the
 * comparison, and later rebuilding the parsed list per insertion, were the most
 * expensive steps of every listing.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @return {list of string} the version strings, highest first
 */
export func listVersionsDescending(db as flatdb.DB, name as string) {
    def all as list of string init listVersions($db, $name);
    if (len($all) < 2) {
        return $all;
    }
    def plain as list of string init plainDescending($all);
    if (len($plain) > 0) {
        return $plain;
    }
    # `isUsableVersion`, not `semver.isValid`: a valid version with a number too
    # large to hold throws inside `compare` and would fail every listing.
    def usable as list of string init [];
    def parsed as list of semver.Version init [];
    def unusable as list of string init [];
    for (def v in $all) {
        if (not constraint.isUsableVersion($v)) {
            $unusable[] = $v;
            continue;
        }
        $parsed[] = semver.parse($v);
        $usable[] = $v;
    }
    def out as list of string init [];
    for (def i in semverOrder($parsed)) {
        $out[] = $usable[$i];
    }
    for (def v in $unusable) {
        $out[] = $v;
    }
    return $out;
}

/**
 * The published version that `version` is the same release as, or "". SemVer
 * ignores build metadata in precedence, so `1.0.0+a` and `1.0.0+b` are one
 * version; stored as two records they would be two commits behind one number.
 * Every write path asks this before adding a version.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param version {string} the version about to be written
 * @return {string} the stored version with the same precedence, or ""
 */
export func publishedAs(db as flatdb.DB, name as string, version as string) {
    def bare as string init withoutBuild($version);
    for (def v in listVersions($db, $name)) {
        if (withoutBuild($v) == $bare) {
            return $v;
        }
    }
    return "";
}

# withoutBuild drops a version's build metadata (from the first "+").
func withoutBuild(version as string) {
    def plus as int init strings.indexOf($version, "+");
    if ($plus < 0) {
        return $version;
    }
    return strings.substring($version, 0, $plus);
}

/**
 * Report whether a specific deck version exists.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {bool} true when that version is published
 */
export func hasVersion(db as flatdb.DB, name as string, version as string) {
    return flatdb.has($db, versionPtr($name, $version));
}

/**
 * Return one version's record as a json.Value. The caller should check
 * `hasVersion` first.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {json.Value} the version record
 * @throws {Error} when that version does not exist
 */
export func getVersionJson(db as flatdb.DB, name as string, version as string) {
    return flatdb.get($db, versionPtr($name, $version));
}

/**
 * Read one published version's whole record as a `DeckVersion`. Absent optional
 * fields read as empty and an absent `kind` reads as KIND_TARGZ. The caller
 * should check `hasVersion` first.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {DeckVersion} the version record
 * @throws {Error} when that version does not exist
 */
export func getVersionRecord(db as flatdb.DB, name as string, version as string) {
    def rec as json.Value init getVersionJson($db, $name, $version);
    return DeckVersion{
        version: $version,
        kind: recordKind($rec),
        url: recordString($rec, "/url"),
        ref: recordString($rec, "/ref"),
        commit: recordString($rec, "/commit"),
        checksum: recordString($rec, "/checksum"),
        requires: versionRequires($db, $name, $version),
        engines: versionEngines($db, $name, $version),
        capabilities: versionCapabilities($db, $name, $version),
        description: recordString($rec, "/description"),
        publishedAt: recordString($rec, "/publishedAt"),
        yanked: recordBool($rec, "/yanked"),
        license: recordString($rec, "/license"),
        keywords: versionKeywords($db, $name, $version)
    };
}

/**
 * Insert or replace a deck version, creating the deck record if needed, and
 * returning a fresh DB. A non-empty `description` updates the deck's own
 * description; an empty one leaves an existing description untouched.
 *
 * Over an existing record the publish provenance (`repoId`, `repoOwnerId`,
 * `repoOwner`) is carried over, and so are `yanked`, `license` and `keywords`
 * when `ver` leaves them unset: `deckadmin update` replaces the pin, not the
 * withdrawal or what the manifest said.
 * @param db {flatdb.DB} the store to edit
 * @param name {string} the deck name
 * @param description {string} the deck's description (empty = leave unchanged)
 * @param ver {DeckVersion} the version record to store
 * @return {flatdb.DB} a fresh store with the version written
 */
export func putVersion(db as flatdb.DB, name as string, description as string, ver as DeckVersion) {
    def out as flatdb.DB init ensureSchema($db);
    if (not flatdb.has($out, deckPtr($name))) {
        def rec as json.Value init json.map();
        $rec = json.set($rec, "/name", deckname.fold($name));
        $rec = json.set($rec, "/description", $description);
        $rec = json.set($rec, "/versions", json.map());
        $out = flatdb.set($out, deckPtr($name), $rec);
    } elseif (len($description) > 0) {
        # flatdb.set needs a json.Value; json.set coerces the native string.
        def rec as json.Value init flatdb.get($out, deckPtr($name));
        $rec = json.set($rec, "/description", $description);
        $out = flatdb.set($out, deckPtr($name), $rec);
    }
    def kept as DeckVersion init carriedOver($out, $name, $ver);
    def vjson as json.Value init json.map();
    $vjson = json.set($vjson, "/version", $ver.version);
    $vjson = json.set($vjson, "/kind", $ver.kind);
    $vjson = json.set($vjson, "/url", $ver.url);
    $vjson = json.set($vjson, "/ref", $ver.ref);
    $vjson = json.set($vjson, "/commit", $ver.commit);
    $vjson = json.set($vjson, "/checksum", $ver.checksum);
    $vjson = json.set($vjson, "/yanked", $kept.yanked);
    $vjson = json.set($vjson, "/license", $kept.license);
    def rjson as json.Value init json.map();
    for (def dep in $ver.requires) {
        $rjson = json.set($rjson, "/" + ptrEscape($dep), $ver.requires[$dep]);
    }
    $vjson = json.set($vjson, "/requires", $rjson);
    def ejson as json.Value init json.map();
    for (def eng in $ver.engines) {
        $ejson = json.set($ejson, "/" + ptrEscape($eng), $ver.engines[$eng]);
    }
    $vjson = json.set($vjson, "/engines", $ejson);
    def cjson as json.Value init json.list();
    for (def cap in $ver.capabilities) {
        $cjson = json.append($cjson, "", $cap);
    }
    $vjson = json.set($vjson, "/capabilities", $cjson);
    def kjson as json.Value init json.list();
    for (def word in $kept.keywords) {
        $kjson = json.append($kjson, "", $word);
    }
    $vjson = json.set($vjson, "/keywords", $kjson);
    $vjson = json.set($vjson, "/description", $ver.description);
    $vjson = json.set($vjson, "/publishedAt", $ver.publishedAt);
    if (flatdb.has($out, versionPtr($name, $ver.version))) {
        def old as json.Value init flatdb.get($out, versionPtr($name, $ver.version));
        for (def field in ["/repoId", "/repoOwnerId", "/repoOwner"]) {
            if (json.has($old, $field)) {
                $vjson = json.set($vjson, $field, json.get($old, $field));
            }
        }
    }
    $out = flatdb.set($out, versionPtr($name, $ver.version), $vjson);
    return $out;
}

# carriedOver fills `yanked`, `license` and `keywords` from the record `ver`
# replaces, where `ver` leaves them unset. A new version is returned unchanged.
func carriedOver(db as flatdb.DB, name as string, ver as DeckVersion) {
    if (not flatdb.has($db, versionPtr($name, $ver.version))) {
        return $ver;
    }
    def old as json.Value init flatdb.get($db, versionPtr($name, $ver.version));
    def out as DeckVersion init $ver;
    if (not $out.yanked) {
        $out.yanked = recordBool($old, "/yanked");
    }
    if ($out.license == "") {
        $out.license = recordString($old, "/license");
    }
    if (len($out.keywords) == 0) {
        $out.keywords = recordStrings($old, "/keywords");
    }
    return $out;
}

/**
 * Remove one deck version, returning a fresh DB. Errors if that version does
 * not exist (guard with `hasVersion`). The deck record is kept even when its
 * last version is removed.
 * @param db {flatdb.DB} the store to edit
 * @param name {string} the deck name
 * @param version {string} the version to remove
 * @return {flatdb.DB} a fresh store without that version
 * @throws {Error} when the version does not exist
 */
export func removeVersion(db as flatdb.DB, name as string, version as string) {
    return flatdb.remove($db, versionPtr($name, $version));
}

/**
 * Remove a whole deck (all its versions), its trusted-publisher binding and its
 * lookup counts, returning a fresh DB. Errors if the deck does not exist (guard with
 * `hasDeck`). A binding left behind would let the bound repository publish the
 * name again as a first publish.
 * @param db {flatdb.DB} the store to edit
 * @param name {string} the deck name
 * @return {flatdb.DB} a fresh store without that deck
 * @throws {Error} when the deck does not exist
 */
export func removeDeck(db as flatdb.DB, name as string) {
    def out as flatdb.DB init flatdb.remove($db, deckPtr($name));
    if (flatdb.has($out, bindingPtr($name))) {
        $out = flatdb.remove($out, bindingPtr($name));
    }
    # Counts left behind would be inherited by a later deck of the same name.
    if (flatdb.has($out, statsPtr($name))) {
        $out = flatdb.remove($out, statsPtr($name));
    }
    return $out;
}

/**
 * Drop every credential delegated under a scope: its CI tokens, and the
 * trusted-publisher bindings of the decks under it. Used on scope reassignment,
 * so the old owner's pipelines cannot publish under the new owner's name.
 * @param db {flatdb.DB} the store to edit
 * @param scope {string} the scope, without its "@"
 * @return {flatdb.DB} a fresh store without them
 */
export func dropDelegations(db as flatdb.DB, scope as string) {
    def folded as string init deckname.fold($scope);
    def out as flatdb.DB init $db;
    for (def print in listCiTokens($db)) {
        if (deckname.fold(getCiToken($db, $print).scope) == $folded) {
            $out = flatdb.remove($out, ciTokenPtr($print));
        }
    }
    for (def key in listBindings($db)) {
        if (bindingScopeOf($key) == $folded) {
            $out = flatdb.remove($out, bindingPtr($key));
        }
    }
    return $out;
}

# notFound builds a Resolution for a deck/constraint that did not resolve.
func notFound(name as string) {
    return Resolution{
        found: false,
        name: $name,
        version: "",
        kind: KIND_TARGZ,
        url: "",
        ref: "",
        commit: "",
        checksum: "",
        description: ""
    };
}

# recordString reads an optional string field off a record, yielding "" when
# the field is absent.
func recordString(rec as json.Value, field as string) {
    if (json.has($rec, $field) and json.typeOf($rec, $field) == "string") {
        return json.asString($rec, $field);
    }
    return "";
}

# recordInt reads an optional integer field. Absent or not a number reads as 0.
func recordInt(rec as json.Value, field as string) {
    if (json.has($rec, $field) and json.typeOf($rec, $field) == "int") {
        return json.asInt($rec, $field);
    }
    return 0;
}

# The two kinds a scope's principal may be.
export def const SCOPE_USER as string init "user";
export def const SCOPE_ORG as string init "org";

# scopeKindOf normalises a kind, defaulting anything unrecognised to the
# narrower "user", so a typo cannot open a personal scope to an organisation.
func scopeKindOf(kind as string) {
    if ($kind == SCOPE_ORG) {
        return SCOPE_ORG;
    }
    return SCOPE_USER;
}

# recordKindOfScope reads a namespace record's kind. Absent reads as "user".
func recordKindOfScope(rec as json.Value) {
    if (not json.has($rec, "/kind")) {
        return SCOPE_USER;
    }
    return scopeKindOf(json.asString($rec, "/kind"));
}

# recordStrings reads an optional array of strings. Absent reads as empty.
func recordStrings(rec as json.Value, field as string) {
    def out as list of string init [];
    if (not json.has($rec, $field)) {
        return $out;
    }
    def n as int init json.length($rec, $field);
    def i as int init 0;
    while ($i < $n) {
        $out[] = json.asString($rec, $field + "/" + convert.toString($i));
        $i = $i + 1;
    }
    return $out;
}

# recordMap reads an optional object of string values into a map.
func recordMap(rec as json.Value, field as string) {
    def out as map of string to string init {};
    if (not json.has($rec, $field)) {
        return $out;
    }
    for (def key in json.keys($rec, $field)) {
        $out[$key] = recordString($rec, $field + "/" + ptrEscape($key));
    }
    return $out;
}

# recordBool reads an optional boolean field. Absent reads as false.
func recordBool(rec as json.Value, field as string) {
    if (json.has($rec, $field) and json.typeOf($rec, $field) == "bool") {
        return json.asBool($rec, $field);
    }
    return false;
}

# recordKind reads a version record's delivery kind. An absent or empty `kind`
# reads as KIND_TARGZ (the specification's compatibility rule).
func recordKind(rec as json.Value) {
    def k as string init recordString($rec, "/kind");
    if ($k == "") {
        return KIND_TARGZ;
    }
    return $k;
}

/**
 * Return a published version's runtime requirements as a map of deck name to
 * version constraint. Empty when the version has no requirements or predates the
 * field. Scoped dependency names (`@scope/deck`) are returned unescaped.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {map of string to string} the version's requirements
 */
export func versionRequires(db as flatdb.DB, name as string, version as string) {
    def out as map of string to string init {};
    def reqPtr as string init versionPtr($name, $version) + "/requires";
    if (not flatdb.has($db, $reqPtr)) {
        return $out;
    }
    for (def key in flatdb.keys($db, $reqPtr)) {
        $out[$key] = json.asString(flatdb.get($db, $reqPtr + "/" + ptrEscape($key)));
    }
    return $out;
}

/**
 * Return a published version's `[engines]` as a map of engine name to version
 * range. Empty when the version declares none (imposes no engine restriction)
 * or predates the field.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {map of string to string} the version's engine allowlist
 */
export func versionEngines(db as flatdb.DB, name as string, version as string) {
    def out as map of string to string init {};
    def engPtr as string init versionPtr($name, $version) + "/engines";
    if (not flatdb.has($db, $engPtr)) {
        return $out;
    }
    for (def key in flatdb.keys($db, $engPtr)) {
        $out[$key] = json.asString(flatdb.get($db, $engPtr + "/" + ptrEscape($key)));
    }
    return $out;
}

/**
 * Return a published version's keywords, as normalised at publish time. Absent
 * reads as empty.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {list of string} the version's keywords
 */
export func versionKeywords(db as flatdb.DB, name as string, version as string) {
    def out as list of string init [];
    def at as string init versionPtr($name, $version) + "/keywords";
    if (not flatdb.has($db, $at)) {
        return $out;
    }
    def arr as json.Value init flatdb.get($db, $at);
    for (def i as int init 0; $i < json.length($arr, ""); $i = $i + 1) {
        $out[] = json.asString($arr, "/" + convert.toString($i));
    }
    return $out;
}

/**
 * Return a published version's declared host capabilities (`net` / `exec` /
 * `sql`). Empty when the version declares none, which means its code runs on any
 * build including `jennifer-tiny`.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {list of string} the version's capability set
 */
export func versionCapabilities(db as flatdb.DB, name as string, version as string) {
    def out as list of string init [];
    def capPtr as string init versionPtr($name, $version) + "/capabilities";
    if (not flatdb.has($db, $capPtr)) {
        return $out;
    }
    def arr as json.Value init flatdb.get($db, $capPtr);
    for (def i as int init 0; $i < json.length($arr, ""); $i = $i + 1) {
        $out[] = json.asString($arr, "/" + convert.toString($i));
    }
    return $out;
}

# --- namespace registry -----------------------------------------------------

# namespacePtr is the JSON Pointer of a registered namespace record, folded and
# escaped like deck pointers. Unescaped, `acme/subject` would point inside the
# `acme` record and `hasNamespace` would accept a scope that does not exist.
func namespacePtr(scope as string) {
    return "/namespaces/" + ptrEscape(deckname.fold($scope));
}

/**
 * Report whether a scope (the `@scope` of a scoped deck name, without the `@`)
 * is registered in the namespace registry. A scoped deck may only be published
 * under a registered scope.
 * @param db {flatdb.DB} the store to read
 * @param scope {string} the scope name (e.g. "jennifer")
 * @return {bool} true when the scope is registered
 */
export func hasNamespace(db as flatdb.DB, scope as string) {
    return flatdb.has($db, namespacePtr($scope));
}

/**
 * List every registered namespace scope, in document order.
 * @param db {flatdb.DB} the store to read
 * @return {list of string} the registered scopes (empty when none)
 */
export func listNamespaces(db as flatdb.DB) {
    if (not flatdb.has($db, "/namespaces")) {
        def none as list of string init [];
        return $none;
    }
    return flatdb.keys($db, "/namespaces");
}

/**
 * Who owns a scope. Ownership binds to the identity provider's stable subject
 * identifier, never to a login (specification 8.1), since a login released by
 * a rename can be claimed by somebody else.
 *
 * An empty `subject` means the scope is operator-held: registered, so nobody
 * may claim it, and bound to no principal, so nobody may write under it. A
 * reservation is in this state, as is a scope whose owner was removed.
 * @field scope {string} the folded scope name
 * @field provider {string} the identity provider that issued the subject ("" when unowned)
 * @field subject {string} the provider's stable subject identifier ("" when unowned)
 * @field login {string} the owner's username, a display label refreshed on each login
 * @field registeredAt {string} when the scope was registered (Unix seconds as text)
 * @field kind {string} `"user"` when `subject` is a person, `"org"` when it is an
 *     organisation the provider can be asked about (8.7); absent reads as `"user"`
 * @field coOwners {list of string} additional principals that may write under
 *     this scope, as subject ids under the same `provider`; empty for one owner
 */
export def struct Namespace {
    scope as string,
    provider as string,
    subject as string,
    login as string,
    registeredAt as string,
    kind as string,
    coOwners as list of string
};

/**
 * Register or re-register a namespace scope, returning a fresh DB. The scope
 * name in `ns` is folded before it is written.
 *
 * Re-registering replaces the record; that is how an operator reassigns a scope
 * after a dispute or a departure (specification 10).
 * @param db {flatdb.DB} the store to edit
 * @param ns {Namespace} the scope and its owner
 * @return {flatdb.DB} a fresh store with the scope registered
 */
export func registerNamespace(db as flatdb.DB, ns as Namespace) {
    def out as flatdb.DB init $db;
    if (not flatdb.has($out, "/namespaces")) {
        $out = flatdb.set($out, "/namespaces", json.map());
    }
    def rec as json.Value init json.map();
    $rec = json.set($rec, "/scope", deckname.fold($ns.scope));
    $rec = json.set($rec, "/provider", $ns.provider);
    $rec = json.set($rec, "/subject", $ns.subject);
    $rec = json.set($rec, "/login", $ns.login);
    $rec = json.set($rec, "/registeredAt", $ns.registeredAt);
    $rec = json.set($rec, "/kind", scopeKindOf($ns.kind));
    def owners as json.Value init json.list();
    for (def other in $ns.coOwners) {
        $owners = json.append($owners, "", $other);
    }
    $rec = json.set($rec, "/coOwners", $owners);
    return flatdb.set($out, namespacePtr($ns.scope), $rec);
}

/**
 * Read a namespace record. Absent fields read as empty, so a record without
 * ownership fields yields an operator-held scope. Guard with `hasNamespace`
 * first.
 * @param db {flatdb.DB} the store to read
 * @param scope {string} the scope name
 * @return {Namespace} the record
 * @throws {Error} when the scope is not registered
 */
export func getNamespace(db as flatdb.DB, scope as string) {
    def rec as json.Value init flatdb.get($db, namespacePtr($scope));
    return Namespace{
        scope: deckname.fold($scope),
        provider: recordString($rec, "/provider"),
        subject: recordString($rec, "/subject"),
        login: recordString($rec, "/login"),
        registeredAt: recordString($rec, "/registeredAt"),
        kind: recordKindOfScope($rec),
        coOwners: recordStrings($rec, "/coOwners")
    };
}

/**
 * Report whether a principal owns a scope. Every write under a scope asks this
 * (specification 2.2). It reads only the recorded binding, so a rename does not
 * move a scope and a released username does not inherit one.
 *
 * An unowned scope answers false for everybody, including a caller with empty
 * credentials.
 * @param db {flatdb.DB} the store to read
 * @param scope {string} the scope name
 * @param provider {string} the identity provider that authenticated the caller
 * @param subject {string} the caller's stable subject identifier
 * @return {bool} true when that principal owns the scope
 */
export func ownsNamespace(db as flatdb.DB, scope as string, provider as string, subject as string) {
    if ($provider == "" or $subject == "") {
        return false;
    }
    if (not hasNamespace($db, $scope)) {
        return false;
    }
    def ns as Namespace init getNamespace($db, $scope);
    if (not ($ns.provider == $provider)) {
        return false;
    }
    if ($ns.subject == $subject) {
        return true;
    }
    # A co-owner writes as the owner does. Co-owners are bare subject ids under
    # the same provider, with no login stored, since a login would go stale on
    # rename.
    for (def other in $ns.coOwners) {
        if ($other == $subject) {
            return true;
        }
    }
    return false;
}

/**
 * Remove a registered namespace scope, returning a fresh DB. Errors if the
 * scope is not registered (guard with `hasNamespace`).
 * @param db {flatdb.DB} the store to edit
 * @param scope {string} the scope name to remove
 * @return {flatdb.DB} a fresh store without that scope
 * @throws {Error} when the scope is not registered
 */
export func removeNamespace(db as flatdb.DB, scope as string) {
    return flatdb.remove($db, namespacePtr($scope));
}

# --- refresh tokens ---------------------------------------------------------

# refreshPtr is the JSON Pointer of one refresh-token record, keyed by the
# token's fingerprint.
func refreshPtr(fingerprint as string) {
    return "/refreshTokens/" + ptrEscape($fingerprint);
}

/**
 * A stored refresh token: who it belongs to and when it stops working. The
 * token itself is never stored, only its fingerprint (the map key), so a leaked
 * database holds no live credentials.
 * @field subject {string} the provider subject id this token authenticates
 * @field login {string} the provider login, a display label refreshed on each use
 * @field expiresAt {int} when the token stops working (Unix seconds)
 * @field orgs {map of string to string} folded organisation login to provider id,
 *     as captured at login
 * @field orgsCheckedAt {int} when `orgs` was read at login (Unix seconds); absent
 *     reads as 0
 */
export def struct Refresh {
    subject as string,
    login as string,
    expiresAt as int,
    orgs as map of string to string,
    orgsCheckedAt as int
};

/**
 * Record a refresh token by fingerprint, returning a fresh DB.
 * @param db {flatdb.DB} the store to edit
 * @param fingerprint {string} the token's fingerprint, never the token
 * @param rec {Refresh} the identity and expiry it authenticates
 * @return {flatdb.DB} a fresh store with the token recorded
 */
export func putRefresh(db as flatdb.DB, fingerprint as string, rec as Refresh) {
    def out as flatdb.DB init $db;
    if (not flatdb.has($out, "/refreshTokens")) {
        $out = flatdb.set($out, "/refreshTokens", json.map());
    }
    def rj as json.Value init json.map();
    $rj = json.set($rj, "/subject", $rec.subject);
    $rj = json.set($rj, "/login", $rec.login);
    $rj = json.set($rj, "/expiresAt", $rec.expiresAt);
    def ids as json.Value init json.map();
    for (def name in $rec.orgs) {
        $ids = json.set($ids, "/" + ptrEscape($name), $rec.orgs[$name]);
    }
    $rj = json.set($rj, "/orgs", $ids);
    $rj = json.set($rj, "/orgsCheckedAt", $rec.orgsCheckedAt);
    return flatdb.set($out, refreshPtr($fingerprint), $rj);
}

/**
 * Report whether a refresh-token fingerprint is on record.
 * @param db {flatdb.DB} the store to read
 * @param fingerprint {string} the token's fingerprint
 * @return {bool} true when the token is known
 */
export func hasRefresh(db as flatdb.DB, fingerprint as string) {
    return flatdb.has($db, refreshPtr($fingerprint));
}

/**
 * Read a refresh-token record. Guard with `hasRefresh` first.
 * @param db {flatdb.DB} the store to read
 * @param fingerprint {string} the token's fingerprint
 * @return {Refresh} the record
 * @throws {Error} when the fingerprint is unknown
 */
export func getRefresh(db as flatdb.DB, fingerprint as string) {
    def rec as json.Value init flatdb.get($db, refreshPtr($fingerprint));
    return Refresh{
        subject: recordString($rec, "/subject"),
        login: recordString($rec, "/login"),
        expiresAt: recordInt($rec, "/expiresAt"),
        orgs: recordMap($rec, "/orgs"),
        orgsCheckedAt: recordInt($rec, "/orgsCheckedAt")
    };
}

/**
 * Forget one refresh token, returning a fresh DB. A no-op when it is unknown,
 * so a logout or a rotation never has to check first.
 * @param db {flatdb.DB} the store to edit
 * @param fingerprint {string} the token's fingerprint
 * @return {flatdb.DB} a fresh store without that token
 */
export func deleteRefresh(db as flatdb.DB, fingerprint as string) {
    if (not hasRefresh($db, $fingerprint)) {
        return $db;
    }
    return flatdb.remove($db, refreshPtr($fingerprint));
}

/**
 * How many refresh tokens an account currently holds. Asked before a revoke so
 * the operational log records how many were dropped; "revoked 0" usually means
 * the wrong account id.
 * @param db {flatdb.DB} the store to read
 * @param subject {string} the subject id
 * @return {int} the number of live refresh tokens held by that account
 */
export func countRefresh(db as flatdb.DB, subject as string) {
    if (not flatdb.has($db, "/refreshTokens")) {
        return 0;
    }
    def n as int init 0;
    for (def key in flatdb.keys($db, "/refreshTokens")) {
        if (getRefresh($db, $key).subject == $subject) {
            $n = $n + 1;
        }
    }
    return $n;
}

/**
 * Forget every refresh token belonging to an account, its sealed forge
 * credential and its forge link, returning a fresh DB. The operator path of
 * specification 8.5.
 * @param db {flatdb.DB} the store to edit
 * @param subject {string} the subject id to revoke
 * @return {flatdb.DB} a fresh store without that account's tokens
 */
export func revokeAccount(db as flatdb.DB, subject as string) {
    # A revoked account must not leave a forge token the registry could act with.
    def out as flatdb.DB init deleteForgeLink(deleteForgeToken($db, $subject), $subject);
    if (not flatdb.has($out, "/refreshTokens")) {
        return $out;
    }
    for (def key in flatdb.keys($db, "/refreshTokens")) {
        if (getRefresh($db, $key).subject == $subject) {
            $out = flatdb.remove($out, refreshPtr($key));
        }
    }
    return $out;
}

func forgeTokenPtr(subject as string) {
    return "/forgeTokens/" + ptrEscape($subject);
}

/**
 * Record an account's forge credential, sealed, returning a fresh DB.
 *
 * Kept only under `login` source authority, where identity and forge are one
 * service, to ask the forge whether this account may push to a repository
 * (specification 7.1, route A). One per account; a later login replaces it.
 * @param db {flatdb.DB} the store to edit
 * @param subject {string} the subject id
 * @param sealed {string} the credential as `forgecred.seal` produced it
 * @param storedAt {int} when it was recorded (Unix seconds)
 * @return {flatdb.DB} a fresh store with the credential recorded
 */
export func putForgeToken(db as flatdb.DB, subject as string, sealed as string, storedAt as int) {
    def out as flatdb.DB init $db;
    if (not flatdb.has($out, "/forgeTokens")) {
        $out = flatdb.set($out, "/forgeTokens", json.map());
    }
    def rec as json.Value init json.map();
    $rec = json.set($rec, "/sealed", $sealed);
    $rec = json.set($rec, "/storedAt", $storedAt);
    return flatdb.set($out, forgeTokenPtr($subject), $rec);
}

/**
 * An account's sealed forge credential, or "" when none is on record.
 * @param db {flatdb.DB} the store to read
 * @param subject {string} the subject id
 * @return {string} the sealed credential, or ""
 */
export func getForgeToken(db as flatdb.DB, subject as string) {
    if (not flatdb.has($db, forgeTokenPtr($subject) + "/sealed")) {
        return "";
    }
    return json.asString(flatdb.get($db, forgeTokenPtr($subject) + "/sealed"), "");
}

/**
 * Forget an account's forge credential, returning a fresh DB. A no-op when there
 * is none.
 * @param db {flatdb.DB} the store to edit
 * @param subject {string} the subject id
 * @return {flatdb.DB} a fresh store without it
 */
export func deleteForgeToken(db as flatdb.DB, subject as string) {
    if (not flatdb.has($db, forgeTokenPtr($subject))) {
        return $db;
    }
    return flatdb.remove($db, forgeTokenPtr($subject));
}

/**
 * The forge account a subject was linked to at login (12.5), for `service`
 * source authority: the forge's immutable account id, and its username then.
 * @field forgeId {string} the forge account id; "" when there is no link
 * @field forgeLogin {string} the forge username when the link was made
 * @field linkedAt {int} when (Unix seconds)
 */
export def struct ForgeLink {
    forgeId as string,
    forgeLogin as string,
    linkedAt as int
};

func forgeLinkPtr(subject as string) {
    return "/forgeLinks/" + ptrEscape($subject);
}

/**
 * Record a subject's forge link, replacing any earlier one.
 * @param db {flatdb.DB} the store to edit
 * @param subject {string} the identity-provider subject
 * @param link {ForgeLink} the forge account it maps to
 * @return {flatdb.DB} a fresh store
 */
export func putForgeLink(db as flatdb.DB, subject as string, link as ForgeLink) {
    def out as flatdb.DB init $db;
    if (not flatdb.has($out, "/forgeLinks")) {
        $out = flatdb.set($out, "/forgeLinks", json.map());
    }
    def rec as json.Value init json.map();
    $rec = json.set($rec, "/forgeId", $link.forgeId);
    $rec = json.set($rec, "/forgeLogin", $link.forgeLogin);
    $rec = json.set($rec, "/linkedAt", $link.linkedAt);
    return flatdb.set($out, forgeLinkPtr($subject), $rec);
}

/**
 * A subject's forge link; `forgeId` is "" when there is none.
 * @param db {flatdb.DB} the store to read
 * @param subject {string} the identity-provider subject
 * @return {ForgeLink} the link
 */
export func getForgeLink(db as flatdb.DB, subject as string) {
    if (not flatdb.has($db, forgeLinkPtr($subject))) {
        return ForgeLink{forgeId: "", forgeLogin: "", linkedAt: 0};
    }
    def rec as json.Value init flatdb.get($db, forgeLinkPtr($subject));
    return ForgeLink{
        forgeId: recordString($rec, "/forgeId"),
        forgeLogin: recordString($rec, "/forgeLogin"),
        linkedAt: recordInt($rec, "/linkedAt")
    };
}

/**
 * Forget a subject's forge link. A no-op when there is none.
 * @param db {flatdb.DB} the store to edit
 * @param subject {string} the identity-provider subject
 * @return {flatdb.DB} a fresh store
 */
export func deleteForgeLink(db as flatdb.DB, subject as string) {
    if (not flatdb.has($db, forgeLinkPtr($subject))) {
        return $db;
    }
    return flatdb.remove($db, forgeLinkPtr($subject));
}

/**
 * Drop every refresh token that expired at or before `now`, returning a fresh
 * DB. Called on each issue so the table cannot grow without bound.
 * @param db {flatdb.DB} the store to edit
 * @param now {int} the current time (Unix seconds)
 * @return {flatdb.DB} a fresh store without the expired tokens
 */
export func purgeExpiredRefresh(db as flatdb.DB, now as int) {
    if (not flatdb.has($db, "/refreshTokens")) {
        return $db;
    }
    def out as flatdb.DB init $db;
    for (def key in flatdb.keys($db, "/refreshTokens")) {
        if (getRefresh($db, $key).expiresAt <= $now) {
            $out = flatdb.remove($out, refreshPtr($key));
        }
    }
    return $out;
}

/**
 * Resolve a deck name and version constraint to the best published version.
 * Returns a Resolution with `found` false when the deck is absent or no
 * published version satisfies the constraint.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param constraintExpr {string} the version constraint (e.g. "^1.2.0", "*")
 * @return {Resolution} the resolution outcome
 */
export func resolve(db as flatdb.DB, name as string, constraintExpr as string) {
    if (not hasDeck($db, $name)) {
        return notFound($name);
    }
    # Live versions only: a yanked version stays fetchable for a lockfile but is
    # never chosen by a new resolution (specification 9).
    def picked as string init constraint.best(listLiveVersions($db, $name), $constraintExpr);
    if ($picked == "") {
        return notFound($name);
    }
    def v as DeckVersion init getVersionRecord($db, $name, $picked);
    return Resolution{
        found: true,
        name: $name,
        version: $v.version,
        kind: $v.kind,
        url: $v.url,
        ref: $v.ref,
        commit: $v.commit,
        checksum: $v.checksum,
        description: $v.description
    };
}

# --- trusted publisher bindings ---------------------------------------------

# bindingPtr is the JSON Pointer of a trusted-publisher binding, keyed on the
# folded deck name, or on `@scope` for one covering a whole scope (8.9).
func bindingPtr(deck as string) {
    return "/publishers/" + ptrEscape(deckname.fold($deck));
}

/**
 * Record a trusted-publisher binding, returning a fresh DB. One binding per
 * deck; re-registering replaces it (how a repository migration is done).
 * @param db {flatdb.DB} the store to edit
 * @param b {trustpub.Binding} the binding to record
 * @return {flatdb.DB} a fresh store carrying it
 */
export func putBinding(db as flatdb.DB, b as trustpub.Binding) {
    # The root is created on first write; readers treat a missing `/publishers`
    # as no bindings.
    def out as flatdb.DB init $db;
    if (not flatdb.has($out, "/publishers")) {
        $out = flatdb.set($out, "/publishers", json.map());
    }
    def rec as json.Value init json.map();
    $rec = json.set($rec, "/provider", $b.provider);
    $rec = json.set($rec, "/repositoryId", $b.repositoryId);
    $rec = json.set($rec, "/repository", $b.repository);
    $rec = json.set($rec, "/workflow", $b.workflow);
    $rec = json.set($rec, "/refPattern", $b.refPattern);
    $rec = json.set($rec, "/deck", deckname.fold($b.deck));
    $rec = json.set($rec, "/pending", $b.pending);
    $rec = json.set($rec, "/createdAt", $b.createdAt);
    return flatdb.set($out, bindingPtr($b.deck), $rec);
}

/**
 * Report whether a deck has a trusted-publisher binding.
 * @param db {flatdb.DB} the store to read
 * @param deck {string} the deck name
 * @return {bool} true when one is registered
 */
export func hasBinding(db as flatdb.DB, deck as string) {
    return flatdb.has($db, bindingPtr($deck));
}

/**
 * Read a deck's trusted-publisher binding. Returns a zero `Binding` when none is
 * registered, whose empty `repositoryId` can never match a token (8.9), so an
 * unguarded caller fails closed.
 * @param db {flatdb.DB} the store to read
 * @param deck {string} the deck name
 * @return {trustpub.Binding} the binding, or a zero value
 */
export func getBinding(db as flatdb.DB, deck as string) {
    def out as trustpub.Binding init trustpub.Binding{
        provider: "",
        repositoryId: "",
        repository: "",
        workflow: "",
        refPattern: "",
        deck: deckname.fold($deck),
        pending: false,
        createdAt: ""
    };
    if (not flatdb.has($db, bindingPtr($deck))) {
        return $out;
    }
    def rec as json.Value init flatdb.get($db, bindingPtr($deck));
    $out.provider = recordString($rec, "/provider");
    $out.repositoryId = recordString($rec, "/repositoryId");
    $out.repository = recordString($rec, "/repository");
    $out.workflow = recordString($rec, "/workflow");
    $out.refPattern = recordString($rec, "/refPattern");
    if (json.has($rec, "/pending")) {
        $out.pending = json.asBool($rec, "/pending");
    }
    $out.createdAt = recordString($rec, "/createdAt");
    return $out;
}

/**
 * Whether a binding key names a whole scope (`@scope`) rather than a deck.
 * @param key {string} a binding key, as `Binding.deck` holds it
 * @return {bool} true for `@scope`
 */
export func isScopeKey(key as string) {
    return strings.startsWith($key, "@") and not strings.contains($key, "/");
}

/**
 * The scope a binding key falls under: the scope itself for `@scope`, the
 * deck's scope otherwise.
 * @param key {string} a binding key
 * @return {string} the folded scope, or ""
 */
export func bindingScopeOf(key as string) {
    if (isScopeKey($key)) {
        return deckname.fold(strings.substring($key, 1, len($key)));
    }
    return deckname.scopeOf($key);
}

/**
 * The binding that authorises trusted publishing of a deck (8.9): the deck's
 * own, else its scope's. A zero `Binding` (empty `repositoryId`) when neither
 * exists.
 * @param db {flatdb.DB} the store to read
 * @param deck {string} the deck name
 * @return {trustpub.Binding} the binding that applies
 */
export func bindingFor(db as flatdb.DB, deck as string) {
    if (hasBinding($db, $deck)) {
        return getBinding($db, $deck);
    }
    def scopeKey as string init "@" + deckname.scopeOf($deck);
    if (not ($scopeKey == "@") and hasBinding($db, $scopeKey)) {
        return getBinding($db, $scopeKey);
    }
    return getBinding($db, $deck);
}

/**
 * Forget a deck's trusted-publisher binding, returning a fresh DB. Cuts off a
 * compromised or retired repository.
 * @param db {flatdb.DB} the store to edit
 * @param deck {string} the deck name
 * @return {flatdb.DB} a fresh store without it
 */
export func removeBinding(db as flatdb.DB, deck as string) {
    if (not hasBinding($db, $deck)) {
        return $db;
    }
    return flatdb.remove($db, bindingPtr($deck));
}

/**
 * Every deck with a trusted-publisher binding, in stored order.
 * @param db {flatdb.DB} the store to read
 * @return {list of string} the deck names
 */
export func listBindings(db as flatdb.DB) {
    if (not flatdb.has($db, "/publishers")) {
        def none as list of string init [];
        return $none;
    }
    return flatdb.keys($db, "/publishers");
}

/**
 * Withdraw a version from new resolutions, or restore it, returning a fresh DB.
 * Yanking is not deletion (specification 9): the record stays, the code stays
 * fetchable, and a lockfile that pins the version keeps installing.
 * @param db {flatdb.DB} the store to edit
 * @param name {string} the deck name
 * @param version {string} the version to withdraw or restore
 * @param yanked {bool} true to withdraw, false to restore
 * @return {flatdb.DB} a fresh store with the flag set
 * @throws {Error} when that version does not exist
 */
export func setYanked(db as flatdb.DB, name as string, version as string, yanked as bool) {
    def rec as json.Value init getVersionJson($db, $name, $version);
    $rec = json.set($rec, "/yanked", $yanked);
    return flatdb.set($db, versionPtr($name, $version), $rec);
}

/**
 * Report whether a version is yanked. An unknown version is not yanked; callers
 * that care about existence check `hasVersion` first.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {bool} true when the version is withdrawn
 */
export func isYanked(db as flatdb.DB, name as string, version as string) {
    # Read the flag directly; building the whole record cost a third of every
    # listing.
    def ptr as string init versionPtr($name, $version) + "/yanked";
    if (not flatdb.has($db, $ptr)) {
        return false;
    }
    return json.asBool(flatdb.get($db, $ptr), "");
}

/**
 * Where a version was published from, as the forge identified it (specification
 * 6.4, 7.3). Recorded by `POST /publish`; a record written by `deckadmin add`
 * has none, and every field reads as "".
 * @field repoId {string} the forge's immutable repository id
 * @field repoOwnerId {string} the immutable id of the account that owned it
 * @field repoOwner {string} that account's name at publish, a display label
 */
export def struct Provenance {
    repoId as string,
    repoOwnerId as string,
    repoOwner as string
};

# numericId writes a forge id as a JSON number (section 3 types them `int`), and
# returns false for anything that is not plain digits, which is then omitted.
func numericId(s as string) {
    if ($s == "" or len($s) > 18) {
        return false;
    }
    for (def c in strings.chars($s)) {
        if (not strings.contains("0123456789", $c)) {
            return false;
        }
    }
    return true;
}

/**
 * Record a version's provenance. Empty or non-numeric ids are left out.
 * @param db {flatdb.DB} the store to edit
 * @param name {string} the deck name
 * @param version {string} an existing version
 * @param p {Provenance} what the forge reported at publish
 * @return {flatdb.DB} a fresh store
 */
export func putProvenance(db as flatdb.DB, name as string, version as string, p as Provenance) {
    def rec as json.Value init getVersionJson($db, $name, $version);
    if (numericId($p.repoId)) {
        $rec = json.set($rec, "/repoId", convert.toInt($p.repoId));
    }
    if (numericId($p.repoOwnerId)) {
        $rec = json.set($rec, "/repoOwnerId", convert.toInt($p.repoOwnerId));
    }
    if (not ($p.repoOwner == "")) {
        $rec = json.set($rec, "/repoOwner", $p.repoOwner);
    }
    return flatdb.set($db, versionPtr($name, $version), $rec);
}

# idField reads a numeric id field as text, "" when absent or not a number.
func idField(rec as json.Value, field as string) {
    if (not json.has($rec, $field) or not (json.typeOf($rec, $field) == "int")) {
        return "";
    }
    return convert.toString(json.asInt($rec, $field));
}

/**
 * A version's provenance; all fields "" when none was recorded.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {Provenance} the recorded ids and label
 */
export func provenanceOf(db as flatdb.DB, name as string, version as string) {
    def rec as json.Value init getVersionJson($db, $name, $version);
    return Provenance{
        repoId: idField($rec, "/repoId"),
        repoOwnerId: idField($rec, "/repoOwnerId"),
        repoOwner: recordString($rec, "/repoOwner")
    };
}

/**
 * The newest earlier version published from the same repository under a
 * different owner (6.4), or "" when there is none. A repository that changed
 * hands keeps its id, so the owner id is what tells.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param repoId {string} the repository the new version comes from
 * @param ownerId {string} its owner now
 * @return {string} that earlier version, or ""
 */
export func ownerChangeOf(db as flatdb.DB, name as string, repoId as string, ownerId as string) {
    if ($repoId == "" or $ownerId == "" or not hasDeck($db, $name)) {
        return "";
    }
    for (def v in listVersionsDescending($db, $name)) {
        def p as Provenance init provenanceOf($db, $name, $v);
        if ($p.repoId == $repoId and not ($p.repoOwnerId == "") and
            not ($p.repoOwnerId == $ownerId)) {
            return $v;
        }
    }
    return "";
}

/**
 * Every live (not yanked) version of a deck, in stored order: what a resolution
 * chooses from. `listVersions` returns yanked versions too, for deck pages and
 * lockfile-pinned fetches.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @return {list of string} the version strings that are not yanked
 */
export func listLiveVersions(db as flatdb.DB, name as string) {
    def out as list of string init [];
    for (def v in listVersions($db, $name)) {
        if (not isYanked($db, $name, $v)) {
            $out[] = $v;
        }
    }
    return $out;
}

# --- CI tokens ---------------------------------------------------------------

# ciTokenPtr is the JSON Pointer of a CI token record, keyed on the token's
# SHA-256. As with refresh tokens, the token itself is never stored.
func ciTokenPtr(fingerprint as string) {
    return "/ciTokens/" + ptrEscape($fingerprint);
}

/**
 * Record a CI token, returning a fresh DB.
 * @param db {flatdb.DB} the store to edit
 * @param t {citoken.Token} the token record (its fingerprint, never the token)
 * @return {flatdb.DB} a fresh store carrying it
 */
export func putCiToken(db as flatdb.DB, t as citoken.Token) {
    def out as flatdb.DB init $db;
    if (not flatdb.has($out, "/ciTokens")) {
        $out = flatdb.set($out, "/ciTokens", json.map());
    }
    def rec as json.Value init json.map();
    $rec = json.set($rec, "/name", $t.name);
    $rec = json.set($rec, "/scope", $t.scope);
    $rec = json.set($rec, "/deck", $t.deck);
    $rec = json.set($rec, "/provider", $t.provider);
    $rec = json.set($rec, "/subject", $t.subject);
    $rec = json.set($rec, "/createdAt", $t.createdAt);
    $rec = json.set($rec, "/expiresAt", $t.expiresAt);
    $rec = json.set($rec, "/lastUsedAt", $t.lastUsedAt);
    return flatdb.set($out, ciTokenPtr($t.fingerprint), $rec);
}

/**
 * Read a CI token record by fingerprint. An unknown fingerprint yields a zero
 * `Token`, whose empty `fingerprint` `citoken.check` refuses, so an unguarded
 * caller fails closed.
 * @param db {flatdb.DB} the store to read
 * @param fingerprint {string} the token's SHA-256
 * @return {citoken.Token} the record, or a zero value
 */
export func getCiToken(db as flatdb.DB, fingerprint as string) {
    def out as citoken.Token init citoken.Token{
        fingerprint: "",
        name: "",
        scope: "",
        deck: "",
        provider: "",
        subject: "",
        createdAt: "",
        expiresAt: "",
        lastUsedAt: ""
    };
    if (not flatdb.has($db, ciTokenPtr($fingerprint))) {
        return $out;
    }
    def rec as json.Value init flatdb.get($db, ciTokenPtr($fingerprint));
    $out.fingerprint = $fingerprint;
    $out.name = recordString($rec, "/name");
    $out.scope = recordString($rec, "/scope");
    $out.deck = recordString($rec, "/deck");
    $out.provider = recordString($rec, "/provider");
    $out.subject = recordString($rec, "/subject");
    $out.createdAt = recordString($rec, "/createdAt");
    $out.expiresAt = recordString($rec, "/expiresAt");
    $out.lastUsedAt = recordString($rec, "/lastUsedAt");
    return $out;
}

/**
 * Forget one CI token, returning a fresh DB. A no-op when it is unknown.
 * @param db {flatdb.DB} the store to edit
 * @param fingerprint {string} the token to drop
 * @return {flatdb.DB} a fresh store without it
 */
export func deleteCiToken(db as flatdb.DB, fingerprint as string) {
    if (not flatdb.has($db, ciTokenPtr($fingerprint))) {
        return $db;
    }
    return flatdb.remove($db, ciTokenPtr($fingerprint));
}

/**
 * Every CI token fingerprint on record, in stored order.
 * @param db {flatdb.DB} the store to read
 * @return {list of string} the fingerprints
 */
export func listCiTokens(db as flatdb.DB) {
    if (not flatdb.has($db, "/ciTokens")) {
        def none as list of string init [];
        return $none;
    }
    return flatdb.keys($db, "/ciTokens");
}

/**
 * Stamp a CI token as used, returning a fresh DB. Recorded so an unused token
 * can be found and removed.
 * @param db {flatdb.DB} the store to edit
 * @param fingerprint {string} the token that authorised a write
 * @param now {string} the time (Unix seconds as text)
 * @return {flatdb.DB} a fresh store with the stamp updated
 */
export func touchCiToken(db as flatdb.DB, fingerprint as string, now as string) {
    if (not flatdb.has($db, ciTokenPtr($fingerprint))) {
        return $db;
    }
    def rec as json.Value init flatdb.get($db, ciTokenPtr($fingerprint));
    $rec = json.set($rec, "/lastUsedAt", $now);
    return flatdb.set($db, ciTokenPtr($fingerprint), $rec);
}

/**
 * Record a deck's README, returning a fresh DB. A no-op when the deck is absent.
 *
 * Held on the deck, not the version, and overwritten by each publish that
 * carries one, so the page shows the most recent README published. Stored verbatim as untrusted
 * publisher input; `webview` escapes it before rendering.
 * @param db {flatdb.DB} the store to edit
 * @param name {string} the deck name
 * @param readme {string} the file's contents ("" clears it)
 * @return {flatdb.DB} a fresh store carrying it
 */
export func putReadme(db as flatdb.DB, name as string, readme as string) {
    if (not flatdb.has($db, deckPtr($name))) {
        return $db;
    }
    def rec as json.Value init flatdb.get($db, deckPtr($name));
    $rec = json.set($rec, "/readme", $readme);
    return flatdb.set($db, deckPtr($name), $rec);
}

/**
 * A deck's README, or "" when none was recorded.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @return {string} the README source, unrendered and unescaped
 */
export func getReadme(db as flatdb.DB, name as string) {
    if (not flatdb.has($db, deckPtr($name))) {
        return "";
    }
    return recordString(flatdb.get($db, deckPtr($name)), "/readme");
}

/**
 * Add a co-owner to a scope, returning a fresh DB.
 *
 * A co-owner writes under the scope as the owner does, but the record still
 * names one `subject` as the principal it was granted to; reassigning that is
 * `registerNamespace`.
 *
 * Idempotent. An unowned (reserved) scope is left unchanged, so nobody can
 * write under a scope nobody holds.
 * @param db {flatdb.DB} the store to edit
 * @param scope {string} the scope
 * @param subject {string} the principal to add, under the scope's own provider
 * @return {flatdb.DB} a fresh store, or the original when nothing changed
 * @throws {Error} when the scope is not registered
 */
export func addCoOwner(db as flatdb.DB, scope as string, subject as string) {
    def ns as Namespace init getNamespace($db, $scope);
    if ($subject == "" or $ns.subject == "" or $ns.subject == $subject) {
        return $db;
    }
    for (def other in $ns.coOwners) {
        if ($other == $subject) {
            return $db;
        }
    }
    # A struct's list field cannot be appended to in place.
    def owners as list of string init $ns.coOwners;
    $owners[] = $subject;
    def out as Namespace init $ns;
    $out.coOwners = $owners;
    return registerNamespace($db, $out);
}

/**
 * Remove a co-owner from a scope, returning a fresh DB.
 *
 * The scope's own `subject` cannot be removed this way, since that would leave
 * decks nobody can yank; handing the scope on is `registerNamespace`.
 * @param db {flatdb.DB} the store to edit
 * @param scope {string} the scope
 * @param subject {string} the principal to remove
 * @return {flatdb.DB} a fresh store, or the original when nothing changed
 * @throws {Error} when the scope is not registered
 */
export func removeCoOwner(db as flatdb.DB, scope as string, subject as string) {
    def ns as Namespace init getNamespace($db, $scope);
    def kept as list of string init [];
    def found as bool init false;
    for (def other in $ns.coOwners) {
        if ($other == $subject) {
            $found = true;
        } else {
            $kept[] = $other;
        }
    }
    if (not $found) {
        return $db;
    }
    def out as Namespace init $ns;
    $out.coOwners = $kept;
    return registerNamespace($db, $out);
}

/**
 * Every principal that may write under a scope: the owner first, then any
 * co-owners. Empty when the scope is unregistered or reserved.
 * @param db {flatdb.DB} the store to read
 * @param scope {string} the scope
 * @return {list of string} the subject ids
 */
export func ownersOf(db as flatdb.DB, scope as string) {
    def out as list of string init [];
    if (not hasNamespace($db, $scope)) {
        return $out;
    }
    def ns as Namespace init getNamespace($db, $scope);
    if ($ns.subject == "") {
        return $out;
    }
    $out[] = $ns.subject;
    for (def other in $ns.coOwners) {
        $out[] = $other;
    }
    return $out;
}

# --- the write lock ----------------------------------------------------------

/**
 * A held write lock. Release it with `unlock`, through `defer` so it is
 * released however the block exits.
 * @field path {string} the lock's own path
 * @field holder {string} what was written into it, for diagnosing a stuck lock
 */
export def struct Lock {
    path as string,
    holder as string
};

# lockPathFor is the lock beside the database, named as `flatdb.lock` names it.
func lockPathFor(dbPath as string) {
    return $dbPath + ".lock";
}

# holderOf reads a lock's holder label, or "" when there is no lock to read.
func holderOf(path as string) {
    try {
        return fs.readString($path);
    } catch (err) {
        return "";
    }
}

/**
 * Take the registry's write lock, waiting for it if somebody else holds it.
 *
 * `flatdb.save` is crash-atomic but does not lock, so two writers that each
 * read, edit, and write back lose one edit. `deckadmin` run while the server is
 * up, or two concurrent publishes, is enough.
 *
 * This is `flatdb.lock`: an exclusive file beside the database whose content is
 * the holder label (`cat` it to diagnose a stuck lock). A lock older than 120 s
 * is treated as abandoned and broken, one waiter at a time and only while it
 * still holds the holder judged stale. A lock that cannot be created at all
 * (read-only mount, missing directory, wrong uid) fails at once with the reason.
 *
 * A held lock is waited for up to `flatdb`'s bound, 5 s (`LOCK_WAIT_MS`); past
 * it this throws rather than queueing, so a long `deckadmin` run makes a
 * concurrent publish fail instead of stall.
 *
 * The document must be read inside the lock as well as written, or the edit is
 * computed against a stale copy.
 * @param dbPath {string} the database path this lock guards
 * @return {Lock} the held lock
 * @throws {Error} kind "store" when the lock could not be taken: held past the
 *   5 s wait, or not creatable at all
 */
export func lock(dbPath as string) {
    try {
        def held as flatdb.Lock init flatdb.lock($dbPath);
        return Lock{path: $held.path, holder: $held.holder};
    } catch (err) {
        throw Error{
            kind: "store",
            message: "registry write lock: " + $err.message,
            file: "",
            line: 0,
            col: 0
        };
    }
}

/**
 * Who currently holds the write lock, or "" when it is free.
 * @param dbPath {string} the database the lock guards
 * @return {string} the holder label, or "" when unlocked
 */
export func lockHolder(dbPath as string) {
    return holderOf(lockPathFor($dbPath));
}

/**
 * Release a write lock. A release that finds a different holder (the lock was
 * broken and re-taken) leaves it alone.
 * @param held {Lock} the lock returned by `lock`
 */
export func unlock(held as Lock) {
    flatdb.unlock(flatdb.Lock{path: $held.path, holder: $held.holder});
    return null;
}

# --- lookup counts -----------------------------------------------------------

# statsPtr is the JSON Pointer of a deck's lookup-count record. A separate
# top-level table, so counting and publishing writes touch different subtrees
# and `getDeckJson`, which the API serves, carries no constantly changing member.
func statsPtr(name as string) {
    return "/stats/" + ptrEscape(deckname.fold($name));
}

/**
 * A deck's lookup-count record, or an empty object when it has never been
 * looked up, so `stats.summarise` answers with zeroes.
 * @param db {flatdb.DB} the store
 * @param name {string} the deck name
 * @return {json.Value} the record, possibly empty
 */
export func getStats(db as flatdb.DB, name as string) {
    if (not flatdb.has($db, statsPtr($name))) {
        return json.map();
    }
    return flatdb.get($db, statsPtr($name));
}

/**
 * Write a deck's lookup-count record, returning a fresh DB.
 * @param db {flatdb.DB} the store to edit
 * @param name {string} the deck name
 * @param rec {json.Value} the record to store
 * @return {flatdb.DB} a fresh store
 */
export func putStats(db as flatdb.DB, name as string, rec as json.Value) {
    def out as flatdb.DB init $db;
    if (not flatdb.has($out, "/stats")) {
        $out = flatdb.set($out, "/stats", json.map());
    }
    return flatdb.set($out, statsPtr($name), $rec);
}

/**
 * A deck's live versions, newest first: the ordered form of `listLiveVersions`,
 * for pages.
 * @param db {flatdb.DB} the store
 * @param name {string} the deck name
 * @return {list of string} the unyanked versions, highest first
 */
export func listLiveVersionsDescending(db as flatdb.DB, name as string) {
    def out as list of string init [];
    for (def v in listVersionsDescending($db, $name)) {
        if (not isYanked($db, $name, $v)) {
            $out[] = $v;
        }
    }
    return $out;
}
