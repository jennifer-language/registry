# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * The token-exchange endpoints (specification 8.3), as pure data. Same shape as
 * `apiview` one layer along: each function maps a request to an `AuthReply` - a
 * `Reply` plus the store it wants persisted - with no dependency on the web
 * engine, so `bin/serve` stays a handler that reads a body and sends a reply.
 *
 * Only two lines here touch the network, both in `token`: the poll to GitHub and
 * the account read. Everything else - parsing, the status mapping, minting,
 * rotating, refreshing - is a pure function of its arguments and the store, and
 * is covered by the overlay.
 *
 * `now` is a parameter everywhere rather than a clock read, so a test can place
 * a token either side of its expiry.
 * @module authview
 * @example
 * import "./authview.j" as authview;
 * def out as authview.AuthReply init authview.refresh($cfg, $db, $body, $now);
 * # if (out.changed) { store.save(out.db); }
 */

use json;
use strings;
use convert;
use maps;
use lists;
import "flatdb.j" as flatdb;
import "./store.j" as store;
import "./token.j" as token;
import "./identity.j" as identity;

/**
 * What the registry needs in order to issue tokens at all. An empty client id or
 * signing key disables the whole surface: the routes are not served and the
 * discovery document advertises no `auth` object, which is what tells a client
 * this registry accepts no logins.
 *
 * **The provider arrives as a struct of `func` values, not as a name.** This
 * module never learns which identity provider it is talking to, so adding one is
 * a new module under `identity/` and a line in the entry program, with nothing
 * to change here (specification 12.2).
 * @field provider {identity.Provider} the identity provider's vtable
 * @field providerConfig {identity.Config} where that provider lives and its OAuth app
 * @field signingKey {bytes} the HMAC secret the bearer token is signed with
 * @field tokenTtl {int} how long a bearer token lives, in seconds
 * @field refreshTtl {int} how long a refresh token lives, in seconds
 */
export def struct Config {
    provider as identity.Provider,
    providerConfig as identity.Config,
    signingKey as bytes,
    tokenTtl as int,
    refreshTtl as int
};

/**
 * A reply plus the store it wants persisted. Issuing a token records a refresh
 * token, and refreshing rotates one, so these endpoints write; the caller saves
 * when `changed` is set.
 * @field status {int} the HTTP status code
 * @field body {json.Value} the JSON response body
 * @field db {flatdb.DB} the resulting store
 * @field changed {bool} true when the store was edited and should be saved
 */
export def struct AuthReply {
    status as int,
    body as json.Value,
    db as flatdb.DB,
    changed as bool
};

# fail builds an error reply that leaves the store untouched.
func fail(db as flatdb.DB, status as int, message as string) {
    def body as json.Value init json.map();
    $body = json.set($body, "/error", $message);
    return AuthReply{ status: $status, body: $body, db: $db, changed: false };
}

# pending builds the 202 a client polls against.
func pending(db as flatdb.DB) {
    def body as json.Value init json.map();
    $body = json.set($body, "/status", "pending");
    return AuthReply{ status: 202, body: $body, db: $db, changed: false };
}

/**
 * Report whether a configuration can issue tokens. Both halves are required:
 * without a client id there is no OAuth application to run the flow against,
 * and without a signing key nothing could be verified afterwards.
 * @param cfg {Config} the configuration to test
 * @return {bool} true when the auth surface should be served
 */
export func enabled(cfg as Config) {
    return not ($cfg.providerConfig.clientId == "") and len($cfg.signingKey) > 0;
}

/**
 * Read a required string field from a request body. A malformed body and a
 * missing field are the same answer to a client - the request was not usable -
 * so both yield "".
 * @param body {string} the raw request body
 * @param field {string} the field name
 * @return {string} the value, or "" when absent or unparseable
 */
export func bodyField(body as string, field as string) {
    try {
        def doc as json.Value init json.decode($body);
        if (not json.has($doc, "/" + $field)) {
            return "";
        }
        return json.asString($doc, "/" + $field);
    } catch (err) {
        return "";
    }
}

/**
 * Map a poll state onto the reply a client polls against. The outcome rides on
 * the **status code** so a client can branch without reading prose.
 * @param db {flatdb.DB} the store, returned untouched
 * @param state {string} a `github.Poll` state other than "ok"
 * @return {AuthReply} the reply for that state
 */
export func stateReply(db as flatdb.DB, state as string) {
    match ($state) {
        when "pending" {
            return pending($db);
        }
        when "slowDown" {
            return fail($db, 429, "polling too fast; wait for the interval and retry");
        }
        when "denied" {
            return fail($db, 403, "the request was denied by the identity provider");
        }
        when "expired" {
            return fail($db, 410, "this device code expired; start the login again");
        }
    }
    return fail($db, 403, "the login could not be completed");
}

/**
 * Issue a bearer token and a refresh token for an account, recording the
 * refresh token by fingerprint and dropping any that have expired.
 *
 * This is where a login and a refresh converge, so both produce exactly the same
 * response shape and neither can drift.
 * @param cfg {Config} the issuing configuration
 * @param db {flatdb.DB} the store to record the refresh token in
 * @param accountId {int} the numeric GitHub account id
 * @param login {string} the GitHub login, carried as a display label
 * @param orgs {map of string to string} the organisations read at login (8.7)
 * @param checkedAt {int} when those memberships were read (Unix seconds). Carried
 *     separately so a refresh can reissue them without pretending they are fresh.
 * @param now {int} the current time (Unix seconds)
 * @return {AuthReply} a 200 carrying the token pair, and the store to persist
 */
export func issue(cfg as Config, db as flatdb.DB, accountId as int, login as string,
        orgs as map of string to string, checkedAt as int, now as int) {
    def bearer as string init token.mint($cfg.signingKey, $accountId, $login,
        $orgs, $checkedAt, $cfg.tokenTtl, $now);
    def refreshToken as string init token.newRefresh();
    def out as flatdb.DB init store.purgeExpiredRefresh($db, $now);
    $out = store.putRefresh($out, token.fingerprint($refreshToken), store.Refresh{
        accountId: $accountId,
        login: $login,
        expiresAt: $now + $cfg.refreshTtl,
        orgs: $orgs,
        orgsCheckedAt: $checkedAt
    });
    def body as json.Value init json.map();
    $body = json.set($body, "/token", $bearer);
    $body = json.set($body, "/expiresIn", $cfg.tokenTtl);
    $body = json.set($body, "/refreshToken", $refreshToken);
    $body = json.set($body, "/login", $login);
    $body = json.set($body, "/accountId", $accountId);
    $body = json.set($body, "/orgs", orgNames($orgs));
    return AuthReply{ status: 200, body: $body, db: $out, changed: true };
}

/**
 * The organisation logins a token carries, sorted.
 *
 * Reported back at login because the alternative is a silent shortfall. An
 * identity provider hands over the organisations it is *willing* to disclose,
 * not the ones the account belongs to: on GitHub an organisation that enforces
 * third-party application restrictions is simply absent from the response until
 * somebody approves this registry for it. The account looks like a non-member,
 * a claim under that scope is refused with a message about names not matching,
 * and nothing anywhere says which organisations were actually seen.
 *
 * So the token exchange answers with them. A client can print "you can claim:
 * ..." and the person recognises immediately that one of theirs is missing,
 * which turns a confusing refusal later into an obvious omission now. The
 * **logins** are returned and the ids are not, for the same reason `listScopes`
 * reports logins: an id is what ownership binds to, and a login is what a claim
 * is typed as.
 * @param orgs {map of string to string} folded login to provider id
 * @return {json.Value} the logins as a sorted JSON list
 */
export func orgNames(orgs as map of string to string) {
    def out as json.Value init json.list();
    for (def name in lists.sort(maps.keys($orgs))) {
        $out = json.append($out, "", $name);
    }
    return $out;
}

/**
 * `POST /auth/device` - begin a device authorization. The only outbound call is
 * to GitHub; nothing is stored, because nothing is decided yet.
 * @param cfg {Config} the issuing configuration
 * @param db {flatdb.DB} the store, returned untouched
 * @return {AuthReply} a 200 carrying the codes to show the user
 */
export func device(cfg as Config, db as flatdb.DB) {
    if (not enabled($cfg)) {
        return fail($db, 404, "this registry does not accept logins");
    }
    def dev as identity.Device;
    try {
        $dev = $cfg.provider.startDevice($cfg.providerConfig);
    } catch (err) {
        return fail($db, 502, "the provider could not start the login: " + $err.message);
    }
    def body as json.Value init json.map();
    $body = json.set($body, "/deviceCode", $dev.deviceCode);
    $body = json.set($body, "/userCode", $dev.userCode);
    $body = json.set($body, "/verificationUri", $dev.verificationUri);
    $body = json.set($body, "/expiresIn", $dev.expiresIn);
    $body = json.set($body, "/interval", $dev.interval);
    return AuthReply{ status: 200, body: $body, db: $db, changed: false };
}

/**
 * `POST /auth/token` - exchange an approved device code for a registry token.
 * Polled by the client until it resolves.
 * @param cfg {Config} the issuing configuration
 * @param db {flatdb.DB} the store to record the refresh token in
 * @param body {string} the raw request body, carrying `deviceCode`
 * @param now {int} the current time (Unix seconds)
 * @return {AuthReply} the outcome, and the store to persist on success
 */
export func token(cfg as Config, db as flatdb.DB, body as string, now as int) {
    if (not enabled($cfg)) {
        return fail($db, 404, "this registry does not accept logins");
    }
    def deviceCode as string init bodyField($body, "deviceCode");
    if ($deviceCode == "") {
        return fail($db, 400, "missing 'deviceCode' in the request body");
    }
    def result as identity.Poll;
    try {
        $result = $cfg.provider.poll($cfg.providerConfig, $deviceCode);
    } catch (err) {
        return fail($db, 502, "the provider could not be reached: " + $err.message);
    }
    if (not ($result.state == "ok")) {
        return stateReply($db, $result.state);
    }
    def who as identity.Subject;
    try {
        $who = $cfg.provider.subject($cfg.providerConfig, $result.accessToken);
    } catch (err) {
        return fail($db, 502, "the provider could not identify the account: " + $err.message);
    }
    # The provider token is discarded here, deliberately: the registry issues its
    # own credential rather than storing somebody else's (specification 8.4).
    # Memberships are read here and nowhere else. The provider token is about to
    # be discarded, so this is the only moment the registry can ask which
    # organisations this account acts for (8.7). A provider that cannot answer
    # returns none, which makes an organisation scope unwritable rather than
    # writable by anybody.
    def orgs as map of string to string init {};
    try {
        $orgs = $cfg.provider.memberships($cfg.providerConfig, $result.accessToken);
    } catch (err) {
        def none as map of string to string init {};
        $orgs = $none;
    }
    return issue($cfg, $db, convert.toInt($who.id), $who.login, $orgs, $now, $now);
}

/**
 * `POST /auth/refresh` - exchange a refresh token for a new token pair.
 *
 * The presented token is **rotated**: it is deleted before the replacement is
 * recorded, so a captured refresh token is spent the first time it is used and
 * the theft is visible as an unexpected logout rather than as silent, unbounded
 * access. No network call is involved.
 * @param cfg {Config} the issuing configuration
 * @param db {flatdb.DB} the store holding the refresh tokens
 * @param body {string} the raw request body, carrying `refreshToken`
 * @param now {int} the current time (Unix seconds)
 * @return {AuthReply} a new token pair, or a 401 the client answers by logging in
 */
export func refresh(cfg as Config, db as flatdb.DB, body as string, now as int) {
    if (not enabled($cfg)) {
        return fail($db, 404, "this registry does not accept logins");
    }
    def presented as string init bodyField($body, "refreshToken");
    if ($presented == "") {
        return fail($db, 400, "missing 'refreshToken' in the request body");
    }
    def print as string init token.fingerprint($presented);
    if (not store.hasRefresh($db, $print)) {
        return fail($db, 401, "that refresh token is not valid; log in again");
    }
    def rec as store.Refresh init store.getRefresh($db, $print);
    if ($rec.expiresAt <= $now) {
        # Expired: drop it on the way out rather than leaving it to the purge.
        def cleaned as flatdb.DB init store.deleteRefresh($db, $print);
        def reply as AuthReply init fail($cleaned, 401,
            "that refresh token expired; log in again");
        return AuthReply{
            status: $reply.status, body: $reply.body, db: $cleaned, changed: true
        };
    }
    def rotated as flatdb.DB init store.deleteRefresh($db, $print);
    # A refresh reissues the memberships it was given and **does not advance
    # `orgsCheckedAt`**. Refreshing proves possession of a refresh token, not
    # continued membership of an organisation, and letting the timestamp move
    # would make a stale membership renewable forever - which is exactly the
    # failure a co-owner list has and organisation scopes exist to avoid.
    return issue($cfg, $rotated, $rec.accountId, $rec.login, $rec.orgs,
        $rec.orgsCheckedAt, $now);
}

/**
 * Authenticate a request's `Authorization` header, for the write endpoints that
 * will come to need it.
 * @param cfg {Config} the issuing configuration
 * @param header {string} the raw `Authorization` header value
 * @return {token.Identity} the caller
 * @throws {Error} when the header is absent, malformed, or the token is invalid
 */
export func authenticate(cfg as Config, header as string) {
    if (not strings.startsWith($header, "Bearer ")) {
        throw Error{
            kind: "auth", message: "missing bearer token", file: "", line: 0, col: 0
        };
    }
    def bearer as string init strings.substring($header, 7, len($header));
    return token.verify($cfg.signingKey, $bearer);
}
