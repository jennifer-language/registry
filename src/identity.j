# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The identity-provider interface (specification 12.2): the caller's stable
 * external identity.
 *
 * A deployment names one provider module under `identity/`, whose `provider()`
 * returns a `Provider`, a struct of `func` values. The shared types live here
 * because a struct type is identified by `(module, name)`.
 *
 * `token.j` mints the registry's own bearer token from what a provider reports.
 *
 * Pure. Provider modules do the network calls and keep their parsing separate
 * so it can be tested without a socket.
 * @module identity
 * @example
 * import "./identity/github.j" as github;
 * def p as identity.Provider init github.provider();
 * def d as identity.Device init $p.startDevice($cfg);
 */

use strings;

/**
 * Where a provider lives and what it is registered as. Self-hosted GitLab,
 * Gitea and Forgejo differ from hosted only in `baseUrl`, so there is one module
 * per API family.
 * @field name {string} the provider name advertised in discovery ("github", ...)
 * @field baseUrl {string} the instance root, no trailing slash ("" = the module's default)
 * @field clientId {string} the OAuth application id
 * @field clientSecret {string} the OAuth application secret ("" where the flow needs none)
 * @field scopes {string} the scopes to request, space-separated
 */
export def struct Config {
    name as string,
    baseUrl as string,
    clientId as string,
    clientSecret as string,
    scopes as string
};

/**
 * Who the caller is, as the provider reports them.
 * @field provider {string} the provider that issued this subject
 * @field id {string} the provider's stable subject identifier, opaque; a numeric
 *     account id on a forge, the `sub` claim on OIDC. Scope ownership binds to
 *     it (specification 8.1).
 * @field login {string} the provider's username, a display label only
 * @field orgs {map of string to string} folded organisation login to provider id;
 *     empty from a provider's `subject`, filled from the bearer token (8.7)
 * @field orgsCheckedAt {string} when `orgs` was read (Unix seconds as text); ""
 *     when not known
 */
export def struct Subject {
    provider as string,
    id as string,
    login as string,
    orgs as map of string to string,
    orgsCheckedAt as string
};

/**
 * A device authorization, as issued.
 * @field deviceCode {string} the code the registry polls with, opaque to the user
 * @field userCode {string} the short code the user types
 * @field verificationUri {string} where the user types it
 * @field expiresIn {int} how long the pair remains valid, in seconds
 * @field interval {int} the minimum seconds between polls
 */
export def struct Device {
    deviceCode as string,
    userCode as string,
    verificationUri as string,
    expiresIn as int,
    interval as int
};

/**
 * The outcome of one poll.
 * @field state {string} "ok", "pending", "slowDown", "denied", or "expired"
 * @field accessToken {string} the provider token, set only when state is "ok"
 */
export def struct Poll {
    state as string,
    accessToken as string
};

/**
 * Whether `s` is usable as a subject id (specification 8.1): an opaque string of
 * 1 to 255 printable ASCII characters without whitespace, the bound OIDC places
 * on `sub`. Numeric ids (GitHub, GitLab, Gitea) qualify as their decimal text.
 * @param s {string} the candidate
 * @return {bool} true when it can be stored and compared as a subject
 */
export func isSubject(s as string) {
    if (len($s) == 0 or len($s) > 255) {
        return false;
    }
    for (def ch in strings.chars($s)) {
        if ($ch < "!" or $ch > "~") {
            return false;
        }
    }
    return true;
}

/**
 * The error kind `subject` throws when the provider refuses the token outright
 * (HTTP 401): it was revoked or has expired. Any other failure is `identity` or
 * a network kind, which says nothing about the grant (specification 8.5).
 */
export def const REJECTED as string init "rejected";

/**
 * The error kind for a provider refusing a token with `status`.
 * @param status {int} the provider's HTTP status
 * @return {string} `REJECTED` for 401, `identity` otherwise
 */
export func rejectionKind(status as int) {
    if ($status == 401) {
        return REJECTED;
    }
    return "identity";
}

/**
 * An identity provider, as a set of func values.
 *
 * Every function takes the `Config` as its first argument: Jennifer has no
 * closures, so `provider()` takes nothing and returns a vtable, and the caller
 * passes the configuration on each call.
 * @field name {string} the provider name, advertised in discovery
 * @field flow {func} `func(Config) -> string`: "device" or "authcode" (12.2)
 * @field startDevice {func} `func(Config) -> Device`: begin a device authorization
 * @field poll {func} `func(Config, deviceCode) -> Poll`: poll once for approval
 * @field authorizeUrl {func} `func(Config) -> string`: the provider's authorization
 *     endpoint, advertised as `auth.authorizeUrl` under `authcode` (12.2); "" for a
 *     device-only provider
 * @field exchangeCode {func} `func(Config, code, verifier, redirectUri) -> string`:
 *     swap an authorization code (PKCE) for a provider token; throws on refusal
 * @field scopes {func} `func(Config) -> string`: the space-separated scopes a
 *     login requests, advertised as `auth.scopes` under `authcode`
 * @field memberships {func} `func(Config, accessToken) -> map of string to string`:
 *     the organisations this token's owner is an active member of, as folded
 *     login -> id. Asked once, at login (8.7).
 * @field subject {func} `func(Config, accessToken) -> Subject`: who this token is;
 *     throws kind `REJECTED` when the provider answers 401
 */
export def struct Provider {
    name as string,
    flow as func,
    startDevice as func,
    poll as func,
    authorizeUrl as func,
    exchangeCode as func,
    scopes as func,
    subject as func,
    memberships as func
};

# The states a poll may report. `slowDown` also means widen the interval, and
# the registry answers it with 429 instead of 202.
export def const STATE_OK as string init "ok";
export def const STATE_PENDING as string init "pending";
export def const STATE_SLOWDOWN as string init "slowDown";
export def const STATE_DENIED as string init "denied";
export def const STATE_EXPIRED as string init "expired";

/**
 * Map the OAuth device-grant error vocabulary (RFC 8628) onto the states this
 * registry serves, shared by every provider speaking the standard grant.
 *
 * An unrecognised error is terminal: treating it as pending would spin a client
 * until its device code expired.
 * @param code {string} the provider's `error` field ("" when the exchange succeeded)
 * @return {string} one of the STATE_ constants
 */
export func pollState(code as string) {
    match ($code) {
        when "" { return STATE_OK; }
        when "authorization_pending" { return STATE_PENDING; }
        when "slow_down" { return STATE_SLOWDOWN; }
        when "access_denied" { return STATE_DENIED; }
        when "expired_token" { return STATE_EXPIRED; }
    }
    return STATE_DENIED;
}

/**
 * Join a configured base URL with a path, tolerating a trailing slash on the
 * base and supplying a default when the deployment set none.
 * @param baseUrl {string} the configured base ("" to use the default)
 * @param fallback {string} the module's default base
 * @param path {string} the path, beginning with "/"
 * @return {string} the absolute URL
 */
export func endpoint(baseUrl as string, fallback as string, path as string) {
    def base as string init strings.trim($baseUrl);
    if ($base == "") {
        $base = $fallback;
    }
    if (strings.endsWith($base, "/")) {
        $base = strings.substring($base, 0, len($base) - 1);
    }
    return $base + $path;
}
