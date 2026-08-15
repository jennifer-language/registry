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
# target released versions, so a prerelease candidate never matches.
func rangeMatch(v as semver.Version, lower as semver.Version, upper as semver.Version) {
    if (semver.isPrerelease($v)) {
        return false;
    }
    return inRange($v, $lower, $upper);
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
    if ($c == "" or $c == "*" or $c == "any") {
        return semver.isValid($version);
    }
    if (not semver.isValid($version)) {
        return false;
    }
    def v as semver.Version init semver.parse($version);
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
