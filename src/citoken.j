# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * CI tokens: the non-interactive fallback (specification 8.10).
 *
 * Where trusted publishing (8.9) is unavailable - a laptop, a cron job, a CI
 * system that mints no identity token - something has to authorise a write
 * without a browser. This is that something, and it is deliberately the *second*
 * choice: a standing bearer secret in a pipeline config is exactly what 8.9
 * exists to avoid, so everything here is shaped around limiting the damage when
 * one leaks rather than around convenience.
 *
 * Four properties do that work, and none is optional:
 *
 * - **Scoped narrower than its owner.** A token is bound to one scope, or to one
 *   deck within it. A token that could write everything its minting user can is
 *   not a CI token, it is a copy of the user.
 * - **Individually revocable**, without disturbing the others, so a suspected
 *   leak costs one pipeline rather than every pipeline.
 * - **Expiring by default.** A token nobody remembers is the one that leaks.
 * - **Stored as a fingerprint**, never as the token. A leaked database is a list
 *   of SHA-256 hashes, which is the same decision refresh tokens already take.
 *
 * The secret is shown **once**, at creation, because a store that can display a
 * token again is a store that can lose every token at once.
 *
 * Pure except for the store: `now` is a parameter, and the random half is the
 * caller's. That is what makes expiry and scope matching testable at a fixed
 * instant instead of against a clock.
 * @module citoken
 * @example
 * import "./citoken.j" as citoken;
 * def t as citoken.Minted init citoken.mint($db, "acme", "", "release", $now, 7776000);
 * # show t.secret once, then store.save(t.db)
 */

use strings;
use convert;
import "flatdb.j" as flatdb;
import "./deckname.j" as deckname;

# The prefix every CI token carries. A recognisable prefix is what lets a secret
# scanner spot one in a public repository, and lets this registry reject an
# obviously-wrong credential without a store lookup.
export def const PREFIX as string init "jvcp_";

/**
 * A CI token's record. **The token itself is not here** - only its SHA-256 - so
 * this struct can be read, listed, and logged without handling a credential.
 * @field fingerprint {string} the SHA-256 of the token, its primary key
 * @field name {string} a label the operator chose, shown in listings
 * @field scope {string} the scope this token may write under
 * @field deck {string} one deck within that scope, or "" for the whole scope
 * @field provider {string} the identity provider of the account that minted it
 * @field subject {string} the principal that minted it
 * @field createdAt {string} when it was minted (Unix seconds as text)
 * @field expiresAt {string} when it stops working ("" means never)
 * @field lastUsedAt {string} when it last authorised a write ("" means never)
 */
export def struct Token {
    fingerprint as string,
    name as string,
    scope as string,
    deck as string,
    provider as string,
    subject as string,
    createdAt as string,
    expiresAt as string,
    lastUsedAt as string
};

/**
 * A freshly minted token: the record, the store to persist, and **the one and
 * only time the secret exists in readable form**.
 * @field ok {bool} whether it was minted
 * @field error {string} why not
 * @field secret {string} the token to show the operator, once
 * @field record {Token} what was stored
 * @field db {flatdb.DB} the resulting store
 */
export def struct Minted {
    ok as bool,
    error as string,
    secret as string,
    record as Token,
    db as flatdb.DB
};

/**
 * The outcome of presenting a token.
 * @field allowed {bool} whether the write is authorised
 * @field reason {string} why, phrased for a build log
 * @field fingerprint {string} the matched token's fingerprint ("" when none)
 */
export def struct Verdict {
    allowed as bool,
    reason as string,
    fingerprint as string
};

func no(reason as string) {
    return Verdict{ allowed: false, reason: $reason, fingerprint: "" };
}

/**
 * Does a string look like a CI token? A cheap shape check, so an obviously-wrong
 * credential is refused without touching the store.
 * @param secret {string} the presented token
 * @return {bool} true when it carries the prefix and some body
 */
export func looksLikeToken(secret as string) {
    return strings.startsWith($secret, PREFIX) and len($secret) > len(PREFIX) + 8;
}

/**
 * Whether a token has expired at `now`. An empty `expiresAt` never expires,
 * which a deployment should treat as a thing to avoid rather than a default.
 * @param t {Token} the token record
 * @param now {int} the current time (Unix seconds)
 * @return {bool} true when it has expired
 */
export func isExpired(t as Token, now as int) {
    if (strings.trim($t.expiresAt) == "") {
        return false;
    }
    return convert.toInt($t.expiresAt) <= $now;
}

/**
 * May this token write to this deck?
 *
 * A token bound to a deck may write only that deck; a token bound to a scope may
 * write any deck under it. Both are checked against the **folded** name, so a
 * token minted for `@Acme/Tool` authorises `@acme/tool` and nothing else.
 *
 * Pure, and separate from the store lookup, so the matching rule has tests of
 * its own rather than being reachable only through a database.
 * @param t {Token} the token record
 * @param deck {string} the deck being written
 * @return {bool} true when the token covers it
 */
export func covers(t as Token, deck as string) {
    def target as string init deckname.fold($deck);
    if (not ($t.deck == "")) {
        return deckname.fold($t.deck) == $target;
    }
    if ($t.scope == "") {
        return false;
    }
    return deckname.fold($t.scope) == deckname.scopeOf($target);
}

/**
 * Decide whether a presented token authorises a write, given its record.
 *
 * The store lookup is the caller's; this is everything after it, so the order of
 * the checks is testable. Expiry is checked before scope: a token that expired
 * should say so, rather than complaining about a deck it would never have been
 * allowed to write anyway.
 * @param t {Token} the record found for the presented token
 * @param deck {string} the deck being written
 * @param now {int} the current time (Unix seconds)
 * @return {Verdict} allow, or refuse naming the cause
 */
export func check(t as Token, deck as string, now as int) {
    if ($t.fingerprint == "") {
        return no("no such token");
    }
    if (isExpired($t, $now)) {
        return no("this token expired on " + $t.expiresAt);
    }
    if (not covers($t, $deck)) {
        def where as string init "@" + $t.scope;
        if (not ($t.deck == "")) {
            $where = $t.deck;
        }
        return no("this token may only write " + $where);
    }
    return Verdict{
        allowed: true,
        reason: "authorised by CI token " + $t.name,
        fingerprint: $t.fingerprint
    };
}

/**
 * The expiry timestamp for a token minted at `now`, as text. A `ttl` of 0 means
 * never, which the caller should have to ask for explicitly.
 * @param now {int} the minting time (Unix seconds)
 * @param ttl {int} how long it lives, in seconds (0 = never)
 * @return {string} the expiry as text, or "" for never
 */
export func expiryOf(now as int, ttl as int) {
    if ($ttl <= 0) {
        return "";
    }
    return convert.toString($now + $ttl);
}
