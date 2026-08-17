# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Reading a deck's `deck.toml`.
 *
 * **The manifest is read at the resolved commit, never taken from the request
 * body** (specification 7). That is the whole reason this module exists: if a
 * publisher could name the deck in the request, the name would be whatever they
 * typed rather than what the repository actually declares, and the scope check
 * would be checking a claim instead of a fact.
 *
 * The shape is the specification's, and the appendix's worked example is the
 * canonical instance of it:
 *
 *     [package]
 *     name = "@acme/routeros"
 *     version = "0.1.0"
 *     capabilities = ["net"]
 *
 *     [engines]
 *     jennifer = ">=0.24.0"
 *
 *     [decks]
 *     "@acme/net" = "^1.0.0"
 *
 * Note that a deck's dependencies live under `[decks]` and become the version
 * record's `requires`: the manifest is written for a person declaring what their
 * deck needs, the record is read by a resolver, and the two names differ because
 * they are read by different audiences.
 *
 * Parsing is pure - a string in, a `Manifest` out - so every malformed input
 * has a test rather than a comment. Fetching the bytes at a commit is the
 * caller's job, through a `forge.readFile`.
 * @module manifest
 * @example
 * import "./manifest.j" as manifest;
 * def m as manifest.Manifest init manifest.parse($tomlText);
 * # if (!m.ok) { refuse with m.error }
 */

use toml;
use strings;
use convert;
import "./deckname.j" as deckname;
import "./keywords.j" as keywords;
import "semver.j" as semver;

# The file a deck declares itself in, at the root of its repository.
export def const FILENAME as string init "deck.toml";

/**
 * A parsed `deck.toml`. `ok` false means nothing else is meaningful except
 * `error`, which is phrased for whoever ran the publish.
 * @field ok {bool} whether the manifest parsed and validated
 * @field error {string} why not, for the publisher to read
 * @field name {string} the deck name, folded
 * @field version {string} the SemVer version being published
 * @field description {string} the one-line summary ("" when absent)
 * @field license {string} the SPDX identifier ("" when absent)
 * @field requires {map of string to string} deck name -> version constraint
 * @field engines {map of string to string} engine -> version range
 * @field capabilities {list of string} host capabilities the code needs
 * @field keywords {list of string} the deck's tags, already normalised: folded,
 *     filtered against the refused list, deduplicated, and capped at
 *     `keywords.LIMIT`. Never a reason to reject a manifest.
 */
export def struct Manifest {
    ok as bool,
    error as string,
    name as string,
    version as string,
    description as string,
    license as string,
    requires as map of string to string,
    engines as map of string to string,
    capabilities as list of string,
    keywords as list of string
};

# bad builds a refusal. Every field is zeroed, so a caller that ignores `ok`
# gets an empty name rather than a half-populated one that might pass a check.
func bad(reason as string) {
    def noMap as map of string to string init {};
    def noList as list of string init [];
    return Manifest{
        ok: false, error: $reason, name: "", version: "", description: "",
        license: "", requires: $noMap, engines: $noMap, capabilities: $noList,
        keywords: $noList
    };
}

# str reads an optional string field, returning "" when absent.
func str(doc as toml.Value, pointer as string) {
    if (not toml.has($doc, $pointer)) {
        return "";
    }
    return toml.asString($doc, $pointer);
}

# table reads a table of string values into a map. An absent table is empty,
# which is what the specification says an absent `requires` means.
func table(doc as toml.Value, pointer as string) {
    def out as map of string to string init {};
    if (not toml.has($doc, $pointer)) {
        return $out;
    }
    for (def key in toml.keys($doc, $pointer)) {
        $out[$key] = toml.asString($doc, $pointer + "/" + ptrEscape($key));
    }
    return $out;
}

# ptrEscape encodes one JSON Pointer reference token (RFC 6901). A dependency
# key is a scoped deck name and contains a "/", which would otherwise read as a
# path separator and address a table that does not exist.
func ptrEscape(token as string) {
    def out as string init strings.replace($token, "~", "~0");
    return strings.replace($out, "/", "~1");
}

# strList reads an optional array of strings.
func strList(doc as toml.Value, pointer as string) {
    def out as list of string init [];
    if (not toml.has($doc, $pointer)) {
        return $out;
    }
    def n as int init toml.length($doc, $pointer);
    def i as int init 0;
    while ($i < $n) {
        $out[] = toml.asString($doc, $pointer + "/" + convert.toString($i));
        $i = $i + 1;
    }
    return $out;
}

/**
 * Parse and validate a `deck.toml`.
 *
 * Validation is deliberately strict about the two fields that become the
 * published record's identity, and lenient about everything else. A malformed
 * name or version must not reach the store: a name outside the grammar produces
 * a record a conforming client cannot install (2.1), and a version that is not
 * SemVer cannot be ordered against its siblings.
 * @param text {string} the file's contents
 * @return {Manifest} the parsed manifest, or a refusal with `error` set
 */
export func parse(text as string) {
    if (strings.trim($text) == "") {
        return bad(FILENAME + " is empty");
    }
    def doc as toml.Value;
    try {
        $doc = toml.decode($text);
    } catch (err) {
        return bad(FILENAME + " is not valid TOML: " + $err.message);
    }
    def name as string init deckname.fold(str($doc, "/package/name"));
    if ($name == "") {
        return bad(FILENAME + " has no `name` under [package]");
    }
    if (not deckname.isValid($name)) {
        return bad("not a valid deck name in " + FILENAME + ": " + $name);
    }
    if (not deckname.isScoped($name)) {
        return bad("not a registry deck name: " + $name +
            " (a published deck is scoped, as @scope/deck)");
    }
    def version as string init strings.trim(str($doc, "/package/version"));
    if ($version == "") {
        return bad(FILENAME + " has no `version` under [package]");
    }
    if (not semver.isValid($version)) {
        return bad("not a valid version in " + FILENAME + ": " + $version);
    }
    return Manifest{
        ok: true,
        error: "",
        name: $name,
        version: $version,
        description: str($doc, "/package/description"),
        license: str($doc, "/package/license"),
        requires: table($doc, "/decks"),
        engines: table($doc, "/engines"),
        capabilities: strList($doc, "/package/capabilities"),
        # Normalised here rather than at the call site so there is one answer to
        # "what tags does this deck have": a bad keyword costs the publisher that
        # keyword and never their release, so this cannot fail the parse.
        keywords: keywords.normalise(strList($doc, "/package/keywords"))
    };
}
