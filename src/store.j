# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The deck-registry store: the server side of jvc, backing the deck repository
 * over a `flatdb` JSON document. A registry holds many decks; each deck holds
 * many published versions; each version records where its code lives, how to
 * pin it, a description, and when it was published. The document schema is:
 *
 *     { "decks": { "<name>": {
 *         "name": "...", "description": "...",
 *         "versions": { "<version>": {
 *             "version": "...", "kind": "git" | "tar.gz", "url": "...",
 *             "ref": "...", "commit": "...", "checksum": "...",
 *             "requires": { ... }, "engines": { ... }, "capabilities": [ ... ],
 *             "description": "...", "publishedAt": "..." } } } } }
 *
 * A version is delivered one of two ways, told apart by `kind`. A `"git"`
 * version lives in a repository and is pinned by `commit`, the SHA its `ref`
 * tag pointed at when it was published; git verifies object hashes on fetch, so
 * the commit is the integrity boundary and `checksum` is meaningless. A
 * `"tar.gz"` version is an uploaded artifact pinned by `checksum`, and the
 * reverse holds. A record with no `kind` predates the field and reads as
 * `"tar.gz"`.
 *
 * This module owns reading and editing that document (the HTTP surface lives in
 * `apiview` / `bin/serve`, the maintenance CLI in `admin` / `bin/deckadmin`).
 * Version resolution reuses the `constraint` module. Writers return a fresh DB
 * (flatdb value semantics); call `store.save` to persist.
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
use time;
use uuid;
import "flatdb.j" as flatdb;
import "semver.j" as semver;
import "./constraint.j" as constraint;
import "./deckname.j" as deckname;
import "./trustpub.j" as trustpub;
import "./citoken.j" as citoken;

# ptrEscape / ptrUnescape encode a name as one JSON Pointer reference token
# (RFC 6901: "~" -> "~0", "/" -> "~1"), so a scoped deck name such as
# "@jennifer/routeros" is a single key rather than a nested "/decks/@jennifer/
# routeros" path. Escaping happens in the pointer builders; listing unescapes.
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

# The shortest hex run git will read as an abbreviated object id, and the
# longest object id there is (SHA-256, for repositories using it). A name of
# this shape can be mistaken for an object, which is what `isObjectIdLike`
# exists to refuse.
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
 * digits. An abbreviated SHA is rejected deliberately - a version is pinned to
 * the whole hash, and a short prefix can turn ambiguous as a repository grows.
 * @param s {string} the candidate SHA
 * @return {bool} true when s is a full commit SHA
 */
export func isCommit(s as string) {
    return isLowerHex($s, COMMIT_LEN);
}

/**
 * Report whether a string could be read as a git **object id** rather than as
 * the name it is: 7 to 64 hex digits, in either case.
 *
 * This is the shape a `ref` must never have. A git name and a git object id
 * share one syntactic space, and where a forge or a client resolves a name
 * before an object - which the ref-or-sha `?ref=` parameter on every forge API
 * does by definition, and which `git fetch <remote> <name>` does on the wire -
 * a ref called `4a3b...` **stands in front of the commit of that id**. 
 * GitHub refuses such names at creation; GitLab,
 * Gitea, Forgejo and self-hosted servers do not, so the registry refuses them
 * on the way in rather than relying on the forge to have done it.
 *
 * Both cases are rejected because git's hex parsing accepts either, so
 * `4A3B...` is exactly as ambiguous as `4a3b...`. The floor is 7 because that
 * is git's shortest abbreviation; below it a name cannot be read as an id. The
 * ceiling is 64 because that is the longest object id that exists.
 *
 * A real tag does not look like this: `v1.2.0`, `release-3`, `1.2.0`. The cost
 * of a false positive is that a publisher renames a tag once; the cost of a
 * false negative is a pin that points at content nobody reviewed.
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
 * table and returned to a client.
 *
 * The pin depends on `kind`: a `"git"` version carries `ref` and `commit` and
 * leaves `checksum` empty, a `"tar.gz"` version carries `checksum` and leaves
 * `ref` / `commit` empty. The unused fields are stored empty rather than
 * omitted, so a reader never has to distinguish "absent" from "not applicable".
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
 * @field yanked {bool} true when the version is withdrawn from new resolutions
 *     but still fetchable, so an existing lockfile keeps installing
 * @field license {string} the SPDX identifier from the manifest ("" when absent)
 * @field keywords {list of string} the deck's tags, already normalised by
 *     `keywords.normalise` at publish time. Absent reads as empty, which is what
 *     makes the field additive over versions published before it existed.
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

# Every pointer builder folds the deck name first, which is what makes the whole
# store case-insensitive: `@Netflix/Foo` and `@netflix/foo` address one record,
# and a name is recorded in exactly one form (specification 2.1). Folding here
# rather than at each call site means no caller can forget.
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

# precedes reports whether version a sorts before b when ordering highest-first.
# A version that is not valid SemVer sorts last, so a malformed record stays
# visible rather than being dropped or crashing the comparison.
func precedes(a as string, b as string) {
    if (not semver.isValid($a)) {
        return false;
    }
    if (not semver.isValid($b)) {
        return true;
    }
    return semver.compare(semver.parse($a), semver.parse($b)) > 0;
}

/**
 * List a deck's published versions, **highest first**, by SemVer precedence
 * rather than document order - so `[0]` is the latest release and a deck page
 * leads with it. A version string that is not valid SemVer sorts last.
 *
 * An insertion sort: version lists are short, and it keeps the invalid-last
 * rule explicit instead of hidden inside a comparator.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @return {list of string} the version strings, highest first
 */
export func listVersionsDescending(db as flatdb.DB, name as string) {
    def out as list of string init [];
    for (def v in listVersions($db, $name)) {
        def next as list of string init [];
        def placed as bool init false;
        for (def have in $out) {
            if (not $placed and precedes($v, $have)) {
                $next[] = $v;
                $placed = true;
            }
            $next[] = $have;
        }
        if (not $placed) {
            $next[] = $v;
        }
        $out = $next;
    }
    return $out;
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
 * fields read as empty and an absent `kind` reads as KIND_TARGZ, so a record
 * written before a field existed still yields a complete value. The caller
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
        # flatdb.set needs a json.Value, so edit the record's description via
        # json.set (which coerces the native string) and write the record back.
        def rec as json.Value init flatdb.get($out, deckPtr($name));
        $rec = json.set($rec, "/description", $description);
        $out = flatdb.set($out, deckPtr($name), $rec);
    }
    def vjson as json.Value init json.map();
    $vjson = json.set($vjson, "/version", $ver.version);
    $vjson = json.set($vjson, "/kind", $ver.kind);
    $vjson = json.set($vjson, "/url", $ver.url);
    $vjson = json.set($vjson, "/ref", $ver.ref);
    $vjson = json.set($vjson, "/commit", $ver.commit);
    $vjson = json.set($vjson, "/checksum", $ver.checksum);
    $vjson = json.set($vjson, "/yanked", $ver.yanked);
    $vjson = json.set($vjson, "/license", $ver.license);
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
    for (def word in $ver.keywords) {
        $kjson = json.append($kjson, "", $word);
    }
    $vjson = json.set($vjson, "/keywords", $kjson);
    $vjson = json.set($vjson, "/description", $ver.description);
    $vjson = json.set($vjson, "/publishedAt", $ver.publishedAt);
    $out = flatdb.set($out, versionPtr($name, $ver.version), $vjson);
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
 * Remove a whole deck (all its versions), returning a fresh DB. Errors if the
 * deck does not exist (guard with `hasDeck`).
 * @param db {flatdb.DB} the store to edit
 * @param name {string} the deck name
 * @return {flatdb.DB} a fresh store without that deck
 * @throws {Error} when the deck does not exist
 */
export func removeDeck(db as flatdb.DB, name as string) {
    return flatdb.remove($db, deckPtr($name));
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

# recordString reads an optional string field off a version record, yielding ""
# when the field is absent - which is how a record written before a field
# existed reads, and how the pin unused by a record's kind is stored.
func recordString(rec as json.Value, field as string) {
    if (json.has($rec, $field)) {
        return json.asString($rec, $field);
    }
    return "";
}

# The two kinds a scope's principal may be.
export def const SCOPE_USER as string init "user";
export def const SCOPE_ORG as string init "org";

# scopeKindOf normalises a kind, defaulting anything unrecognised to "user".
# Defaulting to the *narrower* kind matters: a typo must not turn a personal
# scope into one that anybody in some organisation can write to.
func scopeKindOf(kind as string) {
    if ($kind == SCOPE_ORG) {
        return SCOPE_ORG;
    }
    return SCOPE_USER;
}

# recordKindOfScope reads a namespace record's kind. Absent reads as "user",
# which is what every record written before the field existed actually was.
func recordKindOfScope(rec as json.Value) {
    if (not json.has($rec, "/kind")) {
        return SCOPE_USER;
    }
    return scopeKindOf(json.asString($rec, "/kind"));
}

# recordStrings reads an optional array of strings. Absent reads as empty, which
# is what makes a list field additive over records written before it existed.
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
        $out[$key] = json.asString($rec, $field + "/" + $key);
    }
    return $out;
}

# recordBool reads an optional boolean field. Absent reads as false, which is
# what makes `yanked` additive: every record written before the field existed is
# a live version, which is exactly what it was.
func recordBool(rec as json.Value, field as string) {
    if (json.has($rec, $field)) {
        return json.asBool($rec, $field);
    }
    return false;
}

# recordKind reads a version record's delivery kind. An absent or empty `kind`
# reads as KIND_TARGZ, per the specification's compatibility rule for records
# written before the field existed.
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
 * Return a published version's keywords, as normalised at publish time.
 *
 * Absent reads as empty, which is what makes the field additive: every version
 * published before keywords existed is a version with no tags, which is exactly
 * what it was.
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

# namespacePtr is the JSON Pointer of a registered namespace record. Folded, for
# the same reason deck pointers are.
func namespacePtr(scope as string) {
    return "/namespaces/" + deckname.fold($scope);
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
 * Who owns a scope. **Ownership binds to the identity provider's stable subject
 * identifier, never to a login** (specification 8.1): a login released by a
 * rename becomes claimable by somebody else, and binding to one would hand them
 * an established scope.
 *
 * An empty `subject` means the scope is **operator-held**: registered, so nobody
 * may claim it, but bound to no principal, so nobody may write under it either.
 * That is the state a reservation is in, and the state a scope falls back to
 * when its owner is removed.
 * @field scope {string} the folded scope name
 * @field provider {string} the identity provider that issued the subject ("" when unowned)
 * @field subject {string} the provider's stable subject identifier ("" when unowned)
 * @field login {string} the owner's username, a display label refreshed on each login
 * @field registeredAt {string} when the scope was registered (Unix seconds as text)
 * @field kind {string} `"user"` when `subject` is a person, `"org"` when it is an
 *     organisation the provider can be asked about (8.7). Absent reads as
 *     `"user"`, which is what every record written before this field was.
 * @field coOwners {list of string} additional principals that may write under
 *     this scope, as subject ids under the same `provider`. Empty for a scope
 *     with one owner, which is every scope written before co-ownership existed.
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
 * Re-registering replaces the record, which is how an operator reassigns a scope
 * after a dispute or a departure (specification 10). There is no separate
 * transfer verb, because a transfer *is* a re-registration to a new principal.
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
 * Read a namespace record. Absent fields read as empty, so a record written
 * before ownership existed yields an operator-held scope rather than an error.
 * Guard with `hasNamespace` first.
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
 * Report whether a principal owns a scope.
 *
 * **This is the question every write under a scope asks** (specification 2.2),
 * and it is answered from the recorded binding rather than from anything the
 * provider says now: a rename does not move a scope, and the person who later
 * takes a released username does not inherit one.
 *
 * An unowned scope answers false for everybody, including a caller with empty
 * credentials, so an operator-held scope cannot be written to by accident.
 * @param db {flatdb.DB} the store to read
 * @param scope {string} the scope name
 * @param provider {string} the identity provider that authenticated the caller
 * @param subject {string} the caller's stable subject identifier
 * @return {bool} true when that principal owns the scope
 */
export func ownsNamespace(db as flatdb.DB, scope as string, provider as string,
        subject as string) {
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
    # A co-owner writes under the scope exactly as the owner does. They are held
    # as bare subject ids under the same provider, and no login is stored beside
    # them: the id is what authorises, a login is decoration, and a second copy
    # of a display label is a second thing to go stale after a rename.
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
# token's fingerprint rather than the token itself.
func refreshPtr(fingerprint as string) {
    return "/refreshTokens/" + $fingerprint;
}

/**
 * A stored refresh token: who it belongs to and when it stops working. The
 * token itself is never stored, only its fingerprint (the map key), so a leaked
 * database cannot be replayed as a set of live credentials.
 * @field accountId {int} the numeric GitHub account id this token authenticates
 * @field login {string} the GitHub login, a display label refreshed on each use
 * @field expiresAt {int} when the token stops working (Unix seconds)
 */
export def struct Refresh {
    accountId as int,
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
    $rj = json.set($rj, "/accountId", $rec.accountId);
    $rj = json.set($rj, "/login", $rec.login);
    $rj = json.set($rj, "/expiresAt", $rec.expiresAt);
    def ids as json.Value init json.map();
    for (def name in $rec.orgs) {
        $ids = json.set($ids, "/" + $name, $rec.orgs[$name]);
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
    def checkedAt as int init 0;
    if (json.has($rec, "/orgsCheckedAt")) {
        $checkedAt = json.asInt($rec, "/orgsCheckedAt");
    }
    return Refresh{
        accountId: json.asInt($rec, "/accountId"),
        login: json.asString($rec, "/login"),
        expiresAt: json.asInt($rec, "/expiresAt"),
        orgs: recordMap($rec, "/orgs"),
        orgsCheckedAt: $checkedAt
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
 * How many refresh tokens an account currently holds. Asked before a revoke, so
 * the operational log can record what was actually dropped: "revoked 3" and
 * "revoked 0" are different events, and the second one usually means the
 * operator has the wrong account id.
 * @param db {flatdb.DB} the store to read
 * @param accountId {int} the numeric account id
 * @return {int} the number of live refresh tokens held by that account
 */
export func countRefresh(db as flatdb.DB, accountId as int) {
    if (not flatdb.has($db, "/refreshTokens")) {
        return 0;
    }
    def n as int init 0;
    for (def key in flatdb.keys($db, "/refreshTokens")) {
        if (getRefresh($db, $key).accountId == $accountId) {
            $n = $n + 1;
        }
    }
    return $n;
}

/**
 * Forget every refresh token belonging to an account, returning a fresh DB.
 * This is the operator path the specification requires for invalidating an
 * identity's outstanding tokens (section 8.5).
 * @param db {flatdb.DB} the store to edit
 * @param accountId {int} the numeric GitHub account id to revoke
 * @return {flatdb.DB} a fresh store without that account's tokens
 */
export func revokeAccount(db as flatdb.DB, accountId as int) {
    if (not flatdb.has($db, "/refreshTokens")) {
        return $db;
    }
    def out as flatdb.DB init $db;
    for (def key in flatdb.keys($db, "/refreshTokens")) {
        if (getRefresh($db, $key).accountId == $accountId) {
            $out = flatdb.remove($out, refreshPtr($key));
        }
    }
    return $out;
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
    # Live versions only: a yank withdraws a version from *new* resolutions while
    # leaving it fetchable for a lockfile that already pins it (specification 9).
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

# bindingPtr is the JSON Pointer of a deck's trusted-publisher binding. Keyed on
# the folded deck name, so a binding registered for @Acme/Tool is found for
# @acme/tool.
func bindingPtr(deck as string) {
    return "/publishers/" + ptrEscape(deckname.fold($deck));
}

/**
 * Record a trusted-publisher binding, returning a fresh DB. One binding per
 * deck: re-registering replaces, which is how a repository migration is done.
 * @param db {flatdb.DB} the store to edit
 * @param b {trustpub.Binding} the binding to record
 * @return {flatdb.DB} a fresh store carrying it
 */
export func putBinding(db as flatdb.DB, b as trustpub.Binding) {
    # The root is created on first write, as every other table here is. That is
    # also the whole migration story for this schema addition: a document written
    # before trusted publishing existed simply has no `/publishers`, and every
    # reader below treats that as "no bindings" rather than as an error.
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
        provider: "", repositoryId: "", repository: "", workflow: "",
        refPattern: "", deck: deckname.fold($deck), pending: false, createdAt: ""
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
 * Forget a deck's trusted-publisher binding, returning a fresh DB. This is how a
 * compromised or retired repository is cut off.
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
 *
 * **Yanking is not deletion** (specification 9). The record stays, the code stays
 * fetchable, and an existing lockfile that pins this version keeps installing;
 * what changes is that a fresh resolution will not choose it. That is the whole
 * point: deleting a version breaks everyone who already depends on it, which
 * punishes the wrong people for the publisher's mistake.
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
    if (not hasVersion($db, $name, $version)) {
        return false;
    }
    return getVersionRecord($db, $name, $version).yanked;
}

/**
 * Every live (not yanked) version of a deck, in stored order. This is what a
 * resolution chooses from; `listVersions` still returns everything, because a
 * deck page and a lockfile-pinned fetch both need to see a yanked version.
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
# SHA-256. The token itself is never a key, and never stored: a leaked database
# is a list of hashes, the same decision refresh tokens take.
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
 * `Token`, whose empty `fingerprint` `citoken.check` refuses, so a caller that
 * forgets to guard fails closed.
 * @param db {flatdb.DB} the store to read
 * @param fingerprint {string} the token's SHA-256
 * @return {citoken.Token} the record, or a zero value
 */
export func getCiToken(db as flatdb.DB, fingerprint as string) {
    def out as citoken.Token init citoken.Token{
        fingerprint: "", name: "", scope: "", deck: "", provider: "",
        subject: "", createdAt: "", expiresAt: "", lastUsedAt: ""
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
 * Forget one CI token, returning a fresh DB. Individually revocable is the
 * point: a suspected leak costs one pipeline, not every pipeline.
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
 * can be found and removed, which is the only way a standing credential gets
 * retired before it leaks.
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
 * Record a deck's README, returning a fresh DB.
 *
 * Held on the **deck** rather than the version, and overwritten by each publish,
 * so the page shows what the most recent release says about the deck. A per
 * version copy would mean storing the same text many times over to answer a
 * question nobody asks: readers want to know what this deck is now.
 *
 * **Stored verbatim, as the untrusted publisher input it is.** Nothing here
 * renders it; `webview` escapes before rendering, because a README that could
 * inject markup would be running a publisher's script on every visitor.
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
 * A co-owner writes under the scope exactly as the owner does. What they are
 * **not** is a second holder of the scope's identity: the record still names one
 * `subject` as the principal it was granted to, and reassigning that is
 * `registerNamespace`. This is the difference between "let my colleague publish"
 * and "hand the scope over".
 *
 * Idempotent, and it refuses an unowned scope: a reserved name has no owner to
 * co-own with, and quietly accepting one would leave a scope nobody holds that
 * somebody can nevertheless write to.
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
    # A list field of a struct cannot be appended to in place; build the list,
    # then assign it back.
    def owners as list of string init $ns.coOwners;
    $owners[] = $subject;
    def out as Namespace init $ns;
    $out.coOwners = $owners;
    return registerNamespace($db, $out);
}

/**
 * Remove a co-owner from a scope, returning a fresh DB.
 *
 * The scope's own `subject` cannot be removed this way. Losing the last owner
 * would leave a scope with decks under it and nobody able to yank them, so
 * handing the scope on is `registerNamespace` and is deliberately a different
 * verb.
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
 * co-owners. Empty when the scope is reserved, which is what makes a reserved
 * scope unwritable rather than merely unclaimed.
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

# How long to wait for a held lock before giving up, and how long a lock may sit
# untouched before it is assumed abandoned. The stale window is deliberately much
# larger than any real write: breaking a live lock is worse than waiting, because
# breaking it reintroduces exactly the lost update the lock exists to prevent.
def const LOCK_WAIT_MS as int init 5000;
def const LOCK_RETRY_MS as int init 25;
def const LOCK_STALE_SECONDS as int init 120;

/**
 * A held write lock. Release it with `unlock`, ideally through `defer` so it is
 * released however the block exits.
 * @field path {string} the lock's own path
 * @field holder {string} what was written into it, for diagnosing a stuck lock
 */
export def struct Lock {
    path as string,
    holder as string
};

# lockPathFor is the lock beside the database, so the two travel together and a
# bind-mounted data directory carries both.
func lockPathFor(dbPath as string) {
    return $dbPath + ".lock";
}

# holderOf reads a lock's holder label, or "" when it cannot be read.
func holderOf(path as string) {
    try {
        return fs.readlink($path);
    } catch (err) {
        return "";
    }
}

# stampOf pulls the acquisition time out of a holder label, or 0. The label is
# "<uuid> <unix seconds>", so the last space-separated field is the stamp.
# (`strings.lastIndexOf` does not exist in this interpreter; splitting is the
# way to reach the final field.)
func stampOf(holder as string) {
    def parts as list of string init strings.split($holder, " ");
    if (len($parts) < 2) {
        return 0;
    }
    try {
        return convert.toInt($parts[len($parts) - 1]);
    } catch (err) {
        return 0;
    }
}

# breakIfStale removes a lock that has sat untouched past the stale window,
# which is how a writer killed mid-write stops wedging the registry. Split out of
# `lock` only to keep its retry loop flat. The removal races with anybody else
# doing the same, and that is harmless: the retry that follows re-takes the lock
# through the same atomic symlink, so there is still exactly one winner.
func breakIfStale(path as string) {
    def current as string init holderOf($path);
    if ($current == "") {
        return null;
    }
    if (time.unix(time.utc()) - stampOf($current) <= LOCK_STALE_SECONDS) {
        return null;
    }
    try {
        fs.remove($path);
    } catch (rmErr) { # lint-disable: L103
        # somebody else broke it first, which is fine
    }
    return null;
}

/**
 * Take the registry's write lock, waiting for it if somebody else holds it.
 *
 * **`flatdb` has no locking of its own.** `flatdb.save` replaces the document
 * crash-atomically, so a reader never sees a torn file - but two writers that
 * each read, edit, and write back will still lose one of the two edits, and
 * nothing in the write path notices. That is the loss this prevents, and it is
 * not a rare race: `deckadmin` run while the server is up, or two publishes
 * arriving together, is enough.
 *
 * The lock is a **symlink**, because creating one is atomic and fails if the
 * name exists, which is the test-and-set this needs; and because its target can
 * carry a readable holder label, so a stuck lock can be diagnosed with
 * `ls -l` rather than guessed at.
 *
 * A lock older than the stale window is assumed abandoned by a killed writer and
 * broken. That window is deliberately long: waiting is cheap, and breaking a
 * lock that is merely slow reintroduces the very loss this exists to stop.
 *
 * **Holding the lock is only half of it.** The document must be *read* inside
 * the lock as well as written, or the read happened before somebody else's write
 * and the edit is computed against a stale copy.
 * @param dbPath {string} the database path this lock guards
 * @return {Lock} the held lock
 * @throws {Error} when the lock could not be taken within the wait
 */
export func lock(dbPath as string) {
    def path as string init lockPathFor($dbPath);
    def holder as string init uuid.v4() + " " + convert.toString(time.unix(time.utc()));
    def waited as int init 0;
    while ($waited <= LOCK_WAIT_MS) {
        try {
            fs.symlink($holder, $path);
            return Lock{ path: $path, holder: $holder };
        } catch (err) {
            # A failed `symlink` means one of two very different things. If
            # somebody holds the lock, this is contention and waiting is right.
            # If nothing holds it, the lock could not be *created* - a read-only
            # mount, a missing directory, the wrong uid - and no amount of
            # waiting will help. Reporting that as a timeout blames contention
            # for a permissions problem and costs the caller the wait as well.
            if (holderOf($path) == "") {
                throw Error{
                    kind: "store",
                    message: "cannot create the registry write lock at " + $path +
                        ": " + $err.message,
                    file: "", line: 0, col: 0
                };
            }
            breakIfStale($path);
        }
        time.sleep(time.fromMilliseconds(LOCK_RETRY_MS));
        $waited = $waited + LOCK_RETRY_MS;
    }
    throw Error{
        kind: "store",
        message: "could not take the registry write lock at " + $path +
            " within " + convert.toString(LOCK_WAIT_MS) + "ms; holder: " +
            holderOf($path),
        file: "", line: 0, col: 0
    };
}

/**
 * Who currently holds the write lock, or "" when it is free.
 *
 * Note that **`fs.exists` cannot answer this**: the lock is a symlink whose
 * target is a holder label rather than a path, so `exists` follows the link,
 * finds nothing, and reports the lock absent while it is very much held.
 * Reading the link is the test.
 * @param dbPath {string} the database the lock guards
 * @return {string} the holder label, or "" when unlocked
 */
export func lockHolder(dbPath as string) {
    return holderOf(lockPathFor($dbPath));
}

/**
 * Release a write lock. Safe to call on a lock somebody else has already broken:
 * a release that finds a different holder leaves it alone rather than freeing
 * somebody else's lock.
 * @param held {Lock} the lock returned by `lock`
 */
export func unlock(held as Lock) {
    if (not (holderOf($held.path) == $held.holder)) {
        return null;
    }
    try {
        fs.remove($held.path);
    } catch (err) { # lint-disable: L103
        # already gone; nothing to release
    }
    return null;
}

# --- lookup counts -----------------------------------------------------------

# statsPtr is the JSON Pointer of a deck's lookup-count record. Kept in its own
# top-level table rather than inside the deck's record so that counting writes
# and publishing writes touch different subtrees: a flush that lands while an
# operator is editing a deck then merges cleanly instead of racing over one
# object. It also keeps `getDeckJson` free of a member that changes constantly,
# which matters because that value is what the API serves.
func statsPtr(name as string) {
    return "/stats/" + ptrEscape(deckname.fold($name));
}

/**
 * A deck's lookup-count record, or an empty object when it has never been
 * looked up.
 *
 * Empty rather than absent is what lets `stats.summarise` answer with zeroes for
 * a deck nobody has resolved yet, so a page has nothing to special-case.
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
 * A deck's live versions, newest first.
 *
 * `listLiveVersions` answers in document order, which is the right shape for a
 * resolver choosing by constraint and the wrong one for a page that wants "the
 * current release". This is the ordered form.
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
