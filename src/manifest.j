# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.27.0

/**
 * Reading a deck's manifest: `deck.toml`, `deck.yaml`, `deck.yml` or
 * `deck.json`, the four names a client accepts. Each is decoded into one JSON
 * tree and validated by the same rules, so the format changes nothing about
 * what is recorded; the examples below are TOML.
 *
 * The manifest is read at the resolved commit, never taken from the request
 * body (specification 7), so the scope check runs against what the repository
 * declares rather than what the publisher typed.
 *
 * The shape is the specification's; the appendix's worked example:
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
 * Dependencies under `[decks]` become the version record's `requires`.
 *
 * Parsing is pure: a file name and a string in, a `Manifest` out. The caller
 * fetches the bytes at a commit through `forge.readFile`.
 * @module manifest
 * @example
 * import "./manifest.j" as manifest;
 * def m as manifest.Manifest init manifest.parseAs("deck.yaml", $text);
 * # if (not $m.ok) { refuse with $m.error }
 */

use toml;
use yaml;
use json;
use strings;
use convert;
use maps;
import "./deckname.j" as deckname;
import "./keywords.j" as keywords;
import "./constraint.j" as constraint;
import "./enginerange.j" as enginerange;

# The file a deck declares itself in, at the root of its repository, in TOML.
export def const FILENAME as string init "deck.toml";

/**
 * Every manifest name a deck may use, in the order a reader looks for them.
 * A commit holding more than one is refused (`publishview.chooseManifest`), as
 * clients refuse it: which one counts would otherwise depend on who reads it.
 */
export def const FILENAMES as list of string init [
    "deck.toml",
    "deck.yaml",
    "deck.yml",
    "deck.json"
];

# Limits on what a manifest may carry into the record (specification 3).
# Everything here is served in every `GET /deck` reply and held in the shared
# index, so a manifest cannot be allowed to grow them without bound.
export def const MAX_DESCRIPTION as int init 512;
export def const MAX_LICENSE as int init 64;
export def const MAX_CAPABILITIES as int init 32;
export def const MAX_CAPABILITY as int init 64;
export def const MAX_REQUIRES as int init 256;
export def const MAX_ENGINES as int init 16;

/**
 * A parsed `deck.toml`. When `ok` is false only `error` is meaningful.
 * @field ok {bool} whether the manifest parsed and validated
 * @field error {string} why not, for the publisher to read
 * @field name {string} the deck name, folded
 * @field version {string} the SemVer version being published
 * @field description {string} the one-line summary ("" when absent)
 * @field license {string} the SPDX identifier ("" when absent)
 * @field requires {map of string to string} deck name -> version constraint
 * @field engines {map of string to string} engine -> version range
 * @field capabilities {list of string} host capabilities the code needs
 * @field keywords {list of string} the deck's tags, normalised by
 *     `keywords.normalise`; never a reason to reject a manifest
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

# bad builds a refusal with every field zeroed, so a caller ignoring `ok` gets
# no name that might pass a check.
func bad(reason as string) {
    def noMap as map of string to string init {};
    def noList as list of string init [];
    return Manifest{
        ok: false,
        error: $reason,
        name: "",
        version: "",
        description: "",
        license: "",
        requires: $noMap,
        engines: $noMap,
        capabilities: $noList,
        keywords: $noList
    };
}

# str reads an optional string field, returning "" when absent.
func str(doc as json.Value, pointer as string) {
    if (not json.has($doc, $pointer)) {
        return "";
    }
    return json.asString($doc, $pointer);
}

# table reads a table of string values into a map, folding the keys when they
# are deck names. An absent table is empty, as the specification defines an
# absent `requires`. Call after `tableProblem` has checked the shape.
func table(doc as json.Value, pointer as string, decks as bool) {
    def out as map of string to string init {};
    if (not json.has($doc, $pointer)) {
        return $out;
    }
    for (def key in json.keys($doc, $pointer)) {
        def name as string init $key;
        if ($decks) {
            $name = deckname.fold($key);
        }
        $out[$name] = strings.trim(json.asString($doc, $pointer + "/" + ptrEscape($key)));
    }
    return $out;
}

# isIdent is the grammar of an engine name or a capability: a lowercase letter,
# then lowercase letters, digits and hyphens.
func isIdent(s as string) {
    if ($s == "") {
        return false;
    }
    def first as bool init true;
    for (def c in strings.chars($s)) {
        def letter as bool init $c >= "a" and $c <= "z";
        if ($first and not $letter) {
            return false;
        }
        if (not ($letter or ($c >= "0" and $c <= "9") or $c == "-")) {
            return false;
        }
        $first = false;
    }
    return true;
}

# keyProblem is why one key of a dependency table cannot be published, or "".
# Under `[decks]` a key is a scoped deck name other than the deck itself; under
# `[engines]` it is an engine name.
func keyProblem(key as string, label as string, decks as bool, self as string) {
    if ($decks) {
        def folded as string init deckname.fold($key);
        if (not deckname.isValid($folded) or not deckname.isScoped($folded)) {
            return "not a deck name in " + $label + ": " + $key;
        }
        if ($folded == $self) {
            return $self + " cannot require itself";
        }
        return "";
    }
    if (not isIdent($key)) {
        return "not an engine name in " + $label + ": " + $key +
            " (lowercase letters, digits and hyphens)";
    }
    return "";
}

# tableProblem is why a dependency table cannot be published, or "". Each entry
# must be a constraint in the grammar (2.4); one outside it matches nothing.
# Under `[decks]` each key must be a scoped deck name, and two spellings of one
# folded name are refused, since they would be one dependency at two versions.
# `self` is the deck's own name, which it may not require.
func tableProblem(
    file as string,
    doc as json.Value,
    pointer as string,
    decks as bool,
    self as string) {
    def label as string init "[" + $pointer[1..len($pointer)] + "]";
    if (not json.has($doc, $pointer)) {
        return "";
    }
    if (not (json.typeOf($doc, $pointer) == "map")) {
        return $label + " in " + $file + " must be a table";
    }
    def most as int init MAX_ENGINES;
    if ($decks) {
        $most = MAX_REQUIRES;
    }
    if (json.length($doc, $pointer) > $most) {
        return $label + " in " + $file + " lists more than " + convert.toString($most) +
            " entries";
    }
    def seen as map of string to bool init {};
    for (def key in json.keys($doc, $pointer)) {
        def at as string init $pointer + "/" + ptrEscape($key);
        if (not (json.typeOf($doc, $at) == "string")) {
            return $label + " entry " + $key + " must be a version constraint in quotes";
        }
        def wrongKey as string init keyProblem($key, $label, $decks, $self);
        if (not ($wrongKey == "")) {
            return $wrongKey;
        }
        if ($decks) {
            def folded as string init deckname.fold($key);
            if (maps.has($seen, $folded)) {
                return $key + " is listed twice in " + $label + ", under two spellings";
            }
            $seen[$folded] = true;
        }
        def value as string init json.asString($doc, $at);
        # The module reads "" as "*", the default where nothing was given; written
        # in a manifest it is a placeholder or a slip, so it is refused (2.4).
        if (strings.trim($value) == "") {
            return "empty version constraint for " + $key + " in " + $label +
                ": write \"*\" for any version";
        }
        # The interpreter engines take only `>=X.Y.Z` or `>=X.Y.Z <A.B.C`, the
        # forms jvc's resolver judges and the version pragma accepts; deckadmin
        # holds `--engines` to the same rule.
        if (not $decks and enginerange.isEngineKey($key)) {
            def parsed as enginerange.Range init enginerange.parse($value);
            if (not $parsed.ok) {
                return "not a valid engine range for " + $key + " in " + $label + ": " +
                    $value + " (" + $parsed.problem + "; write " + enginerange.FORMS + ")";
            }
            continue;
        }
        if (not constraint.isValidConstraint($value)) {
            return "not a valid version constraint for " + $key + " in " + $label + ": " +
                $value;
        }
    }
    return "";
}

# listProblem is why a list cannot be read as strings, or "".
func listProblem(file as string, doc as json.Value, pointer as string) {
    if (not json.has($doc, $pointer)) {
        return "";
    }
    if (not (json.typeOf($doc, $pointer) == "list")) {
        return $pointer[1..len($pointer)] + " in " + $file +
            " must be a list";
    }
    for (def i in 0..json.length($doc, $pointer)) {
        if (not (json.typeOf($doc, $pointer + "/" + convert.toString($i)) == "string")) {
            return $pointer[1..len($pointer)] + " in " + $file +
                " must hold only strings";
        }
    }
    return "";
}

# fieldProblem is why a [package] field that must be text is not, or "". TOML
# and YAML read an unquoted `0.1` as a number, so that case says to quote it.
func fieldProblem(file as string, doc as json.Value, field as string) {
    def at as string init "/package/" + $field;
    if (not json.has($doc, $at) or json.typeOf($doc, $at) == "string") {
        return "";
    }
    def kind as string init json.typeOf($doc, $at);
    if ($kind == "int" or $kind == "float") {
        return "`" + $field + "` in " + $file + " must be a string; put it in quotes";
    }
    return "`" + $field + "` in " + $file + " must be a string";
}

# lengthProblem is why a text field is too long to record, or "".
func lengthProblem(file as string, value as string, field as string, most as int) {
    if (len($value) > $most) {
        return "`" + $field + "` in " + $file + " is longer than " +
            convert.toString($most) + " characters";
    }
    return "";
}

# capabilitiesProblem is why the capability list cannot be recorded, or "":
# too many, or one outside the name grammar or too long. Call after
# `listProblem` has checked the shape.
func capabilitiesProblem(file as string, caps as list of string) {
    if (len($caps) > MAX_CAPABILITIES) {
        return "`capabilities` in " + $file + " lists more than " +
            convert.toString(MAX_CAPABILITIES) + " entries";
    }
    for (def cap in $caps) {
        if (len($cap) > MAX_CAPABILITY or not isIdent($cap)) {
            return "not a capability name in " + $file + ": " + $cap +
                " (lowercase letters, digits and hyphens)";
        }
    }
    return "";
}

# ptrEscape encodes one JSON Pointer reference token (RFC 6901). A scoped deck
# name contains a "/", which would otherwise read as a path separator.
func ptrEscape(token as string) {
    def out as string init strings.replace($token, "~", "~0");
    return strings.replace($out, "/", "~1");
}

# strList reads an optional array, keeping its strings and skipping anything
# else. Fields where a wrong entry fails the publish check `listProblem` first;
# keywords do not.
func strList(doc as json.Value, pointer as string) {
    def out as list of string init [];
    if (not json.has($doc, $pointer) or not (json.typeOf($doc, $pointer) == "list")) {
        return $out;
    }
    for (def i in 0..json.length($doc, $pointer)) {
        def at as string init $pointer + "/" + convert.toString($i);
        if (json.typeOf($doc, $at) == "string") {
            $out[] = json.asString($doc, $at);
        }
    }
    return $out;
}

/**
 * Decode a manifest of any accepted name into one JSON tree, which is what
 * every check reads. TOML and YAML values are copied node by node; a date or
 * time, which JSON lacks, becomes null, so a field holding one fails as the
 * wrong type rather than passing as text.
 * @param file {string} the manifest's name, one of `FILENAMES`
 * @param text {string} the file's contents
 * @return {json.Value} the document
 * @throws {Error} kind "manifest" when the text is not valid in its format, or
 *     the name is not a manifest name
 */
export func decodeAs(file as string, text as string) {
    def format as string init formatOf($file);
    # Only the decode is caught: a fault in the copy below must not read as the
    # publisher's syntax error.
    if ($format == "toml") {
        def t as toml.Value;
        try {
            $t = toml.decode($text);
        } catch (err) {
            throw Error{kind: "manifest", message: invalid($file, $format, $err.message)};
        }
        return fromToml($t, "");
    }
    if ($format == "yaml") {
        def y as yaml.Value;
        try {
            $y = yaml.decode($text);
        } catch (err) {
            throw Error{kind: "manifest", message: invalid($file, $format, $err.message)};
        }
        return fromYaml($y, "");
    }
    try {
        return json.decode($text);
    } catch (err) {
        throw Error{kind: "manifest", message: invalid($file, $format, $err.message)};
    }
}

# invalid is the message for text that is not valid in its format.
func invalid(file as string, format as string, detail as string) {
    return $file + " is not valid " + FORMAT_NAMES[$format] + ": " + $detail;
}

# How each format is named to a publisher.
def const FORMAT_NAMES as map of string to string init {
    "toml": "TOML",
    "yaml": "YAML",
    "json": "JSON"
};

# formatOf maps a manifest name to its format; anything else is a caller bug.
func formatOf(file as string) {
    match ($file) {
        when "deck.toml" { return "toml"; }
        when "deck.yaml", "deck.yml" { return "yaml"; }
        when "deck.json" { return "json"; }
    }
    throw Error{kind: "manifest", message: "not a manifest name: " + $file};
}

# fromToml copies the TOML node at `at` into JSON.
func fromToml(doc as toml.Value, at as string) {
    match (toml.typeOf($doc, $at)) {
        when "map" {
            def m as map of string to json.Value init {};
            for (def key in toml.keys($doc, $at)) {
                $m[$key] = fromToml($doc, $at + "/" + ptrEscape($key));
            }
            return json.map($m);
        }
        when "list" {
            def l as list of json.Value init [];
            for (def i in 0..toml.length($doc, $at)) {
                $l[] = fromToml($doc, $at + "/" + convert.toString($i));
            }
            return json.list($l);
        }
        when "string" { return json.get(json.list([toml.asString($doc, $at)]), "/0"); }
        when "int" { return json.get(json.list([toml.asInt($doc, $at)]), "/0"); }
        when "float" { return json.get(json.list([toml.asFloat($doc, $at)]), "/0"); }
        when "bool" { return json.get(json.list([toml.asBool($doc, $at)]), "/0"); }
    }
    return json.decode("null");
}

# fromYaml copies the YAML node at `at` into JSON.
func fromYaml(doc as yaml.Value, at as string) {
    match (yaml.typeOf($doc, $at)) {
        when "map" {
            def m as map of string to json.Value init {};
            for (def key in yaml.keys($doc, $at)) {
                $m[$key] = fromYaml($doc, $at + "/" + ptrEscape($key));
            }
            return json.map($m);
        }
        when "list" {
            def l as list of json.Value init [];
            for (def i in 0..yaml.length($doc, $at)) {
                $l[] = fromYaml($doc, $at + "/" + convert.toString($i));
            }
            return json.list($l);
        }
        when "string" { return json.get(json.list([yaml.asString($doc, $at)]), "/0"); }
        when "int" { return json.get(json.list([yaml.asInt($doc, $at)]), "/0"); }
        when "float" { return json.get(json.list([yaml.asFloat($doc, $at)]), "/0"); }
        when "bool" { return json.get(json.list([yaml.asBool($doc, $at)]), "/0"); }
    }
    return json.decode("null");
}

/**
 * The scoped deck name a manifest tries to give, folded, whether or not the
 * rest of it validates; "" when there is none readable. For deciding who may
 * see a failed manifest's errors, never for publishing.
 * @param file {string} the manifest's name, one of `FILENAMES`
 * @param text {string} the file's contents
 * @return {string} the folded name, or ""
 */
export func nameOfAs(file as string, text as string) {
    def doc as json.Value;
    try {
        $doc = decodeAs($file, $text);
    } catch (err) {
        return "";
    }
    if (not (json.typeOf($doc, "") == "map") or not (fieldProblem($file, $doc, "name") == "")) {
        return "";
    }
    def name as string init deckname.fold(str($doc, "/package/name"));
    if (not deckname.isValid($name) or not deckname.isScoped($name)) {
        return "";
    }
    return $name;
}

/**
 * `nameOfAs` for a `deck.toml`.
 * @param text {string} the file's contents
 * @return {string} the folded name, or ""
 */
export func nameOf(text as string) {
    return nameOfAs(FILENAME, $text);
}

/**
 * `parseAs` for a `deck.toml`.
 * @param text {string} the file's contents
 * @return {Manifest} the parsed manifest, or a refusal with `error` set
 */
export func parse(text as string) {
    return parseAs(FILENAME, $text);
}

/**
 * Parse and validate a manifest of any accepted name. Strict on name and
 * version, which form the record's identity: a name outside the grammar cannot
 * be installed by a conforming client (2.1), and a non-SemVer version cannot be
 * ordered.
 * @param file {string} the manifest's name, one of `FILENAMES`
 * @param text {string} the file's contents
 * @return {Manifest} the parsed manifest, or a refusal with `error` set
 */
export func parseAs(file as string, text as string) {
    if (strings.trim($text) == "") {
        return bad($file + " is empty");
    }
    def doc as json.Value;
    try {
        $doc = decodeAs($file, $text);
    } catch (err) {
        return bad($err.message);
    }
    # A YAML scalar or a JSON array is valid syntax, and every lookup in it
    # would miss; say what is wrong rather than "has no name".
    if (not (json.typeOf($doc, "") == "map")) {
        return bad($file + " must be a table of fields at the top, with [package] in it");
    }
    for (def field in ["name", "version", "description", "license"]) {
        def wrongType as string init fieldProblem($file, $doc, $field);
        if (not ($wrongType == "")) {
            return bad($wrongType);
        }
    }
    def name as string init deckname.fold(str($doc, "/package/name"));
    if ($name == "") {
        return bad($file + " has no `name` under [package]");
    }
    if (not deckname.isValid($name)) {
        return bad("not a valid deck name in " + $file + ": " + $name);
    }
    if (not deckname.isScoped($name)) {
        return bad("not a registry deck name: " + $name +
            " (a published deck is scoped, as @scope/deck)");
    }
    def version as string init strings.trim(str($doc, "/package/version"));
    if ($version == "") {
        return bad($file + " has no `version` under [package]");
    }
    if (not constraint.isUsableVersion($version)) {
        return bad("not a valid version in " + $file + ": " + $version +
            " (SemVer, with no number longer than 18 digits)");
    }
    for (def complaint in [
        lengthProblem($file, str($doc, "/package/description"), "description", MAX_DESCRIPTION),
        lengthProblem($file, str($doc, "/package/license"), "license", MAX_LICENSE),
        tableProblem($file, $doc, "/decks", true, $name),
        tableProblem($file, $doc, "/engines", false, $name),
        listProblem($file, $doc, "/package/capabilities")
    ]) {
        if (not ($complaint == "")) {
            return bad($complaint);
        }
    }
    def capsComplaint as string init capabilitiesProblem(
        $file,
        strList($doc, "/package/capabilities"));
    if (not ($capsComplaint == "")) {
        return bad($capsComplaint);
    }
    return Manifest{
        ok: true,
        error: "",
        name: $name,
        version: $version,
        description: str($doc, "/package/description"),
        license: str($doc, "/package/license"),
        requires: table($doc, "/decks", true),
        engines: table($doc, "/engines", false),
        capabilities: strList($doc, "/package/capabilities"),
        # Normalised here so every caller sees the same tags; cannot fail the parse.
        keywords: keywords.normalise(strList($doc, "/package/keywords"))
    };
}
