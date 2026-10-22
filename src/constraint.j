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
 * (`../app-registry`, split out on 2026-08-15) carries its own copy of each
 * rather than importing these, and its copies are currently behind this
 * repository's, so a change here usually wants porting there.
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
    if (not semver.isValid($v)) {
        return false;
    }
    def body as string init $v;
    def plus as int init strings.indexOf($body, "+");
    if ($plus >= 0) {
        $body = strings.substring($body, 0, $plus);
    }
    def ids as list of string init [];
    def dash as int init strings.indexOf($body, "-");
    if ($dash < 0) {
        $ids = strings.split($body, ".");
    } else {
        $ids = strings.split(strings.substring($body, 0, $dash), ".");
        for (def id in strings.split(rest($body, $dash + 1), ".")) {
            $ids[] = $id;
        }
    }
    for (def id in $ids) {
        if (isDigits($id) and len($id) > MAX_DIGITS) {
            return false;
        }
    }
    return true;
}

# trimAscii drops the ASCII spaces and tabs around s, and nothing else: the
# grammar allows that much padding and no other, and `strings.trim` would also
# strip Unicode whitespace.
func trimAscii(s as string) {
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

# isPartial reports whether s is the `partial` of the grammar: one to three
# numbers joined by dots, and nothing else.
func isPartial(s as string) {
    def parts as list of string init strings.split($s, ".");
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
 * Whether a constraint is in the grammar (specification 2.4): a wildcard, an
 * exact version, a caret or tilde over a partial, or a comparator over a
 * version - each with nothing else before or after it but ASCII spaces and
 * tabs, which are ignored. Something outside it is not a looser way of saying
 * something inside it, so `satisfies` matches nothing for it rather than
 * guessing: `^abc` used to read as `^0` and `^ 1.2.0` chose a 0.x release.
 *
 * Only ASCII space and tab are trimmed. `strings.trim` also strips Unicode
 * whitespace, so a constraint led by a no-break space used to be valid.
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

# rangeMatch evaluates a caret / tilde range against v. Numeric-core ranges
# target released versions, so a prerelease candidate never matches. The gate in
# `satisfies` already refuses every prerelease before this runs, since a caret
# or tilde operand is a partial (`isPartial` refuses `^0.2.0-rc.1` outright) and
# so carries no prerelease to opt in with; the check here only keeps this
# function correct on its own terms, which is what the specification says a
# range does.
func rangeMatch(v as semver.Version, lower as semver.Version, upper as semver.Version) {
    if (semver.isPrerelease($v)) {
        return false;
    }
    return inRange($v, $lower, $upper);
}

# constraintVersion returns the version text a constraint carries, with its
# operator stripped. A wildcard carries none, and a caret / tilde operand is a
# *partial* ("0.2"), which is not valid SemVer and therefore carries no
# prerelease either - which is exactly the answer wanted in both cases.
func constraintVersion(constraint as string) {
    def c as string init trimAscii($constraint);
    if ($c == "" or $c == "*" or $c == "any") {
        return "";
    }
    for (def op in [">=", "<=", ">", "<", "=", "^", "~"]) {
        if (strings.startsWith($c, $op)) {
            return trimAscii(rest($c, len($op)));
        }
    }
    return $c;
}

# sameCore reports whether two versions share a major.minor.patch, ignoring
# whatever prerelease or build metadata either carries.
func sameCore(a as semver.Version, b as semver.Version) {
    return $a.major == $b.major and $a.minor == $b.minor and $a.patch == $b.patch;
}

# prereleaseAllowed decides whether a prerelease candidate may be considered at
# all for this constraint.
#
# **A prerelease is opt-in, and the opt-in has to name it** (server
# specification 2.4). `0.2.0-dev` sorts above `0.1.0` and below `0.2.0`, which
# is what SemVer requires of *ordering*; using that ordering as a membership
# test is what silently promotes an unreleased version over the last real one
# for every consumer who wrote `*` or `>=0.1.0`. So the candidate's core must be
# named by a constraint that is itself a prerelease: `>=0.2.0-dev` reaches
# `0.2.0-rc.1`, and nothing reaches `0.3.0-alpha` but a constraint naming
# `0.3.0`.
#
# Because a constraint here is a single expression with no compound ranges,
# this needs no per-comparator bookkeeping: there is one version in the
# constraint, and either it carries a prerelease on the candidate's core or it
# does not.
func prereleaseAllowed(v as semver.Version, constraint as string) {
    def operand as string init constraintVersion($constraint);
    if (not semver.isValid($operand)) {
        return false;
    }
    def o as semver.Version init semver.parse($operand);
    if (not semver.isPrerelease($o)) {
        return false;
    }
    return sameCore($v, $o);
}

# cmpMatch evaluates a comparator (">=1.0.0" etc.): parse the operand strictly
# and compare. An unparseable operand never matches.
func cmpMatch(v as semver.Version, operand as string, op as string) {
    def o as string init trimAscii($operand);
    if (not semver.isValid($o)) {
        return false;
    }
    def c as int init semver.compare($v, semver.parse($o));
    if ($op == ">=") {
        return $c >= 0;
    }
    if ($op == "<=") {
        return $c <= 0;
    }
    if ($op == ">") {
        return $c > 0;
    }
    if ($op == "<") {
        return $c < 0;
    }
    return $c == 0;
}

# rest returns s with its first n characters dropped.
func rest(s as string, n as int) {
    return strings.substring($s, $n, len($s));
}

/**
 * Report whether a concrete version satisfies a constraint. Supported forms:
 * "*" / "" / "any" (any valid version), an exact "1.2.3" or "=1.2.3", the
 * comparators ">=", ">", "<=", "<", the caret "^1.2.0", and the tilde
 * "~1.2.3". Only single constraints are supported (no ", " / "||" compound
 * ranges), and ASCII spaces and tabs around one are ignored. An invalid or
 * unusable version string never satisfies anything, and neither does anything
 * at all for a constraint outside the grammar.
 * @param version {string} the concrete version to test (e.g. "1.4.0")
 * @param constraint {string} the constraint expression from the manifest
 * @return {bool} true when version satisfies constraint
 */
export func satisfies(version as string, constraint as string) {
    def c as string init trimAscii($constraint);
    if (not isUsableVersion($version) or not isValidConstraint($c)) {
        return false;
    }
    def v as semver.Version init semver.parse($version);
    # One gate for all six forms: the wildcards, the four comparators, and the
    # caret and tilde ranges. A prerelease reaching any of them without being
    # named would outrank the release it precedes, since it sorts above it.
    if (semver.isPrerelease($v) and not prereleaseAllowed($v, $c)) {
        return false;
    }
    if ($c == "" or $c == "*" or $c == "any") {
        return true;
    }
    if (strings.startsWith($c, "^")) {
        def core as Core init parseCore(rest($c, 1));
        return rangeMatch($v, coreLower($core), caretUpper($core));
    }
    if (strings.startsWith($c, "~")) {
        def core as Core init parseCore(rest($c, 1));
        return rangeMatch($v, coreLower($core), tildeUpper($core));
    }
    if (strings.startsWith($c, ">=")) {
        return cmpMatch($v, rest($c, 2), ">=");
    }
    if (strings.startsWith($c, "<=")) {
        return cmpMatch($v, rest($c, 2), "<=");
    }
    if (strings.startsWith($c, ">")) {
        return cmpMatch($v, rest($c, 1), ">");
    }
    if (strings.startsWith($c, "<")) {
        return cmpMatch($v, rest($c, 1), "<");
    }
    if (strings.startsWith($c, "=")) {
        return cmpMatch($v, rest($c, 1), "=");
    }
    return cmpMatch($v, $c, "=");
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
        if (not isUsableVersion($ver)) {
            continue;
        }
        def parsed as semver.Version init semver.parse($ver);
        if (not semver.isPrerelease($parsed)) {
            continue;
        }
        if (not $have or semver.compare($parsed, $bestVer) > 0) {
            $bestVer = $parsed;
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
 * Versions that `isUsableVersion` refuses are skipped. This is for a caller
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
        if (not isUsableVersion($ver)) {
            continue;
        }
        def parsed as semver.Version init semver.parse($ver);
        if (not $have or semver.compare($parsed, $bestVer) > 0) {
            $bestVer = $parsed;
            $chosen = $ver;
            $have = true;
        }
    }
    return $chosen;
}

/**
 * Pick the highest version from a list that satisfies the constraint. Versions
 * that are not valid SemVer are skipped. Returns "" when none match.
 * @param versions {list of string} the candidate versions
 * @param constraint {string} the constraint expression
 * @return {string} the highest satisfying version, or "" if none match
 */
export func best(versions as list of string, constraint as string) {
    def chosen as string init "";
    def have as bool init false;
    def bestVer as semver.Version;
    for (def ver in $versions) {
        if (satisfies($ver, $constraint)) {
            def parsed as semver.Version init semver.parse($ver);
            if (not $have or semver.compare($parsed, $bestVer) > 0) {
                $bestVer = $parsed;
                $chosen = $ver;
                $have = true;
            }
        }
    }
    return $chosen;
}
