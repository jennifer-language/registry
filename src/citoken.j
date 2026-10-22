# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * CI tokens: the non-interactive fallback (specification 8.10).
 *
 * Authorises a write without a browser where trusted publishing (8.9) is
 * unavailable: a laptop, a cron job, CI that mints no identity token. A standing
 * bearer secret is what 8.9 avoids, so these properties limit the damage of a
 * leak:
 *
 * - **Narrower than its owner.** Bound to one scope, or one deck within it.
 * - **Individually revocable**, so a leak costs one pipeline.
 * - **Expiring by default.**
 * - **Stored as a fingerprint**: a leaked database is a list of SHA-256 hashes,
 *   as for refresh tokens.
 *
 * The secret is shown once, at creation, so the store never holds a displayable
 * token.
 *
 * Pure: no store, no clock, no randomness. `now` is a parameter; minting (the
 * random secret, the store write) is `admin.cmdMintToken`, `deckadmin mint-token`.
 * @module citoken
 * @example
 * import "./citoken.j" as citoken;
 * def t as citoken.Token init store.getCiToken($db, token.fingerprint($secret));
 * def v as citoken.Verdict init citoken.check($t, "@acme/tool", $now);
 * # v.allowed, else v.reason names the cause
 */

use strings;
use convert;
import "./deckname.j" as deckname;

# The prefix every CI token carries, so secret scanners can find a leaked one and
# a wrong credential is rejected without a store lookup.
export def const PREFIX as string init "jvcp_";

/**
 * A CI token's record. It holds only the token's SHA-256, so it can be listed
 * and logged without handling a credential.
 * @field fingerprint {string} the SHA-256 of the token, its primary key
 * @field name {string} a label the operator chose, shown in listings
 * @field scope {string} the scope this token may write under
 * @field deck {string} one deck within that scope, or "" for the whole scope
 * @field provider {string} the identity provider of the account that minted it
 *     ("" when an operator minted it, as `deckadmin mint-token` does)
 * @field subject {string} the principal that minted it ("" likewise; a publish
 *     then checks the scope owner's push access, see `publishview.ciPrincipal`)
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
    return Verdict{allowed: false, reason: $reason, fingerprint: ""};
}

/**
 * Whether a string has the shape of a CI token, checked before any store lookup.
 * @param secret {string} the presented token
 * @return {bool} true when it carries the prefix and some body
 */
export func looksLikeToken(secret as string) {
    return strings.startsWith($secret, PREFIX) and len($secret) > len(PREFIX) + 8;
}

/**
 * Whether a token has expired at `now`. An empty `expiresAt` never expires.
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
 * write any deck under it. Both compare folded names, so a token minted for
 * `@Acme/Tool` authorises `@acme/tool`.
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
 * The store lookup is the caller's. Expiry is checked before scope, so an
 * expired token reports its expiry.
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
 * never, which the caller must ask for explicitly.
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
