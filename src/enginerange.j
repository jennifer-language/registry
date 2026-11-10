# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The `[engines]` range of a deck and whether an interpreter version admits
 * it. An engine range (the value of the `jennifer` and `jennifer-tiny` keys)
 * takes exactly two forms, and no other:
 *
 *     >=X.Y.Z            a floor
 *     >=X.Y.Z <A.B.C     a floor and an exclusive upper bound above it
 *
 * with one space between the two, plain `X.Y.Z` versions (no prerelease, no
 * build, no leading zeros) and nothing else: no caret, tilde, `||` or `<=`.
 * The interpreter's `# pragma-jennifer-version` takes the same two forms and
 * the same rule for a version, so a deck's manifest and its pragmas agree.
 *
 * **A development build** (`dev`, or a version with `-dev` in it, such as
 * `0.25.0-dev+131.afd9207`) passes every floor and fails every upper bound: it
 * counts as newer than any release, since it cannot know whether the next tag
 * is a patch or a minor. Any other version is compared by its `X.Y.Z` core,
 * numerically.
 *
 * Pure Jennifer over `strings` / `convert`. The CLI resolves, gates installs
 * and checks publishes with it; the registry (`../app-registry`) carries an
 * identical copy, as it does of `resolver`, which imports this. Keep the copies
 * identical.
 * @module enginerange
 * @example
 * import "./enginerange.j" as enginerange;
 * enginerange.isValidRange(">=0.25.0 <0.26.0");         # true
 * enginerange.admits(">=0.25.0 <0.26.0", "0.25.3");     # true
 * enginerange.admits(">=0.25.0 <0.26.0", "0.26.0");     # false
 * enginerange.admits(">=0.25.0 <0.26.0", "0.26.0-dev+4"); # false (a dev build)
 */

use strings;
use convert;

/**
 * The two accepted forms, for messages that refuse anything else.
 */
export def const FORMS as string init "\">=X.Y.Z\" or \">=X.Y.Z <A.B.C\"";

# The longest number a range or version part may carry: past 18 digits it no
# longer fits in an int (the limit `constraint` applies too).
def const MAX_DIGITS as int init 18;

# The decimal digits.
def const DIGITS as string init "0123456789";

/**
 * A parsed engine range.
 * @field ok {bool} whether the text was inside the grammar
 * @field problem {string} why it is not ("" when ok)
 * @field floor {string} the floor, `X.Y.Z` ("" unless ok)
 * @field upper {string} the exclusive upper bound, `A.B.C` ("" when there is none)
 */
export def struct Range {
    ok as bool,
    problem as string,
    floor as string,
    upper as string
};

# Core is an X.Y.Z read into numbers; ok is false when the text was not one.
def struct Core {
    ok as bool,
    major as int,
    minor as int,
    patch as int
};

# isNumber reports whether s is a run of decimal digits short enough to hold,
# with no leading zero.
func isNumber(s as string) {
    if (len($s) == 0 or len($s) > MAX_DIGITS) {
        return false;
    }
    for (def ch in strings.chars($s)) {
        if (strings.indexOf(DIGITS, $ch) < 0) {
            return false;
        }
    }
    return len($s) == 1 or not strings.startsWith($s, "0");
}

# readCore reads a plain X.Y.Z, and nothing more, into numbers.
func readCore(s as string) {
    def none as Core init Core{ok: false, major: 0, minor: 0, patch: 0};
    def parts as list of string init strings.split($s, ".");
    if (len($parts) != 3) {
        return $none;
    }
    for (def part in $parts) {
        if (not isNumber($part)) {
            return $none;
        }
    }
    return Core{
        ok: true,
        major: convert.toInt($parts[0]),
        minor: convert.toInt($parts[1]),
        patch: convert.toInt($parts[2])
    };
}

# compare orders two cores: negative, zero or positive as a is below, equal to
# or above b.
func compare(a as Core, b as Core) {
    if ($a.major != $b.major) {
        return $a.major - $b.major;
    }
    if ($a.minor != $b.minor) {
        return $a.minor - $b.minor;
    }
    return $a.patch - $b.patch;
}

# refused is a Range outside the grammar, with the reason.
func refused(problem as string) {
    return Range{ok: false, problem: $problem, floor: "", upper: ""};
}

/**
 * Parse an engine range, `>=X.Y.Z` or `>=X.Y.Z <A.B.C`. Anything else is
 * refused with the reason: another operator, a missing floor, extra or
 * missing spaces, a version that is not a plain `X.Y.Z`, or an upper bound not
 * above the floor (a range nothing can satisfy).
 * @param range {string} the range text
 * @return {Range} the parsed range, or one with `ok` false and a `problem`
 */
export func parse(range as string) {
    if (not strings.startsWith($range, ">=")) {
        return refused("an engine range starts with a \">=\" floor");
    }
    def parts as list of string init strings.split(strings.substring($range, 2, len($range)), " ");
    if (len($parts) > 2) {
        return refused("an engine range is a floor and at most one upper bound, " +
            "separated by one space");
    }
    def floor as Core init readCore($parts[0]);
    if (not $floor.ok) {
        return refused("the floor \"" + $parts[0] + "\" is not a plain X.Y.Z version");
    }
    if (len($parts) == 1) {
        return Range{ok: true, problem: "", floor: $parts[0], upper: ""};
    }
    def bound as string init $parts[1];
    if (not strings.startsWith($bound, "<") or strings.startsWith($bound, "<=")) {
        return refused("the upper bound \"" + $bound + "\" is not \"<A.B.C\" " +
            "(an exclusive bound)");
    }
    $bound = strings.substring($bound, 1, len($bound));
    def upper as Core init readCore($bound);
    if (not $upper.ok) {
        return refused("the upper bound \"" + $bound + "\" is not a plain X.Y.Z version");
    }
    if (compare($upper, $floor) <= 0) {
        return refused("the upper bound " + $bound + " is not above the floor " +
            $parts[0] + ", so no version satisfies it");
    }
    return Range{ok: true, problem: "", floor: $parts[0], upper: $bound};
}

/**
 * Whether a range is one of the two accepted forms (`parse` says why not).
 * @param range {string} the range text
 * @return {bool} true for `>=X.Y.Z` or `>=X.Y.Z <A.B.C` with the bound above the floor
 */
export func isValidRange(range as string) {
    return parse($range).ok;
}

/**
 * Whether an `[engines]` key is one whose value is an engine range: `jennifer`
 * or `jennifer-tiny`, in any case.
 * @param name {string} the `[engines]` key
 * @return {bool} true for the two Jennifer engines
 */
export func isEngineKey(name as string) {
    def key as string init strings.lower($name);
    return $key == "jennifer" or $key == "jennifer-tiny";
}

/**
 * Whether an interpreter version names a development build: the literal `dev`
 * (a plain `go build`), or a version with `-dev` in it
 * (`0.25.0-dev+131.afd9207`).
 * @param version {string} the interpreter version
 * @return {bool} true for a development build
 */
export func isDevBuild(version as string) {
    return $version == "dev" or strings.contains($version, "-dev");
}

# coreOf reads a release version's X.Y.Z core, dropping any prerelease or
# build suffix.
func coreOf(version as string) {
    def base as string init $version;
    def dash as int init strings.indexOf($base, "-");
    if ($dash >= 0) {
        $base = strings.substring($base, 0, $dash);
    }
    def plus as int init strings.indexOf($base, "+");
    if ($plus >= 0) {
        $base = strings.substring($base, 0, $plus);
    }
    return readCore($base);
}

/**
 * Whether an interpreter version can be judged at all: a development build, or
 * a version with an `X.Y.Z` core. An empty or unrecognisable version is not,
 * and a caller does not filter by a range it cannot judge.
 * @param version {string} the interpreter version
 * @return {bool} true when `admits` can answer for it
 */
export func isKnownVersion(version as string) {
    return isDevBuild($version) or coreOf($version).ok;
}

/**
 * Whether an interpreter version admits an engine range. A development build
 * passes every floor and fails every upper bound; any other version passes when
 * floor <= its X.Y.Z core < upper. A range outside the grammar, or a version
 * that is neither, admits nothing.
 * @param range {string} the engine range
 * @param version {string} the interpreter version, prerelease and build included
 * @return {bool} true when the version is inside the range
 */
export func admits(range as string, version as string) {
    def r as Range init parse($range);
    if (not $r.ok) {
        return false;
    }
    if (isDevBuild($version)) {
        return $r.upper == "";
    }
    def v as Core init coreOf($version);
    if (not $v.ok or compare($v, readCore($r.floor)) < 0) {
        return false;
    }
    return $r.upper == "" or compare($v, readCore($r.upper)) < 0;
}

/**
 * Whether a deck version's `[engines]` lets an interpreter run it: no entries
 * at all impose nothing; otherwise the running engine must be listed (the keys
 * are alternatives) and its version must admit that entry's range. An unknown
 * version ("") is not judged against the range, only against the list.
 * @param engines {map of string to string} the deck version's `[engines]`
 * @param engine {string} the running engine, "jennifer" or "jennifer-tiny"
 * @param version {string} its version, "" when unknown
 * @return {bool} true when the version may be installed for this interpreter
 */
export func runsOn(engines as map of string to string, engine as string, version as string) {
    if (len($engines) == 0) {
        return true;
    }
    def range as string init rangeFor($engines, $engine);
    if ($range == "") {
        return false;
    }
    return $version == "" or admits($range, $version);
}

/**
 * The range an `[engines]` map gives an engine, its key compared without case,
 * or "" when the engine is not listed.
 * @param engines {map of string to string} the `[engines]` entries
 * @param engine {string} the engine name
 * @return {string} the range, or ""
 */
export func rangeFor(engines as map of string to string, engine as string) {
    def want as string init strings.lower($engine);
    for (def key in $engines) {
        if (strings.lower($key) == $want) {
            return $engines[$key];
        }
    }
    return "";
}
