# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Version-constraint matching for deck dependencies. A manifest pins
 * each deck with a small range grammar - "^1.2.0", "~0.4", ">=1.0.0", "1.2.3",
 * or "*" - and this module evaluates such a constraint against a concrete
 * SemVer version and picks the best match from a set. The `semver` module owns
 * version values and their ordering; range matching is deliberately out of its
 * scope, so it lives here. Pure Jennifer over `strings` / `convert` + `semver`.
 *
 * The CLI owns resolution, and this module is one of the four pure ones it
 * resolves with (with `catalog`, `resolver` and `deckname`). The registry
 * (`../app-registry`) carries its own copy of each. Keep the copies identical,
 * and diff both ways before changing either.
 * @module constraint
 * @example
 * import "./constraint.j" as constraint;
 * constraint.satisfies("1.4.0", "^1.2.0");                  # true
 * constraint.best(["1.0.0", "1.4.0", "2.0.0"], "^1.2.0");   # "1.4.0"
 */

use strings;
use convert;
import "semver.j" as semver;

# The decimal digits, used by isDigits (string `<` ordering is avoided in
# favour of an explicit membership test).
def const DIGITS as string init "0123456789";

# The longest numeric identifier a version or constraint may carry. SemVer sets
# no limit, but every number here is held in an int: past 18 digits a part no
# longer fits, or overflows once a caret range adds one to it, and parsing it
# throws. 18 digits still admits a date or a timestamp as a version part.
def const MAX_DIGITS as int init 18;

/**
 * A parsed numeric version core: the major / minor / patch numbers plus how
 * many of them the source text specified. Missing trailing numbers read as 0;
 * `count` drives the caret / tilde upper-bound rules, where a partial "^0"
 * ranges wider than a full "^0.0.0".
 * @field major {int} the major number (0 when unspecified)
 * @field minor {int} the minor number (0 when unspecified)
 * @field patch {int} the patch number (0 when unspecified)
 * @field count {int} how many numeric components were specified (1-3)
 */
def struct Core {
    major as int,
    minor as int,
    patch as int,
    count as int
};

# isDigits reports whether s is a non-empty run of decimal digits.
func isDigits(s as string) {
    if (len($s) == 0) {
        return false;
    }
    for (def ch in strings.chars($s)) {
        if (strings.indexOf(DIGITS, $ch) < 0) {
            return false;
        }
    }
    return true;
}

# parseCore reads the numeric core of a version / range operand ("1.2.3",
# "1.2", "1", or a "1.x" prefix), stopping at the first non-numeric component
# and at any prerelease ("-") or build ("+") suffix. count is how many numeric
# components were consumed (1-3).
func parseCore(s as string) {
    def core as Core init Core{major: 0, minor: 0, patch: 0, count: 0};
    def base as string init $s;
    def dash as int init strings.indexOf($base, "-");
    if ($dash >= 0) {
        $base = strings.substring($base, 0, $dash);
    }
    def plus as int init strings.indexOf($base, "+");
    if ($plus >= 0) {
        $base = strings.substring($base, 0, $plus);
    }
    def idx as int init 0;
    for (def part in strings.split($base, ".")) {
        if ($idx >= 3 or not isDigits($part)) {
            break;
        }
        def n as int init convert.toInt($part);
        if ($idx == 0) {
            $core.major = $n;
        } elseif ($idx == 1) {
            $core.minor = $n;
        } else {
            $core.patch = $n;
        }
        $core.count = $idx + 1;
        $idx = $idx + 1;
    }
    return $core;
}

# isNumber reports whether s is a numeric identifier short enough to hold, with
# no leading zero. SemVer forbids one (`01` is not a version number), and the
# comparator operands already go through `semver.isValid`, which refuses it; a
# caret or tilde partial is checked here, so `^01.2` is outside the grammar too
# rather than quietly reading as `^1.2`.
func isNumber(s as string) {
    if (not isDigits($s) or len($s) > MAX_DIGITS) {
        return false;
    }
    return len($s) == 1 or not strings.startsWith($s, "0");
}

/**
 * Whether a version is valid SemVer **and** every numeric identifier in it fits
 * in an int, which is what ordering and range arithmetic need. A version that is
 * valid but too large would pass a SemVer check and then throw the first time it
 * is compared, so anything that stores or compares versions asks this instead.
 * Build metadata is never compared and is not limited.
 * @param v {string} the version
 * @return {bool} true when it can be ordered and matched safely
 */
export func isUsableVersion(v as string) {
    return usable($v).ok;
}

# Usable is a version read once: whether it is usable (`isUsableVersion`) and,
# when it is, its parsed form.
def struct Usable {
    ok as bool,
    version as semver.Version
};

# usable parses a version once and checks it fits (`isUsableVersion`).
# `semver.parse` runs the SemVer grammar a single time and throws on anything
# outside it; checking with `semver.isValid` first and parsing after ran the
# regex twice, and every caller then parsed a third time.
func usable(v as string) {
    def none as Usable init Usable{ok: false, version: version(0, 0, 0)};
    def parsed as semver.Version init version(0, 0, 0);
    try {
        $parsed = semver.parse($v);
    } catch (err) {
        return $none;
    }
    if (not fitsDigits($v)) {
        return $none;
    }
    return Usable{ok: true, version: $parsed};
}

# fitsDigits reports whether every numeric identifier of a valid version's core
# and prerelease is at most MAX_DIGITS long. Build metadata is never compared.
func fitsDigits(v as string) {
    # No identifier can be longer than the whole text, which settles nearly
    # every version without splitting it.
    if (len($v) <= MAX_DIGITS) {
        return true;
    }
    def body as string init $v;
    def plus as int init strings.indexOf($body, "+");
    if ($plus >= 0) {
        $body = strings.substring($body, 0, $plus);
    }
    # One list, appended to in place: it was reassigned per branch before,
    # which copied it on every call.
    def dash as int init strings.indexOf($body, "-");
    def core as string init $body;
    if ($dash >= 0) {
        $core = strings.substring($body, 0, $dash);
    }
    def ids as list of string init strings.split($core, ".");
    if ($dash >= 0) {
        for (def id in strings.split(rest($body, $dash + 1), ".")) {
            $ids[] = $id;
        }
    }
    for (def id in $ids) {
        if (len($id) > MAX_DIGITS and isDigits($id)) {
            return false;
        }
    }
    return true;
}

# trimAscii drops the ASCII spaces and tabs around s, and nothing else: the
# grammar allows that much padding and no other, and `strings.trim` would also
# strip Unicode whitespace.
func trimAscii(s as string) {
    if (not padded($s)) {
        return $s;
    }
    def chars as list of string init strings.chars($s);
    def lo as int init 0;
    def hi as int init len($chars);
    while ($lo < $hi and ($chars[$lo] == " " or $chars[$lo] == "\t")) {
        $lo = $lo + 1;
    }
    while ($hi > $lo and ($chars[$hi - 1] == " " or $chars[$hi - 1] == "\t")) {
        $hi = $hi - 1;
    }
    return strings.join($chars[$lo..$hi], "");
}

# padded reports whether s starts or ends with an ASCII space or tab, the only
# padding trimAscii removes; most constraints have none, and return at once.
func padded(s as string) {
    if ($s == "") {
        return false;
    }
    def first as string init strings.substring($s, 0, 1);
    def last as string init strings.substring($s, len($s) - 1, len($s));
    return $first == " " or $first == "\t" or $last == " " or $last == "\t";
}

# isPartial reports whether s is the `partial` of the grammar: one to three
# numbers joined by dots, and nothing else. The split goes straight into the
# check: bound to a variable first, it was copied on every call.
func isPartial(s as string) {
    return partsArePartial(strings.split($s, "."));
}

# partsArePartial is isPartial over the dot-separated parts.
func partsArePartial(parts as list of string) {
    if (len($parts) < 1 or len($parts) > 3) {
        return false;
    }
    for (def part in $parts) {
        if (not isNumber($part)) {
            return false;
        }
    }
    return true;
}

/**
 * Whether a constraint is in the grammar (server specification 2.4): a
 * wildcard, an exact version, a caret or tilde over a partial, or a comparator
 * over a version, each with nothing before or after it but ASCII spaces and
 * tabs, which are ignored. `satisfies` matches nothing for a constraint outside
 * the grammar rather than guessing (`^abc` is not `^0`).
 *
 * Only ASCII space and tab are trimmed: `strings.trim` also strips Unicode
 * whitespace, which would make a constraint led by a no-break space valid.
 * @param constraint {string} the constraint expression
 * @return {bool} true when it is in the grammar
 */
export func isValidConstraint(constraint as string) {
    def c as string init trimAscii($constraint);
    if ($c == "" or $c == "*" or $c == "any") {
        return true;
    }
    if (strings.startsWith($c, "^") or strings.startsWith($c, "~")) {
        return isPartial(rest($c, 1));
    }
    for (def op in [">=", "<=", ">", "<", "="]) {
        if (strings.startsWith($c, $op)) {
            return isUsableVersion(rest($c, len($op)));
        }
    }
    return isUsableVersion($c);
}

/**
 * A constraint read once, for matching against many versions (`matches`).
 * `satisfies` parses its constraint on every call; a caller testing a list of
 * versions against the same constraints parses each constraint once here.
 * @field valid {bool} false for a constraint outside the grammar, which matches nothing
 * @field any {bool} true for a wildcard
 * @field op {string} `^`, `~`, `>=`, `<=`, `>`, `<` or `=` (an exact version is `=`)
 * @field lower {semver.Version} a range's inclusive lower bound, or a comparator's operand
 * @field upper {semver.Version} a caret or tilde range's exclusive upper bound
 * @field pre {bool} true when the constraint names a prerelease, which opts that core in
 */
export def struct Range {
    valid as bool,
    any as bool,
    op as string,
    lower as semver.Version,
    upper as semver.Version,
    pre as bool
};

/**
 * Read a constraint once (`Range`). A constraint outside the grammar
 * (`isValidConstraint`) comes back with `valid` false.
 * @param constraint {string} the constraint expression
 * @return {Range} the parsed constraint
 */
export func parseRange(constraint as string) {
    def zero as semver.Version init version(0, 0, 0);
    def out as Range init Range{
        valid: false,
        any: false,
        op: "",
        lower: $zero,
        upper: $zero,
        pre: false
    };
    def c as string init trimAscii($constraint);
    if ($c == "" or $c == "*" or $c == "any") {
        $out.valid = true;
        $out.any = true;
        return $out;
    }
    if (strings.startsWith($c, "^") or strings.startsWith($c, "~")) {
        if (not isPartial(rest($c, 1))) {
            return $out;
        }
        def core as Core init parseCore(rest($c, 1));
        $out.valid = true;
        $out.op = strings.substring($c, 0, 1);
        $out.lower = coreLower($core);
        $out.upper = tildeUpper($core);
        if ($out.op == "^") {
            $out.upper = caretUpper($core);
        }
        return $out;
    }
    $out.op = "=";
    def operand as string init $c;
    for (def op in [">=", "<=", ">", "<", "="]) {
        if (strings.startsWith($c, $op)) {
            $out.op = $op;
            $operand = rest($c, len($op));
            break;
        }
    }
    def u as Usable init usable($operand);
    if (not $u.ok) {
        return $out;
    }
    $out.valid = true;
    $out.lower = $u.version;
    $out.pre = semver.isPrerelease($u.version);
    return $out;
}

/**
 * Report whether a parsed, usable version satisfies a parsed constraint, by
 * exactly the rules of `satisfies` (prerelease opt-in included).
 * @param v {semver.Version} the version, already parsed and usable
 * @param r {Range} the constraint, from `parseRange`
 * @return {bool} true when v satisfies r
 */
export func matches(v as semver.Version, r as Range) {
    if (not $r.valid) {
        return false;
    }
    # One gate for every form: wildcard, exact, comparator, caret and tilde. A
    # caret or tilde partial never names a prerelease.
    #
    # **A prerelease is opt-in, and the opt-in has to name it** (server
    # specification 2.4). `0.2.0-dev` sorts above `0.1.0` and below `0.2.0`,
    # which is what SemVer requires of *ordering*; using that ordering as a
    # membership test is what silently promotes an unreleased version over the
    # last real one for every consumer who wrote `*` or `>=0.1.0`. So the
    # candidate's core must be named by a constraint that is itself a
    # prerelease: `>=0.2.0-dev` reaches `0.2.0-rc.1`, and nothing reaches
    # `0.3.0-alpha` but a constraint naming a 0.3.0 prerelease. A constraint
    # here is a single expression, so there is one version in it, and either it
    # carries a prerelease on the candidate's core or it does not.
    if (semver.isPrerelease($v) and not ($r.pre and sameCore($v, $r.lower))) {
        return false;
    }
    if ($r.any) {
        return true;
    }
    if ($r.op == "^" or $r.op == "~") {
        return rangeMatch($v, $r.lower, $r.upper);
    }
    def c as int init semver.compare($v, $r.lower);
    if ($r.op == ">=") {
        return $c >= 0;
    }
    if ($r.op == "<=") {
        return $c <= 0;
    }
    if ($r.op == ">") {
        return $c > 0;
    }
    if ($r.op == "<") {
        return $c < 0;
    }
    return $c == 0;
}

/**
 * Report whether a version satisfies every constraint in a list, reading the
 * version once rather than once per constraint.
 * @param version {string} the version
 * @param constraints {list of string} the constraints, all of which must hold
 * @return {bool} true when every constraint is satisfied
 */
export func satisfiesEvery(version as string, constraints as list of string) {
    def u as Usable init usable($version);
    if (not $u.ok) {
        return false;
    }
    for (def c in $constraints) {
        if (not matches($u.version, parseRange($c))) {
            return false;
        }
    }
    return true;
}

/**
 * The highest version in a list satisfying every constraint, or "" when none
 * does: `satisfiesEvery` and `highest` in one pass, with each constraint and
 * each version read once. The resolver picks with this.
 * @param versions {list of string} the candidate versions
 * @param constraints {list of string} the constraints, all of which must hold
 * @return {string} the highest version satisfying all of them, or ""
 */
export func bestOf(versions as list of string, constraints as list of string) {
    def ranges as list of Range init [];
    for (def c in $constraints) {
        $ranges[] = parseRange($c);
    }
    def chosen as string init "";
    def bestVer as semver.Version init version(0, 0, 0);
    for (def ver in $versions) {
        def u as Usable init usable($ver);
        if (not $u.ok or not matchesAll($u.version, $ranges)) {
            continue;
        }
        if ($chosen == "" or outranks($u.version, $ver, $bestVer, $chosen)) {
            $bestVer = $u.version;
            $chosen = $ver;
        }
    }
    return $chosen;
}

# matchesAll reports whether v satisfies every range.
func matchesAll(v as semver.Version, ranges as list of Range) {
    for (def r in $ranges) {
        if (not matches($v, $r)) {
            return false;
        }
    }
    return true;
}

# outranks reports whether a candidate should replace the best so far. SemVer
# orders first; versions it calls equal differ only in build metadata, which
# SemVer leaves unordered, so the one without build metadata wins, then the
# lexically smaller text. Taking whichever came first locked `1.0.0` or
# `1.0.0+b` depending on the order a registry listed them.
func outranks(v as semver.Version, text as string, best as semver.Version, bestText as string) {
    def c as int init semver.compare($v, $best);
    if (not ($c == 0)) {
        return $c > 0;
    }
    if (not (($v.build == "") == ($best.build == ""))) {
        return $v.build == "";
    }
    return $text < $bestText;
}

# version builds a release semver.Version (no prerelease / build) from parts.
func version(major as int, minor as int, patch as int) {
    return semver.Version{major: $major, minor: $minor, patch: $patch, prerelease: "", build: ""};
}

# coreLower is the inclusive lower bound a caret / tilde core denotes.
func coreLower(core as Core) {
    return version($core.major, $core.minor, $core.patch);
}

# caretUpper is the exclusive upper bound of a caret range. It bumps the
# left-most non-zero component, but a partial "^0" / "^0.0" widens to the next
# unspecified position (npm semantics): ^1.2.3 -> <2.0.0, ^0.2.3 -> <0.3.0,
# ^0.0.3 -> <0.0.4, ^0.0 -> <0.1.0, ^0 -> <1.0.0.
func caretUpper(core as Core) {
    if ($core.major > 0) {
        return version($core.major + 1, 0, 0);
    }
    if ($core.minor > 0) {
        return version(0, $core.minor + 1, 0);
    }
    if ($core.count >= 3) {
        return version(0, 0, $core.patch + 1);
    }
    if ($core.count == 2) {
        return version(0, 1, 0);
    }
    return version(1, 0, 0);
}

# tildeUpper is the exclusive upper bound of a tilde range: it allows patch
# moves when a minor is given, else major moves. ~1.2.3 / ~1.2 -> <1.3.0,
# ~1 -> <2.0.0.
func tildeUpper(core as Core) {
    if ($core.count >= 2) {
        return version($core.major, $core.minor + 1, 0);
    }
    return version($core.major + 1, 0, 0);
}

# inRange reports whether v is within [lower, upper).
func inRange(v as semver.Version, lower as semver.Version, upper as semver.Version) {
    return semver.compare($v, $lower) >= 0 and semver.compare($v, $upper) < 0;
}

# rangeMatch evaluates a caret / tilde range against v. A numeric range never
# matches a prerelease. `matches` already refuses one before this runs, since
# a partial cannot name a prerelease (`isPartial` refuses `^0.2.0-rc.1`); the
# check keeps this function correct on its own.
func rangeMatch(v as semver.Version, lower as semver.Version, upper as semver.Version) {
    if (semver.isPrerelease($v)) {
        return false;
    }
    return inRange($v, $lower, $upper);
}

# sameCore reports whether two versions share a major.minor.patch, ignoring
# whatever prerelease or build metadata either carries.
func sameCore(a as semver.Version, b as semver.Version) {
    return $a.major == $b.major and $a.minor == $b.minor and $a.patch == $b.patch;
}

# rest returns s with its first n characters dropped.
func rest(s as string, n as int) {
    return strings.substring($s, $n, len($s));
}

/**
 * Report whether a concrete version satisfies a constraint. Supported forms:
 * "*" / "" / "any" (any release), an exact "1.2.3" or "=1.2.3", the
 * comparators ">=", ">", "<=", "<", the caret "^1.2.0", and the tilde
 * "~1.2.3". Only single constraints are supported (no ", " / "||" compound
 * ranges), and ASCII spaces and tabs around one are ignored. A prerelease
 * satisfies only a constraint that names a prerelease of the same
 * major.minor.patch, so `satisfies("1.0.0-rc.1", "*")` is false and
 * `satisfies("1.0.0-rc.1", ">=1.0.0-rc.0")` true. An invalid or unusable version
 * never satisfies anything, and nothing satisfies a constraint outside the
 * grammar.
 * @param version {string} the concrete version to test (e.g. "1.4.0")
 * @param constraint {string} the constraint expression from the manifest
 * @return {bool} true when version satisfies constraint
 */
export func satisfies(version as string, constraint as string) {
    def r as Range init parseRange($constraint);
    if (not $r.valid) {
        return false;
    }
    def u as Usable init usable($version);
    if (not $u.ok) {
        return false;
    }
    return matches($u.version, $r);
}

/**
 * The newest prerelease among these versions, or `""` when none is one.
 *
 * This exists for the failure message. Once a prerelease only matches a
 * constraint that names it, a deck whose every published version is a
 * prerelease satisfies nothing, and "no version satisfies `*`" then reads as
 * "this deck does not exist". Naming the newest prerelease turns a dead end
 * into an instruction. A version that `isUsableVersion` refuses is skipped: this
 * runs on the failure path, and comparing one would throw there instead.
 * @param versions {list of string} the candidate versions
 * @return {string} the highest prerelease, or "" when there is none
 */
export func newestPrerelease(versions as list of string) {
    def chosen as string init "";
    def have as bool init false;
    def bestVer as semver.Version;
    for (def ver in $versions) {
        def u as Usable init usable($ver);
        if (not $u.ok or not semver.isPrerelease($u.version)) {
            continue;
        }
        if (not $have or outranks($u.version, $ver, $bestVer, $chosen)) {
            $bestVer = $u.version;
            $chosen = $ver;
            $have = true;
        }
    }
    return $chosen;
}

/**
 * The sentence to add to a "nothing satisfies this" failure when the only
 * thing on offer is unreleased.
 * @param versions {list of string} the candidate versions
 * @return {string} the explanatory clause, or "" when a release exists
 */
export func prereleaseHint(versions as list of string) {
    def newest as string init newestPrerelease($versions);
    if ($newest == "") {
        return "";
    }
    # Only when there is nothing else. A deck that has releases and also a
    # prerelease failed the constraint for some ordinary reason, and "no stable
    # version yet" would be a false explanation of a true failure.
    for (def ver in $versions) {
        if (isUsableVersion($ver) and not semver.isPrerelease(semver.parse($ver))) {
            return "";
        }
    }
    return " (no stable version yet: the newest is " + $newest +
        ", and a prerelease is only chosen by a constraint that names it, " +
        "such as \"=" + $newest + "\")";
}

/**
 * The highest version in a list, under SemVer ordering, with no constraint and
 * no prerelease rule applied: a prerelease competes like any other version.
 * Versions that `isUsableVersion` refuses are skipped, and versions equal under
 * SemVer are ordered as in `best`. This is for a caller
 * that has already filtered the list itself (the resolver keeps only versions
 * satisfying every constraint on a deck); `best(list, "*")` is not a substitute,
 * because `*` refuses every prerelease, including one a constraint named.
 * @param versions {list of string} the candidate versions
 * @return {string} the highest usable version, or "" when there is none
 */
export func highest(versions as list of string) {
    def chosen as string init "";
    def have as bool init false;
    def bestVer as semver.Version;
    for (def ver in $versions) {
        def u as Usable init usable($ver);
        if (not $u.ok) {
            continue;
        }
        if (not $have or outranks($u.version, $ver, $bestVer, $chosen)) {
            $bestVer = $u.version;
            $chosen = $ver;
            $have = true;
        }
    }
    return $chosen;
}

/**
 * Pick the highest version from a list that satisfies the constraint. Skipped:
 * versions that are not valid SemVer, unusable ones (a numeric identifier over
 * 18 digits), and prereleases the constraint does not name (`satisfies`).
 * Returns "" when none match. Versions SemVer orders equal (they differ only in
 * build metadata) are told apart by `outranks`: no build metadata first, then
 * the lexically smaller.
 * @param versions {list of string} the candidate versions
 * @param constraint {string} the constraint expression
 * @return {string} the highest satisfying version, or "" if none match
 */
export func best(versions as list of string, constraint as string) {
    return bestOf($versions, [$constraint]);
}
