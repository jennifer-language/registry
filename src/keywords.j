# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Deck keywords: the grammar, the cap, and the terms this registry refuses.
 *
 * Keywords exist so decks can be grouped and browsed. They are **publisher
 * input that becomes navigation**, which is the whole reason this module is
 * strict: a keyword is not just displayed on one deck's page, it creates a
 * shared page that every deck carrying it appears on. An unfiltered keyword
 * field is therefore a way to put arbitrary text into the registry's own
 * navigation, and to sit a deck next to whatever the author chose to associate
 * it with.
 *
 * Three rules, in the order they are applied:
 *
 * - **A grammar.** Lowercase letters, digits, and single inner hyphens, 2 to 32
 *   characters. That is narrow enough to be a URL segment without escaping and
 *   to make two spellings of one tag rare.
 * - **A blocklist**, below.
 * - **A cap of `LIMIT`.** Keywords past it are dropped rather than the manifest
 *   being rejected: a publisher listing fifteen tags is optimistic, not
 *   malicious, and failing their release over it helps nobody. Dropping keeps
 *   the tag namespace from being flooded by one deck claiming everything.
 *
 * Order matters and is tested: the blocklist runs **before** the cap, so a deck
 * cannot push a legitimate keyword out of its own first five by padding the
 * list with refused ones.
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
 * How many keywords a deck may actually use. Everything after this is dropped,
 * in the order the publisher wrote them, so the first five are the ones that
 * count and a publisher who cares can choose which.
 */
export def const LIMIT as int init 5;

/** The shortest and longest a keyword may be. */
export def const MIN_LENGTH as int init 2;
export def const MAX_LENGTH as int init 32;

/**
 * Terms this registry will not index, and why.
 *
 * **The terms are base64, and that is deliberate.** In plain text this list
 * would be a page of pornographic and child-abuse vocabulary sitting in a public
 * repository, on a docs site, and in every mirror and code-search index that
 * crawls them. Classifiers do not read the surrounding function name: a
 * moderation blocklist and the material it blocks look identical to a crawler
 * counting keywords, so publishing one in the clear is a reliable way to have
 * the registry itself categorised as what it is refusing, or reported for it.
 * Encoding costs one decode per lookup and removes the whole class of problem.
 *
 * It is **encoding, not encryption**, and it is not trying to be. Anyone reading
 * this file can decode it in a second, which is correct: the list should be
 * auditable by a human. What it must not be is machine-readable in passing.
 *
 * **This is a refusal to host navigation for that material, not a claim to have
 * solved moderation.** A word list catches the deliberate and the careless; it
 * does not catch a determined author, who can always misspell. What it does buy
 * is that the registry never *builds a page* grouping decks under these terms,
 * never puts them in a tag cloud on its own front door, and never turns them
 * into a browsable category. That is this project's responsibility, and it is
 * worth doing even though it is not complete.
 *
 * Grouped by why, because the reasons differ and a future reader needs to know
 * which line they are changing:
 *
 * - **`abuse()`** is material involving children. Not a matter of taste, not
 *   configurable, and the one group that should never be relaxed by a
 *   deployment. A deck carrying one of these is refused its keyword; whether the
 *   deck itself belongs here is an operator judgement (`deckadmin yank`) and a
 *   legal one, and both are outside what a word list can decide.
 * - **`adult()`** is sexual content. Refused because this is a package registry
 *   for a programming language and the tag namespace is shared: nobody browsing
 *   for a `parser` should land in that neighbourhood.
 * - **`slur()`** is hate speech aimed at people.
 *
 * Matching is on the **normalised** keyword and is exact, plus a substring pass
 * for the `abuse` group only, since that is the group where a near miss matters
 * more than a false positive.
 * @return {list of string} every refused term, decoded
 */
export func blocked() {
    return lists.concat(lists.concat(abuse(), adult()), slur());
}

# decodeAll turns the stored base64 back into terms to match against.
#
# Decoded on each call rather than once into a constant, because a module top
# level is declarations-only and cannot hold computed state. The lists are a few
# dozen short strings and the call sites are a publish and a page render, so the
# cost is not worth a cache that would have to live somewhere awkward.
func decodeAll(encoded as list of string) {
    def out as list of string init [];
    for (def one in $encoded) {
        $out[] = convert.stringFromBytes(encoding.fromText($one, "base64"),
            "utf-8");
    }
    return $out;
}

/**
 * Terms relating to the sexual abuse of children. Never relax this list.
 * @return {list of string} the terms, decoded
 */
export func abuse() {
    return decodeAll([
        "Y3NhbQ==", "Y3NlbQ==", "Y2hpbGRwb3Ju", "Y2hpbGRwb3Jub2dyYXBoeQ==", "Y3A=",
        "cGVkbw==", "cGVkb3BoaWxl", "cGFlZG8=", "cGFlZG9waGlsZQ==",
        "cGVkb3BoaWxpYQ==", "cGFlZG9waGlsaWE=", "bG9saWNvbg==", "c2hvdGFjb24=",
        "amFpbGJhaXQ=", "cHJldGVlbg==", "dW5kZXJhZ2U=", "bWlub3Jwb3Ju"
    ]);
}

/**
 * Sexual content. Refused as a *category* in this registry's navigation.
 * @return {list of string} the terms, decoded
 */
export func adult() {
    return decodeAll([
        "cG9ybg==", "cG9ybm8=", "cG9ybm9ncmFwaHk=", "eHh4", "bnNmdw==",
        "aGVudGFp", "ZXJvdGljYQ==", "ZXJvdGlj", "Y2FtZ2lybA==", "ZXNjb3J0",
        "ZmV0aXNo", "YmRzbQ==", "b25seWZhbnM=", "c2V4", "c2V4eQ==", "bnVkZQ==",
        "bnVkZXM=", "bnVkaXR5", "YWR1bHRjb250ZW50"
    ]);
}

/**
 * Hate speech aimed at people. Deliberately short and unambiguous: this list
 * exists to refuse the obvious, not to adjudicate language.
 * @return {list of string} the terms, decoded
 */
export func slur() {
    return decodeAll([
        "bmF6aQ==", "aGl0bGVy", "d2hpdGVwb3dlcg==", "Z2Vub2NpZGU=", "bHluY2g="
    ]);
}

/**
 * The substrings that refuse a keyword even inside a longer word.
 *
 * Only the child-abuse group gets this treatment. A substring rule is blunt and
 * produces false positives - which is exactly why it is not applied to the other
 * groups, where a three-letter term would refuse `sexagesimal` - and for this
 * group a false positive costs a publisher one keyword while a false negative
 * costs the registry a category page it should never have built.
 *
 * The two-letter abbreviation in `abuse()` is deliberately **not** here: as a
 * substring it would refuse `cpp`, `cpu`, and `cpanel`. It stays exact-match.
 * @return {list of string} the substrings, decoded
 */
export func blockedSubstrings() {
    return decodeAll([
        "Y3NhbQ==", "Y2hpbGRwb3Ju", "cGVkb3BoaWw=", "cGFlZG9waGls",
        "bG9saWNvbg==", "c2hvdGFjb24=", "amFpbGJhaXQ=", "bWlub3Jwb3Ju"
    ]);
}

/**
 * Encode a term for the lists above.
 *
 * The inverse of what `decodeAll` does, exposed because the list is maintained
 * by hand and an operator adding a term needs its encoded form. Kept here rather
 * than in the CLI so the encoding is defined in exactly one place: a mismatch
 * between how terms are written and how they are read would silently produce a
 * list that matches nothing.
 * @param word {string} the plain term
 * @return {string} its base64 form, ready to paste into a group above
 */
export func encode(word as string) {
    return encoding.toText(convert.bytesFromString($word, "utf-8"), "base64");
}

/**
 * Is this a well-formed keyword? Checked on the already-folded form.
 *
 * The grammar is lowercase letters, digits, and hyphens, starting and ending
 * with a letter or digit, with no doubled hyphen. That makes a keyword safe as a
 * URL path segment with no escaping, which is what `/tag/<keyword>` needs.
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
 * Is this keyword refused? Checked on the already-folded form.
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
 * Fold a keyword to its canonical form: trimmed and lowercased.
 *
 * Folding before every other check is what makes `CLI` and `cli` one tag rather
 * than two pages, and it is also what stops the blocklist being sidestepped by
 * capitalisation.
 * @param word {string} the raw keyword
 * @return {string} the folded form
 */
export func fold(word as string) {
    return strings.lower(strings.trim($word));
}

/**
 * Turn a manifest's raw keyword list into the ones this registry will index.
 *
 * Folds, drops anything malformed or blocked, removes duplicates, and keeps at
 * most `LIMIT`. Never throws: a bad keyword costs a publisher that keyword, not
 * their release.
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
