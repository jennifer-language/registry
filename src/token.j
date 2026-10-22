# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The registry's own credential: minting and verifying the short-lived bearer
 * token a client sends on writes, and generating the opaque refresh token that
 * renews it.
 *
 * The registry issues its own token instead of storing the user's provider
 * token (specification 8.4): a JWT signed with HS256.
 *
 * The subject is the numeric account id, never the login (8.1): a login
 * released by a rename can be re-registered by somebody else. The login is a
 * display label.
 *
 * Pure: no I/O, no store.
 * @module token
 * @example
 * import "./token.j" as token;
 * def t as string init token.mint($key, 1234567, "alice", $orgs, $now, 3600, $now);
 * def who as token.Identity init token.verify($key, $t);
 */

use json;
use time;
use hash;
use crypto;
use encoding;
use convert;
import "jwt.j" as jwt;

# The signing algorithm. `verify` is told the algorithm it expects, which stops
# algorithm confusion.
#
# HS256 is symmetric, which is safe only while this registry is the sole
# verifier. With HMAC, verifying requires the signing key, so any second
# verifier (a CDN edge, a companion service) could mint tokens for any account.
# Adding one means switching to an asymmetric algorithm (`jwt` supports ES256
# over a `crypto.ecGenerateKey` pair) and publishing the public key
# (specification 8.5).
def const ALG as string init "HS256";

# Bytes of crypto-grade entropy in a refresh token (256 bits).
def const REFRESH_BYTES as int init 32;

/**
 * Who a token authenticates.
 * @field accountId {int} the numeric GitHub account id, which ownership binds to
 * @field login {string} the GitHub login, a display label only
 * @field expiresAt {int} when the token stops working (Unix seconds)
 * @field orgs {map of string to string} folded organisation login to provider id,
 *     read at login (8.7)
 * @field orgsCheckedAt {int} when `orgs` was read (Unix seconds); 0 when the
 *     token carries no `orgsAt` claim
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
 *     belongs to, folded login -> id, read at login (8.7)
 * @param checkedAt {int} when that membership was read (Unix seconds). Separate
 *     from `iat` because a refreshed token is newer than its memberships.
 * @param ttl {int} how long the token is valid, in seconds
 * @param now {int} the current time (Unix seconds)
 * @return {string} the compact JWT
 */
export func mint(
    key as bytes,
    accountId as int,
    login as string,
    orgs as map of string to string,
    checkedAt as int,
    ttl as int,
    now as int) {
    def claims as json.Value init json.map();
    # `sub` is the account id as text, since a JWT subject is a string.
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
 * signature, a token signed with a different algorithm, an expired one, and one
 * with no `exp` (which `jwt.verify` alone would accept for ever).
 * @param key {bytes} the HMAC signing secret
 * @param token {string} the compact JWT
 * @return {Identity} the authenticated identity
 * @throws {Error} when the token is malformed, forged, or expired
 */
export func verify(key as bytes, token as string) {
    def claims as json.Value init jwt.verifyWith(
        $token,
        $key,
        ALG,
        jwt.Policy{iss: "", aud: "", requireExp: true});
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
 * carries no claims; it is a lookup key into the store, so one use can revoke it.
 * @return {string} the refresh token
 */
export func newRefresh() {
    return encoding.toText(crypto.randBytes(REFRESH_BYTES), "hex");
}

/**
 * The fingerprint a refresh token is stored under: its SHA-256, as hex.
 *
 * The token itself is never stored, so a leaked database holds hashes rather
 * than live credentials.
 * @param token {string} the refresh token
 * @return {string} its fingerprint
 */
export func fingerprint(token as string) {
    def raw as bytes init convert.bytesFromString($token, "utf-8");
    return encoding.toText(hash.compute($raw, "sha256"), "hex");
}

/**
 * The current time as Unix seconds. The only clock read in this module.
 * @return {int} the current time (Unix seconds)
 */
export func now() {
    return time.unix(time.utc());
}
