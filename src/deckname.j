# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Deck-name grammar and decomposition. The registry (`../app-registry`) holds
 * its own copy of this module rather than importing it. A deck has one of two
 * name forms:
 *
 *   - **bare** - a single identifier, e.g. `ansi`, naming a module bundled with
 *     the interpreter or a local file. Not a registry deck;
 *   - **scoped** - `@scope/deck`, e.g. `@jennifer/routeros`, vendored into
 *     `vendor/<scope>/<deck>/` and imported as `import "@scope/deck/"`, binding
 *     the `deck.` namespace.
 *
 * **The two halves have different grammars, because they do different jobs**
 * (specification 2.1):
 *
 *     scope = [a-z][a-z0-9-]{0,62}[a-z0-9]  |  [a-z]
 *     deck  = [a-z][a-z0-9]{0,63}
 *
 * The **deck** half becomes a Jennifer namespace, so it must be a legal
 * identifier: letters and digits only. The **scope** half is only ever a path
 * segment, so it may carry hyphens, which is what lets a real account name like
 * `jennifer-language` be expressed at all. A scope may not begin or end with a
 * hyphen, nor carry two in a row.
 *
 * **Names are lowercase, and normalised by folding rather than rejected.**
 * `@Netflix/Foo` is a valid way to write `@netflix/foo`. Two reasons, and they
 * compound: `vendor/` lands on case-insensitive filesystems, where
 * `vendor/Netflix/` and `vendor/netflix/` are one directory on macOS and Windows
 * and two on Linux; and folding removes impersonation structurally rather than
 * by a rule somebody has to remember to enforce.
 *
 * A half equal to a Windows reserved device name is refused outright, because
 * `vendor/con/` cannot be created there.
 *
 * All functions here are pure string logic - no I/O, no other modules.
 * @module deckname
 * @example
 * import "./deckname.j" as deckname;
 * def ok as bool init deckname.isValid("@jennifer-language/routeros");  # true
 * def id as string init deckname.fold("@Netflix/Foo");                  # @netflix/foo
 */

use strings;

# The character classes. Lowercase only: a name is folded before it is checked.
def const LOWER as string init "abcdefghijklmnopqrstuvwxyz";
def const DIGITS as string init "0123456789";

# Every character a name may be written with, before folding: the grammar's
# classes, their uppercase forms (folding accepts those), and the `@` and `/`
# of the scoped form. Checked before folding because folding is not ASCII-only.
def const WRITTEN as string init "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-@/"; # lint-disable: L203

# The longest a single half may be.
def const MAX_IDENT as int init 64;

# Names Windows reserves for devices. `vendor/con/` cannot be created there, so
# a half equal to one of these is refused whatever else it satisfies. `com0`
# and `lpt0` are reserved too, though Microsoft's own list long left them out;
# the superscript-digit forms (`com` followed by a superscript one, and so on)
# are reserved as well, but they are outside ASCII and refused before this list
# is consulted.
def const RESERVED_DEVICES as list of string init [
    "con",
    "prn",
    "aux",
    "nul",
    "com0",
    "com1",
    "com2",
    "com3",
    "com4",
    "com5",
    "com6",
    "com7",
    "com8",
    "com9",
    "lpt0",
    "lpt1",
    "lpt2",
    "lpt3",
    "lpt4",
    "lpt5",
    "lpt6",
    "lpt7",
    "lpt8",
    "lpt9"
];

# isLower / isLowerOrDigit test a single character's class.
func isLower(ch as string) {
    return strings.indexOf(LOWER, $ch) >= 0;
}

func isLowerOrDigit(ch as string) {
    return isLower($ch) or strings.indexOf(DIGITS, $ch) >= 0;
}

/**
 * Fold a name to its canonical form: trimmed and lowercased. This is the
 * normalisation the specification requires on the way in, so `@Netflix/Foo` is
 * recorded as `@netflix/foo` and a lookup for either finds the same deck.
 * @param name {string} the name as written
 * @return {string} the folded name
 */
export func fold(name as string) {
    return strings.lower(strings.trim($name));
}

/**
 * Report whether a folded half is a Windows reserved device name.
 * @param s {string} the folded scope or deck half
 * @return {bool} true when the name cannot be a directory on Windows
 */
export func isReservedDevice(s as string) {
    for (def name in RESERVED_DEVICES) {
        if ($name == $s) {
            return true;
        }
    }
    return false;
}

/**
 * Report whether a string is a legal **deck** half: one lowercase letter, then
 * up to 63 more lowercase letters or digits. No hyphens, because this half
 * becomes the Jennifer namespace a consumer binds.
 * @param s {string} the candidate, already folded
 * @return {bool} true when s is a legal deck half
 */
export func isIdent(s as string) {
    if (len($s) == 0 or len($s) > MAX_IDENT) {
        return false;
    }
    if (isReservedDevice($s)) {
        return false;
    }
    def chars as list of string init strings.chars($s);
    if (not isLower($chars[0])) {
        return false;
    }
    for (def i as int init 1; $i < len($chars); $i = $i + 1) {
        if (not isLowerOrDigit($chars[$i])) {
            return false;
        }
    }
    return true;
}

/**
 * Report whether a string is a legal **scope** half: like a deck half, but
 * hyphens are permitted between the first and last character. It may not begin
 * or end with one, nor carry two in a row.
 *
 * Hyphens are allowed here and nowhere else because a scope is only ever a path
 * segment, never a bound namespace.
 * @param s {string} the candidate, already folded
 * @return {bool} true when s is a legal scope half
 */
export func isScopeIdent(s as string) {
    if (len($s) == 0 or len($s) > MAX_IDENT) {
        return false;
    }
    if (isReservedDevice($s)) {
        return false;
    }
    def chars as list of string init strings.chars($s);
    def last as int init len($chars) - 1;
    if (not isLower($chars[0])) {
        return false;
    }
    if (not isLowerOrDigit($chars[$last])) {
        return false;
    }
    for (def i as int init 1; $i < $last; $i = $i + 1) {
        if (isLowerOrDigit($chars[$i])) {
            continue;
        }
        if (not ($chars[$i] == "-")) {
            return false;
        }
        if ($chars[$i - 1] == "-") {
            return false;
        }
    }
    return true;
}

/**
 * Report whether a name uses the scoped `@scope/deck` form (a leading `@` and a
 * `/`). This is a shape test, not a full validity check - use `isValid` to also
 * verify the two halves.
 * @param name {string} the deck name
 * @return {bool} true when the name looks scoped
 */
export func isScoped(name as string) {
    return strings.startsWith($name, "@") and strings.indexOf($name, "/") > 0;
}

/**
 * Return the scope of a scoped name without the leading `@`, folded (so
 * "@Jennifer/Routeros" yields "jennifer"), or "" for a bare name.
 * @param name {string} the deck name
 * @return {string} the folded scope, or "" when the name is not scoped
 */
export func scopeOf(name as string) {
    def folded as string init fold($name);
    if (not isScoped($folded)) {
        return "";
    }
    def slash as int init strings.indexOf($folded, "/");
    return strings.substring($folded, 1, $slash);
}

/**
 * Return the deck component of a name, folded: the part after `@scope/` for a
 * scoped name, or the whole name for a bare one.
 * @param name {string} the deck name
 * @return {string} the folded deck component
 */
export func deckOf(name as string) {
    def folded as string init fold($name);
    if (not isScoped($folded)) {
        return $folded;
    }
    def slash as int init strings.indexOf($folded, "/");
    return strings.substring($folded, $slash + 1, len($folded));
}

# trimAscii drops the ASCII spaces and tabs around s, and nothing else.
# `strings.trim` also strips Unicode whitespace (a no-break space, an
# ideographic space), which would let a name carrying one pass the ASCII check.
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

/**
 * Report whether a name is well-formed: a bare deck identifier, or `@scope/deck`
 * with a legal scope half and a legal deck half.
 *
 * The name is **folded first**, so a differently-cased spelling of a legal name
 * is legal, and so is one with ASCII spaces or tabs around it, which `fold`
 * trims. Callers store `fold(name)`, never the name as written.
 *
 * Anything outside ASCII is refused **before** folding, wherever it stands,
 * leading and trailing positions included. `strings.lower` is Unicode-aware, so
 * the Kelvin sign (U+212A) folds to `k` and a name spelled with it would
 * otherwise pass as its ASCII twin: harmless, since it is the same record, but
 * it is input outside the grammar, and the grammar is the contract. The check
 * used to run on the `strings.trim`-med name, and that trim also strips Unicode
 * whitespace, so a name ending in a no-break space passed.
 * @param name {string} the deck name
 * @return {bool} true when the name is well-formed
 */
export func isValid(name as string) {
    for (def ch in strings.chars(trimAscii($name))) {
        if (strings.indexOf(WRITTEN, $ch) < 0) {
            return false;
        }
    }
    def folded as string init fold($name);
    if (isScoped($folded)) {
        return isScopeIdent(scopeOf($folded)) and isIdent(deckOf($folded));
    }
    return isIdent($folded);
}

/**
 * Return the vendor-relative subdirectory a scoped deck installs into:
 * `<scope>/<deck>`, folded, e.g. "jennifer/routeros" - so the on-disk tree is
 * `vendor/jennifer/routeros/`. For a bare name it is just the folded name.
 *
 * Folding here is what keeps a lockfile meaning the same thing on a
 * case-insensitive filesystem as on a case-sensitive one.
 * @param name {string} the deck name
 * @return {string} the vendor-relative subdirectory
 */
export func vendorSubdir(name as string) {
    if (isScoped(fold($name))) {
        return scopeOf($name) + "/" + deckOf($name);
    }
    return deckOf($name);
}

/**
 * Encode a name as one JSON Pointer reference token (RFC 6901: `~` -> `~0`,
 * `/` -> `~1`), so a scoped deck name like `@jennifer/routeros` addresses a
 * single key in a toml / json document rather than a nested path.
 * @param token {string} the raw name
 * @return {string} the pointer-escaped token
 */
export func ptrEscape(token as string) {
    def out as string init strings.replace($token, "~", "~0");
    return strings.replace($out, "/", "~1");
}

/**
 * Return the deck's entrypoint filename: `<deck>.j`, folded - the module the
 * resolver appends for `import "@scope/deck/"`.
 * @param name {string} the deck name
 * @return {string} the entrypoint filename, e.g. "routeros.j"
 */
export func entryFile(name as string) {
    return deckOf($name) + ".j";
}
