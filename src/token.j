# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The registry's own credential: minting and verifying the short-lived bearer
 * token a client sends on writes, and generating the opaque refresh token that
 * buys a new one.
 *
 * The registry issues **its own** token rather than storing the user's GitHub
 * token (specification 8.4). The token is a JWT signed with HS256, which needs
 * only a shared secret and runs on both interpreter binaries; the registry is
 * both issuer and verifier, so there is no public key to distribute and nothing
 * an asymmetric algorithm would buy.
 *
 * **The subject is the numeric GitHub account id, never the login** (8.1). A
 * login released by a rename can be re-registered by somebody else, so binding
 * to one would hand an attacker an established scope. The login rides along as
 * a display label and is refreshed on each login.
 *
 * Pure: no I/O, no store, so every branch is testable.
 * @module identity
 * @example
 * import "./token.j" as token;
 * def t as string init token.mint($key, 1234567, "alice", 3600, $now);
 * def who as token.Identity init token.verify($key, $t);
 */

use json;
use time;
use hash;
use crypto;
use encoding;
use convert;
import "jwt.j" as jwt;

# The signing algorithm. HS256 is symmetric, which is right here: the registry
# signs and verifies its own tokens, so there is no third party to hand a public
# key to. `verify` is told the algorithm it expects, which is what closes the
# algorithm-confusion attack.
# The signing algorithm. Symmetric, and that is a decision with a condition
# attached rather than a default.
#
# It holds because **this registry is the only thing that verifies these tokens**:
# clients present them and never inspect them, and nothing else is handed the
# key. One key, no distribution, no public half to publish or rotate.
#
# It stops holding the moment anything else needs to verify - a CDN edge
# authorising at the boundary, a companion service, a second implementation.
# With HMAC the ability to verify *is* the ability to sign, so giving a verifier
# the key gives it the power to mint a token for any account. At that point this
# must become asymmetric (`jwt` supports ES256 over a `crypto.ecGenerateKey`
# pair) and the public half must be published. Specification 8.5 states the rule;
# this comment exists so the person adding the second verifier meets it here too.
def const ALG as string init "HS256";

# How many bytes of entropy a refresh token carries. 32 bytes is 256 bits from
# the crypto-grade source, well past guessing.
def const REFRESH_BYTES as int init 32;

/**
 * Who a token authenticates.
 * @field accountId {int} the numeric GitHub account id, the identity that matters
 * @field login {string} the GitHub login, a display label only
 * @field expiresAt {int} when the token stops working (Unix seconds)
 */
export def struct Identity {
    accountId as int,
    login as string,
    expiresAt as int,
    orgs as map of string to string,
    orgsCheckedAt as int
};

/**
 * Mint a signed bearer token for an account.
 * @param key {bytes} the HMAC signing secret
 * @param accountId {int} the numeric GitHub account id
 * @param login {string} the GitHub login, carried as a display label
 * @param orgs {map of string to string} the organisations the account actively
 *     belongs to, folded login -> id, read at login (8.7). Carried in the
 *     token because the provider token
 *     is discarded immediately after, so this is the only chance to ask.
 * @param checkedAt {int} when that membership was read (Unix seconds). Recorded
 *     separately from `iat` because a refreshed token is newer than the
 *     membership it carries, and an org-scope write needs to know which.
 * @param ttl {int} how long the token is valid, in seconds
 * @param now {int} the current time (Unix seconds), passed in so this stays pure
 * @return {string} the compact JWT
 */
export func mint(key as bytes, accountId as int, login as string,
        orgs as map of string to string, checkedAt as int, ttl as int,
        now as int) {
    def claims as json.Value init json.map();
    # `sub` is the account id as text: a JWT subject is a string, and the id is
    # what ownership binds to.
    $claims = json.set($claims, "/sub", convert.toString($accountId));
    $claims = json.set($claims, "/login", $login);
    $claims = json.set($claims, "/iat", $now);
    $claims = json.set($claims, "/exp", $now + $ttl);
    def ids as json.Value init json.map();
    for (def name in $orgs) {
        $ids = json.set($ids, "/" + $name, $orgs[$name]);
    }
    $claims = json.set($claims, "/orgs", $ids);
    $claims = json.set($claims, "/orgsAt", $checkedAt);
    return jwt.sign($claims, $key, ALG);
}

/**
 * Verify a bearer token and return who it authenticates. Rejects a bad
 * signature, a token signed with a different algorithm, and an expired one:
 * `jwt.verify` enforces `exp` itself.
 * @param key {bytes} the HMAC signing secret
 * @param token {string} the compact JWT
 * @return {Identity} the authenticated identity
 * @throws {Error} when the token is malformed, forged, or expired
 */
export func verify(key as bytes, token as string) {
    def claims as json.Value init jwt.verify($token, $key, ALG);
    def orgs as map of string to string init {};
    if (json.has($claims, "/orgs")) {
        for (def name in json.keys($claims, "/orgs")) {
            $orgs[$name] = json.asString($claims, "/orgs/" + $name);
        }
    }
    def checkedAt as int init 0;
    if (json.has($claims, "/orgsAt")) {
        $checkedAt = json.asInt($claims, "/orgsAt");
    }
    return Identity{
        accountId: convert.toInt(json.asString($claims, "/sub")),
        login: json.asString($claims, "/login"),
        expiresAt: json.asInt($claims, "/exp"),
        orgs: $orgs,
        orgsCheckedAt: $checkedAt
    };
}

/**
 * Generate an opaque refresh token: 32 crypto-grade random bytes as hex. It
 * carries no claims and means nothing on its own; it is a lookup key into the
 * store, which is what lets a single use revoke it.
 * @return {string} the refresh token
 */
export func newRefresh() {
    return encoding.toText(crypto.randBytes(REFRESH_BYTES), "hex");
}

/**
 * The fingerprint a refresh token is stored under: its SHA-256, as hex.
 *
 * **The token itself is never written down.** A stolen database is then a list
 * of hashes rather than a set of live credentials, exactly as a password table
 * should be. Lookup still works because the client presents the token and the
 * registry hashes it again.
 * @param token {string} the refresh token
 * @return {string} its fingerprint
 */
export func fingerprint(token as string) {
    def raw as bytes init convert.bytesFromString($token, "utf-8");
    return encoding.toText(hash.compute($raw, "sha256"), "hex");
}

/**
 * The current time as Unix seconds, for a caller that has no better clock.
 * Every other function here takes `now` as an argument so it stays testable;
 * this is the one place that reads the clock.
 * @return {int} the current time (Unix seconds)
 */
export func now() {
    return time.unix(time.utc());
}
