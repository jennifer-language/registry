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
 * Lives in `cli/` because the CLI owns resolution; the server's `store` imports
 * it across the directory boundary for its own `/resolve` endpoint.
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
    def core as Core init Core{ major: 0, minor: 0, patch: 0, count: 0 };
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

# version builds a release semver.Version (no prerelease / build) from parts.
func version(major as int, minor as int, patch as int) {
    return semver.Version{ major: $major, minor: $minor, patch: $patch, prerelease: "", build: "" };
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
# `satisfies` already refuses almost every prerelease here, since a caret
# operand is a partial and carries no prerelease to opt in with; this keeps the
# one spelling that could slip through (`^0.2.0-rc.1`) closed too, which is what
# the specification says a range does.
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
    def c as string init strings.trim($constraint);
    if ($c == "" or $c == "*" or $c == "any") {
        return "";
    }
    for (def op in [">=", "<=", ">", "<", "=", "^", "~"]) {
        if (strings.startsWith($c, $op)) {
            return strings.trim(rest($c, len($op)));
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
    def o as string init strings.trim($operand);
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
 * ranges). An invalid version string never satisfies anything.
 * @param version {string} the concrete version to test (e.g. "1.4.0")
 * @param constraint {string} the constraint expression from the manifest
 * @return {bool} true when version satisfies constraint
 */
export func satisfies(version as string, constraint as string) {
    def c as string init strings.trim($constraint);
    if (not semver.isValid($version)) {
        return false;
    }
    def v as semver.Version init semver.parse($version);
    # One gate for all six forms. The rule used to live inside `rangeMatch`,
    # which only caret and tilde reach, so `*` and every comparator admitted a
    # prerelease and `best` then preferred it over the release it precedes.
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
 * Pick the highest version from a list that satisfies the constraint. Versions
 * that are not valid SemVer are skipped. Returns "" when none match.
 * @param versions {list of string} the candidate versions
 * @param constraint {string} the constraint expression
 * @return {string} the highest satisfying version, or "" if none match
 */
/**
 * The newest prerelease among these versions, or `""` when none is one.
 *
 * This exists for the failure message. Once a prerelease only matches a
 * constraint that names it, a deck whose every published version is a
 * prerelease satisfies nothing, and "no version satisfies `*`" then reads as
 * "this deck does not exist". Naming the newest prerelease turns a dead end
 * into an instruction.
 * @param versions {list of string} the candidate versions
 * @return {string} the highest prerelease, or "" when there is none
 */
export func newestPrerelease(versions as list of string) {
    def chosen as string init "";
    def have as bool init false;
    def bestVer as semver.Version;
    for (def ver in $versions) {
        if (not semver.isValid($ver)) {
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
        if (semver.isValid($ver) and not semver.isPrerelease(semver.parse($ver))) {
            return "";
        }
    }
    return " (no stable version yet: the newest is " + $newest +
        ", and a prerelease is only chosen by a constraint that names it, " +
        "such as \"=" + $newest + "\")";
}

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
