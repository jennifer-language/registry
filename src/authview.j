# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * The token-exchange endpoints (specification 8.4), as pure data. Each function
 * maps a request to an `AuthReply` (a reply plus the store to persist) with no
 * dependency on the web engine.
 *
 * Only the provider calls in `device` and `login` touch the network; the rest is a pure
 * function of its arguments and the store. `now` is a parameter so tests can
 * place a token either side of its expiry.
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
import "./forgecred.j" as forgecred;
import "./identity.j" as identity;

/**
 * The configuration for issuing tokens. An empty client id or signing key
 * disables the surface: the routes are not served and the discovery document
 * advertises no `auth` object.
 *
 * The provider is a struct of `func` values, so this module does not know which
 * identity provider it calls (specification 12.2).
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
    refreshTtl as int,
    orgMaxAge as int
};

/**
 * A reply plus the store to persist. The caller saves when `changed` is set.
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
    return AuthReply{status: $status, body: $body, db: $db, changed: false};
}

# pending builds the 202 a client polls against.
func pending(db as flatdb.DB) {
    def body as json.Value init json.map();
    $body = json.set($body, "/status", "pending");
    return AuthReply{status: 202, body: $body, db: $db, changed: false};
}

/**
 * Report whether a configuration can issue tokens: it needs both a client id and
 * a signing key.
 * @param cfg {Config} the configuration to test
 * @return {bool} true when the auth surface should be served
 */
export func enabled(cfg as Config) {
    return not ($cfg.providerConfig.clientId == "") and len($cfg.signingKey) > 0;
}

/**
 * Read a required string field from a request body. A malformed body and a
 * missing field both yield "".
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
 * Map a poll state onto the reply a client polls against. The outcome is in the
 * status code, so a client can branch without reading the message.
 * @param db {flatdb.DB} the store, returned untouched
 * @param state {string} an `identity.Poll` state other than "ok"
 * @return {AuthReply} the reply for that state
 */
export func stateReply(db as flatdb.DB, state as string, detail as string) {
    match ($state) {
        when "pending" { return pending($db); }
        when "slowDown" {
            return fail($db, 429, "polling too fast; wait for the interval and retry");
        }
        when "denied" { return fail($db, 403, "the request was denied by the identity provider"); }
        when "expired" { return fail($db, 410, "this device code expired; start the login again"); }
        when "invalid" {
            return fail($db, 400, "the identity provider does not know this device code");
        }
        when "spent" {
            # A 400, not a 502: jvc retries a 5xx, and this code cannot succeed.
            return fail(
                $db,
                400,
                "the identity provider could not exchange this device code (" + $detail +
                    "); a code already exchanged ends this way: start the login again");
        }
    }
    # Not in the grant's vocabulary: the provider, or the registry's client
    # configuration, is at fault, not the user. The code is what the operator
    # needs to see (`incorrect_client_credentials`, `device_flow_disabled`).
    return fail(
        $db,
        502,
        "the identity provider answered the poll with an unexpected error: " + $detail);
}

/**
 * Issue a bearer token and a refresh token for an account, recording the
 * refresh token by fingerprint and dropping any that have expired. Login and
 * refresh both answer through here, so their response shape is the same.
 * @param cfg {Config} the issuing configuration
 * @param db {flatdb.DB} the store to record the refresh token in
 * @param subject {string} the provider's subject id (8.1)
 * @param login {string} the provider login, carried as a display label
 * @param orgs {map of string to string} the organisations read at login (8.7)
 * @param checkedAt {int} when those memberships were read (Unix seconds). Carried
 *     separately so a refresh can reissue them without pretending they are fresh.
 * @param now {int} the current time (Unix seconds)
 * @return {AuthReply} a 200 carrying the token pair, and the store to persist
 */
export func issue(
    cfg as Config,
    db as flatdb.DB,
    subject as string,
    login as string,
    orgs as map of string to string,
    checkedAt as int,
    now as int) {
    def bearer as string init token.mint(
        $cfg.signingKey,
        $cfg.providerConfig.name,
        $subject,
        $login,
        $orgs,
        $checkedAt,
        $cfg.tokenTtl,
        $now);
    def refreshToken as string init token.newRefresh();
    def out as flatdb.DB init store.purgeExpiredRefresh($db, $now);
    $out = store.putRefresh(
        $out,
        token.fingerprint($refreshToken),
        store.Refresh{
            subject: $subject,
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
    $body = json.set($body, "/subject", $subject);
    # `accountId` predates opaque subjects; kept for clients that read a number.
    def numeric as int init numericId($subject);
    if ($numeric > 0) {
        $body = json.set($body, "/accountId", $numeric);
    }
    $body = json.set($body, "/orgs", orgNames($orgs));
    return AuthReply{status: 200, body: $body, db: $out, changed: true};
}

/**
 * The organisation logins a token carries, sorted.
 *
 * Returned at login because a provider discloses only the organisations it is
 * willing to: on GitHub an organisation with third-party application
 * restrictions is absent until it approves this registry, and the account then
 * looks like a non-member. Showing the list lets a person spot the missing one.
 * Logins are returned rather than ids because a claim is typed as a login.
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
 * `POST /auth/device`: begin a device authorization. Calls the provider and
 * stores nothing.
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
    return AuthReply{status: 200, body: $body, db: $db, changed: false};
}

/**
 * The result of the network half of a token exchange: an early answer (`ok`
 * false, `reply` ready to send) or the identified account.
 * @field ok {bool} true when the provider identified an account
 * @field reply {AuthReply} the answer to send when `ok` is false
 * @field subject {string} the provider's subject id (8.1)
 * @field login {string} the account's login, a display label
 * @field orgs {map of string to string} folded organisation login to provider id
 * @field accessToken {string} the provider's token, for `issueLogin` to keep
 *     sealed or drop; never part of any reply
 */
export def struct Login {
    ok as bool,
    reply as AuthReply,
    subject as string,
    login as string,
    orgs as map of string to string,
    accessToken as string
};

# noStore is the empty, never-saved store an early `Login` reply carries. The
# network half runs without the write lock, so it must not hold the real registry.
func noStore() {
    return flatdb.openString('{}');
}

# early wraps an answer that ends the exchange before any account is known.
func early(reply as AuthReply) {
    def none as map of string to string init {};
    return Login{ok: false, reply: $reply, subject: "", login: "", orgs: $none, accessToken: ""};
}

/**
 * The network half of `POST /auth/token`: turn an approved device code, or an
 * authorization code (`authcode`, 12.2), into a provider token, then identify
 * the account and read its memberships.
 *
 * The body carries `deviceCode`, or `code`, `codeVerifier` and `redirectUri`
 * (PKCE, RFC 7636). The redirect must be a loopback address (RFC 8252), so the
 * registry exchanges codes only for a client running on the user's machine.
 *
 * Separate from `issueLogin` so these calls run without the write lock;
 * holding it across them would let a slow provider, or anybody polling with a
 * made-up code, stall every publish.
 * @param cfg {Config} the issuing configuration
 * @param body {string} the raw request body
 * @return {Login} the identified account, or an early answer
 */
export func login(cfg as Config, body as string) {
    if (not enabled($cfg)) {
        return early(fail(noStore(), 404, "this registry does not accept logins"));
    }
    def deviceCode as string init bodyField($body, "deviceCode");
    def code as string init bodyField($body, "code");
    if ($deviceCode == "" and not ($code == "")) {
        return byCode(
            $cfg,
            $code,
            bodyField($body, "codeVerifier"),
            bodyField($body, "redirectUri"));
    }
    if ($deviceCode == "") {
        return early(fail(noStore(), 400, "missing 'deviceCode' (or 'code') in the request body"));
    }
    def result as identity.Poll;
    try {
        $result = $cfg.provider.poll($cfg.providerConfig, $deviceCode);
    } catch (err) {
        return early(fail(noStore(), 502, "the provider could not be reached: " +
            $err.message));
    }
    if (not ($result.state == "ok")) {
        return early(stateReply(noStore(), $result.state, $result.detail));
    }
    return identify($cfg, $result.accessToken);
}

# byCode exchanges an authorization code for a provider token (12.2 `authcode`).
func byCode(cfg as Config, code as string, verifier as string, redirectUri as string) {
    if ($verifier == "" or $redirectUri == "") {
        return early(fail(
            noStore(),
            400,
            "an authorization code needs 'codeVerifier' and 'redirectUri'"));
    }
    if (not isLoopbackRedirect($redirectUri)) {
        return early(fail(
            noStore(),
            400,
            "'redirectUri' must be a loopback address (http://127.0.0.1:<port>/... or " +
                "http://[::1]:<port>/...)"));
    }
    def accessToken as string init "";
    try {
        $accessToken = $cfg.provider.exchangeCode(
            $cfg.providerConfig,
            $code,
            $verifier,
            $redirectUri);
    } catch (err) {
        return early(fail(
            noStore(),
            400,
            "the provider refused the authorization code: " +
                $err.message));
    }
    if ($accessToken == "") {
        return early(fail(
            noStore(),
            400,
            "this registry's provider does not offer the authcode flow"));
    }
    return identify($cfg, $accessToken);
}

# isLoopbackRedirect accepts only `http` on an IP loopback literal with a port,
# the redirect RFC 8252 section 7.3 prescribes for native clients.
func isLoopbackRedirect(uri as string) {
    for (def prefix in ["http://127.0.0.1:", "http://[::1]:"]) {
        if (strings.startsWith($uri, $prefix)) {
            return isPort(portOf(strings.substring($uri, len($prefix), len($uri))));
        }
    }
    return false;
}

# portOf is the text before the first `/` of what follows `host:`.
func portOf(rest as string) {
    def slash as int init strings.indexOf($rest, "/");
    if ($slash < 0) {
        return $rest;
    }
    return strings.substring($rest, 0, $slash);
}

# isPort accepts one to five decimal digits.
func isPort(s as string) {
    if (len($s) == 0 or len($s) > 5) {
        return false;
    }
    for (def ch in strings.chars($s)) {
        if ($ch < "0" or $ch > "9") {
            return false;
        }
    }
    return true;
}

# identify asks the provider who a fresh provider token belongs to, and which
# organisations it is in.
func identify(cfg as Config, accessToken as string) {
    def who as identity.Subject;
    try {
        $who = $cfg.provider.subject($cfg.providerConfig, $accessToken);
    } catch (err) {
        return early(fail(
            noStore(),
            502,
            "the provider could not identify the account: " +
                $err.message));
    }
    # The registry issues its own credential (specification 8.4); the provider
    # token goes to `issueLogin` only to be kept sealed (8.5, 7.1 route A), never
    # into a reply. Memberships are read only here (8.7). A provider that cannot
    # answer returns none, so an organisation scope is unwritable rather than
    # writable by anybody.
    def orgs as map of string to string init {};
    try {
        $orgs = $cfg.provider.memberships($cfg.providerConfig, $accessToken);
    } catch (err) {
        def none as map of string to string init {};
        $orgs = $none;
    }
    # The subject is stored and compared as an opaque string (8.1); an OIDC `sub`
    # is often a UUID.
    if (not identity.isSubject($who.id)) {
        return early(fail(noStore(), 502, "the provider returned an unusable subject id"));
    }
    return Login{
        ok: true,
        reply: pending(noStore()),
        subject: $who.id,
        login: $who.login,
        orgs: $orgs,
        accessToken: $accessToken
    };
}

# numericId is the subject as a positive number when it is written as one
# (no sign, no leading zero), else 0. Only for the `accountId` reply field.
func numericId(id as string) {
    def n as int init 0;
    try {
        $n = convert.toInt($id);
    } catch (err) {
        return 0;
    }
    if ($n <= 0 or not (convert.toString($n) == $id)) {
        return 0;
    }
    return $n;
}

/**
 * The store half of `POST /auth/token`: issue a token pair for what `login`
 * found, or pass its early answer through. No network call; the caller holds
 * the write lock and passes a store opened under it.
 *
 * The provider's token is stored sealed against the account, replacing any
 * earlier one: every refresh asks the provider with it whether the grant still
 * stands (8.5), and in `login` source authority a publish asks the forge with it
 * whether the account may push (7.1 route A). Revoking the account drops it.
 * @param cfg {Config} the issuing configuration
 * @param db {flatdb.DB} the store to record the refresh token in
 * @param got {Login} what `login` returned
 * @param now {int} the current time (Unix seconds)
 * @return {AuthReply} the outcome, and the store to persist on success
 */
export func issueLogin(cfg as Config, db as flatdb.DB, got as Login, now as int) {
    if (not $got.ok) {
        return AuthReply{status: $got.reply.status, body: $got.reply.body, db: $db, changed: false};
    }
    def out as flatdb.DB init $db;
    if (not ($got.accessToken == "")) {
        $out = store.putForgeToken(
            $out,
            $got.subject,
            forgecred.seal($cfg.signingKey, $got.accessToken),
            $now);
    }
    return issue($cfg, $out, $got.subject, $got.login, $got.orgs, $now, $now);
}

/**
 * `POST /auth/token`: exchange an approved device code for a registry token.
 * `login` then `issueLogin`, for a caller that does not need the network calls
 * outside the lock.
 * @param cfg {Config} the issuing configuration
 * @param db {flatdb.DB} the store to record the refresh token in
 * @param body {string} the raw request body, carrying `deviceCode`
 * @param now {int} the current time (Unix seconds)
 * @return {AuthReply} the outcome, and the store to persist on success
 */
export func token(cfg as Config, db as flatdb.DB, body as string, now as int) {
    return issueLogin($cfg, $db, login($cfg, $body), $now);
}

/**
 * How long a login lasts however often it is refreshed, in seconds: 30 days.
 *
 * Bounds how long login-time data stays in use: org memberships (a departed
 * member could keep publishing) and the login asked of a forge (a renamed
 * account). Counted from `orgsCheckedAt`, which a refresh never advances; a
 * record without that field reads as 0 and needs a fresh login.
 */
export def const MAX_SESSION_SECONDS as int init 2592000;

/** The provider still accepts the login's token for the same account. */
export def const GRANT_VALID as string init "valid";
/** The provider refused the token (revoked or expired), or it names another account. */
export def const GRANT_REVOKED as string init "revoked";
/** No provider token is kept for the account, so the grant cannot be re-checked. */
export def const GRANT_MISSING as string init "missing";
/** The provider could not be asked; says nothing about the grant. */
export def const GRANT_UNKNOWN as string init "unknown";

/**
 * The network half of `POST /auth/refresh`: ask the provider, with the token
 * kept at login, whether the grant behind this refresh token still stands
 * (specification 8.5: revoking it must prevent a new registry token).
 *
 * Runs without the write lock, like `login`. Answers "" when the body names no
 * refresh token on record; `refresh` then refuses on its own.
 * @param cfg {Config} the issuing configuration
 * @param db {flatdb.DB} the store holding the refresh and provider tokens
 * @param body {string} the raw request body, carrying `refreshToken`
 * @return {string} one of the `GRANT_` values, or ""
 */
export func checkGrant(cfg as Config, db as flatdb.DB, body as string) {
    def presented as string init bodyField($body, "refreshToken");
    if ($presented == "" or not store.hasRefresh($db, token.fingerprint($presented))) {
        return "";
    }
    def rec as store.Refresh init store.getRefresh($db, token.fingerprint($presented));
    def sealed as string init store.getForgeToken($db, $rec.subject);
    if ($sealed == "") {
        return GRANT_MISSING;
    }
    def accessToken as string init "";
    try {
        $accessToken = forgecred.unseal($cfg.signingKey, $sealed);
    } catch (err) {
        # sealed under another signing key: unreadable, so unverifiable
        return GRANT_MISSING;
    }
    def who as identity.Subject;
    try {
        $who = $cfg.provider.subject($cfg.providerConfig, $accessToken);
    } catch (err) {
        if ($err.kind == identity.REJECTED) {
            return GRANT_REVOKED;
        }
        return GRANT_UNKNOWN;
    }
    if (not ($who.id == $rec.subject)) {
        return GRANT_REVOKED;
    }
    return GRANT_VALID;
}

/**
 * `POST /auth/refresh`: exchange a refresh token for a new token pair. No
 * network call; `checkGrant` asked the provider first.
 *
 * The presented token is deleted before its replacement is recorded, so a
 * captured token works once and the theft shows as an unexpected logout. A
 * revoked grant ends the login and drops the kept provider token; a provider
 * that could not be asked is a `502` that keeps the refresh token for a retry.
 * @param cfg {Config} the issuing configuration
 * @param db {flatdb.DB} the store holding the refresh tokens
 * @param body {string} the raw request body, carrying `refreshToken`
 * @param now {int} the current time (Unix seconds)
 * @param grant {string} what `checkGrant` answered
 * @return {AuthReply} a new token pair, or a 401 the client answers by logging in
 */
export func refresh(cfg as Config, db as flatdb.DB, body as string, now as int, grant as string) {
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
        def reply as AuthReply init fail($cleaned, 401, "that refresh token expired; log in again");
        return AuthReply{status: $reply.status, body: $reply.body, db: $cleaned, changed: true};
    }
    if ($now - $rec.orgsCheckedAt > MAX_SESSION_SECONDS) {
        def ended as flatdb.DB init store.deleteRefresh($db, $print);
        def over as AuthReply init fail(
            $ended,
            401,
            "this login is older than " +
                convert.toString(convert.toInt(MAX_SESSION_SECONDS / 86400)) +
                " days; log in again");
        return AuthReply{status: $over.status, body: $over.body, db: $ended, changed: true};
    }
    # 8.7: memberships older than the window must not reach a write. Refusing the
    # refresh bounds them to the window plus one bearer-token lifetime.
    if ($cfg.orgMaxAge > 0 and len($rec.orgs) > 0 and $now - $rec.orgsCheckedAt > $cfg.orgMaxAge) {
        def stale as flatdb.DB init store.deleteRefresh($db, $print);
        def aged as AuthReply init fail(
            $stale,
            401,
            "the organisation memberships of this login are older than " +
                convert.toString(convert.toInt($cfg.orgMaxAge / 3600)) +
                " hours; log in again to read them afresh");
        return AuthReply{status: $aged.status, body: $aged.body, db: $stale, changed: true};
    }
    if ($grant == GRANT_REVOKED or $grant == GRANT_MISSING) {
        def gone as flatdb.DB init store.deleteRefresh($db, $print);
        def why as string init "the provider no longer accepts this login (revoked or expired)";
        if ($grant == GRANT_REVOKED) {
            $gone = store.deleteForgeToken($gone, $rec.subject);
        } else {
            $why = "this login has no provider grant on record to re-check";
        }
        def ended as AuthReply init fail($gone, 401, $why + "; log in again");
        return AuthReply{status: $ended.status, body: $ended.body, db: $gone, changed: true};
    }
    if (not ($grant == GRANT_VALID)) {
        return fail(
            $db,
            502,
            "the provider could not be asked whether this login still stands; try again");
    }
    def rotated as flatdb.DB init store.deleteRefresh($db, $print);
    # Keep `orgsCheckedAt`: a refresh proves possession of a token, not continued
    # membership, so advancing it would make a stale membership renewable forever.
    return issue($cfg, $rotated, $rec.subject, $rec.login, $rec.orgs, $rec.orgsCheckedAt, $now);
}

/**
 * Authenticate a request's `Authorization` header.
 * @param cfg {Config} the issuing configuration
 * @param header {string} the raw `Authorization` header value
 * @return {token.Identity} the caller
 * @throws {Error} when the header is absent, malformed, or the token is invalid
 */
export func authenticate(cfg as Config, header as string) {
    # The scheme is case-insensitive (RFC 7235 2.1); the token is not.
    if (len($header) < 8 or not (strings.lower(strings.substring($header, 0, 7)) == "bearer ")) {
        throw Error{kind: "auth", message: "missing bearer token", file: "", line: 0, col: 0};
    }
    def bearer as string init strings.substring($header, 7, len($header));
    return token.verify($cfg.signingKey, $cfg.providerConfig.name, $bearer);
}
