# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Deck keywords: the grammar, the cap, and the terms this registry refuses.
 *
 * Keywords are publisher input that becomes navigation: each one creates a
 * shared page listing every deck that carries it. Hence the strictness. Rules,
 * in the order applied:
 *
 * - **Grammar.** Lowercase letters, digits and single inner hyphens, 2 to 32
 *   characters: a URL segment without escaping, and few spellings per tag.
 * - **Blocklist**, below.
 * - **Cap of `LIMIT`.** Excess keywords are dropped, not the manifest rejected,
 *   so one deck cannot flood the tag namespace.
 *
 * The blocklist runs before the cap (tested), so padding with refused terms
 * cannot push a legitimate keyword out of the first five.
 * @module keywords
 * @example
 * import "./keywords.j" as keywords;
 * def tags as list of string init keywords.normalise(["CLI", "cli", "spinner"]);
 * # -> ["cli", "spinner"]
 */

use strings;
use lists;
use encoding;
use convert;

/**
 * How many keywords a deck may use. Later ones, in the publisher's order, are
 * dropped.
 */
export def const LIMIT as int init 5;

/** The shortest and longest a keyword may be. */
export def const MIN_LENGTH as int init 2;
export def const MAX_LENGTH as int init 32;

/**
 * Terms this registry will not index, and why.
 *
 * The terms are base64 so that the list of pornographic and child-abuse
 * vocabulary is not plain text in a public repository, where crawlers and
 * classifiers would categorise the registry as what it refuses. It is encoding,
 * not encryption: a human can audit it, a crawler does not read it in passing.
 *
 * A word list does not stop a determined author, who can misspell. It ensures
 * the registry never builds a tag page, tag cloud entry or browsable category
 * for these terms.
 *
 * Groups:
 *
 * - **`abuse()`**: material involving children. Not configurable; never relax
 *   it. Such a deck loses the keyword; whether the deck stays is an operator
 *   and legal decision (`deckadmin yank`).
 * - **`adult()`**: sexual content, kept out of the shared tag namespace.
 * - **`slur()`**: hate speech aimed at people.
 *
 * Matching is exact on the normalised keyword, plus a substring pass for the
 * `abuse` group only, where a near miss matters more than a false positive.
 * @return {list of string} every refused term, decoded
 */
export func blocked() {
    return lists.concat(lists.concat(abuse(), adult()), slur());
}

# decodeAll turns the stored base64 back into terms to match against. It runs
# on every call because a module top level cannot hold computed state; the
# lists are a few dozen short strings.
func decodeAll(encoded as list of string) {
    def out as list of string init [];
    for (def one in $encoded) {
        $out[] = convert.stringFromBytes(encoding.fromText($one, "base64"), "utf-8");
    }
    return $out;
}

/**
 * Terms relating to the sexual abuse of children. Never relax this list.
 * @return {list of string} the terms, decoded
 */
export func abuse() {
    return decodeAll([
        "Y3NhbQ==",
        "Y3NlbQ==",
        "Y2hpbGRwb3Ju",
        "Y2hpbGRwb3Jub2dyYXBoeQ==",
        "Y3A=",
        "cGVkbw==",
        "cGVkb3BoaWxl",
        "cGFlZG8=",
        "cGFlZG9waGlsZQ==",
        "cGVkb3BoaWxpYQ==",
        "cGFlZG9waGlsaWE=",
        "bG9saWNvbg==",
        "c2hvdGFjb24=",
        "amFpbGJhaXQ=",
        "cHJldGVlbg==",
        "dW5kZXJhZ2U=",
        "bWlub3Jwb3Ju"
    ]);
}

/**
 * Sexual content, refused as a category in the registry's navigation.
 * @return {list of string} the terms, decoded
 */
export func adult() {
    return decodeAll([
        "cG9ybg==",
        "cG9ybm8=",
        "cG9ybm9ncmFwaHk=",
        "eHh4",
        "bnNmdw==",
        "aGVudGFp",
        "ZXJvdGljYQ==",
        "ZXJvdGlj",
        "Y2FtZ2lybA==",
        "ZXNjb3J0",
        "ZmV0aXNo",
        "YmRzbQ==",
        "b25seWZhbnM=",
        "c2V4",
        "c2V4eQ==",
        "bnVkZQ==",
        "bnVkZXM=",
        "bnVkaXR5",
        "YWR1bHRjb250ZW50"
    ]);
}

/**
 * Hate speech aimed at people. Short and unambiguous: it refuses the obvious
 * and does not adjudicate language.
 * @return {list of string} the terms, decoded
 */
export func slur() {
    return decodeAll(["bmF6aQ==", "aGl0bGVy", "d2hpdGVwb3dlcg==", "Z2Vub2NpZGU=", "bHluY2g="]);
}

/**
 * The substrings that refuse a keyword even inside a longer word.
 *
 * Child-abuse group only. Substring matching gives false positives (a
 * three-letter adult term would refuse `sexagesimal`); here a false positive
 * costs one keyword, a false negative a category page.
 *
 * The two-letter abbreviation in `abuse()` is not here: as a substring it would
 * refuse `cpp`, `cpu` and `cpanel`. It stays exact-match.
 * @return {list of string} the substrings, decoded
 */
export func blockedSubstrings() {
    return decodeAll([
        "Y3NhbQ==",
        "Y2hpbGRwb3Ju",
        "cGVkb3BoaWw=",
        "cGFlZG9waGls",
        "bG9saWNvbg==",
        "c2hvdGFjb24=",
        "amFpbGJhaXQ=",
        "bWlub3Jwb3Ju"
    ]);
}

/**
 * Encode a term for the lists above; the inverse of `decodeAll`. Defined here,
 * beside the decoder, so writing and reading cannot drift apart into a list
 * that matches nothing.
 * @param word {string} the plain term
 * @return {string} its base64 form, ready to paste into a group above
 */
export func encode(word as string) {
    return encoding.toText(convert.bytesFromString($word, "utf-8"), "base64");
}

/**
 * Report whether a folded keyword is well formed: lowercase letters, digits
 * and hyphens, starting and ending with a letter or digit, no doubled hyphen.
 * Safe unescaped as the `/tag/<keyword>` path segment.
 * @param word {string} the folded candidate
 * @return {bool} true when it matches the grammar
 */
export func isWellFormed(word as string) {
    if (len($word) < MIN_LENGTH or len($word) > MAX_LENGTH) {
        return false;
    }
    def previousWasHyphen as bool init false;
    def i as int init 0;
    while ($i < len($word)) {
        def ch as string init strings.substring($word, $i, $i + 1);
        def isHyphen as bool init $ch == "-";
        if (not ($isHyphen or isAlnum($ch))) {
            return false;
        }
        if ($isHyphen) {
            # no leading, trailing, or doubled hyphen
            if ($i == 0 or $i == len($word) - 1 or $previousWasHyphen) {
                return false;
            }
        }
        $previousWasHyphen = $isHyphen;
        $i = $i + 1;
    }
    return true;
}

# isAlnum reports whether a single character is a lowercase letter or a digit.
func isAlnum(ch as string) {
    return ($ch >= "a" and $ch <= "z") or ($ch >= "0" and $ch <= "9");
}

/**
 * Report whether a folded keyword is refused.
 * @param word {string} the folded candidate
 * @return {bool} true when the registry will not index it
 */
export func isBlocked(word as string) {
    if (lists.contains(blocked(), $word)) {
        return true;
    }
    for (def part in blockedSubstrings()) {
        if (strings.contains($word, $part)) {
            return true;
        }
    }
    return false;
}

/**
 * Fold a keyword to its canonical form: trimmed and lowercased. Applied before
 * every other check, so `CLI` and `cli` are one tag and casing cannot evade the
 * blocklist.
 * @param word {string} the raw keyword
 * @return {string} the folded form
 */
export func fold(word as string) {
    def trimmed as string init strings.trim($word);
    # Only ASCII is lowered: `strings.lower` maps the Kelvin sign (U+212A) to `k`
    # and the dotted capital I to `i`, folding into another valid name. Left as
    # written, it fails the grammar.
    if (not encoding.isAscii(convert.bytesFromString($trimmed, "utf-8"))) {
        return $trimmed;
    }
    return strings.lower($trimmed);
}

/**
 * Turn a manifest's raw keyword list into the ones this registry indexes:
 * folded, malformed, blocked and duplicate ones dropped, at most `LIMIT`. Never
 * throws; a bad keyword costs that keyword, not the release.
 * @param raw {list of string} the keywords as written in deck.toml
 * @return {list of string} the accepted keywords, in the publisher's order
 */
export func normalise(raw as list of string) {
    def out as list of string init [];
    for (def word in $raw) {
        if (len($out) >= LIMIT) {
            return $out;
        }
        def folded as string init fold($word);
        if (not isWellFormed($folded)) {
            continue;
        }
        if (isBlocked($folded)) {
            continue;
        }
        if (lists.contains($out, $folded)) {
            continue;
        }
        $out[] = $folded;
    }
    return $out;
}
