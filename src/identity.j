# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The identity-provider interface (specification 12.2): who is this caller,
 * stably?
 *
 * A deployment names one provider module under `identity/`, each exporting a
 * `provider()` that returns a `Provider` - a struct of `func` values the core
 * calls without knowing which module supplied them. This module holds the shared
 * types, because a Jennifer struct is identified by `(module, name)`: four
 * provider modules each declaring their own `Subject` would declare four
 * incompatible types.
 *
 * Not to be confused with `token.j`, which mints the registry's *own* bearer
 * token. A provider here answers for an **external** identity; `token.j` turns
 * that answer into a credential the registry issues.
 *
 * This module is pure. The provider modules are where the network lives, and
 * each keeps its parsing separate from its one HTTP call so the parsing can be
 * tested without a socket.
 * @module identity
 * @example
 * import "./identity/github.j" as github;
 * def p as identity.Provider init github.provider();
 * def d as identity.Device init $p.startDevice($cfg);
 */

use strings;

/**
 * Where a provider lives and what it is registered as. Self-hosted instances of
 * GitLab, Gitea, and Forgejo differ from their hosted counterparts **only** in
 * `baseUrl`, which is why there is one module per API family rather than one per
 * deployment.
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
 *     account id on a forge, the `sub` claim on OIDC. **This is what scope
 *     ownership binds to** (specification 8.1).
 * @field login {string} the provider's username, a display label only
 */
export def struct Subject {
    provider as string,
    id as string,
    login as string,
    orgs as list of string,
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
 * An identity provider, as a set of func values.
 *
 * **Every function takes the `Config` as its first argument.** Jennifer has no
 * closures and a module top level is declarations-only, so a provider cannot be
 * built around a configuration it remembers; the caller holds the pair and
 * passes it in. `provider()` therefore takes nothing and returns a vtable.
 * @field name {string} the provider name, advertised in discovery
 * @field flow {func} `func(Config) -> string`: "device" or "authcode" (12.2)
 * @field startDevice {func} `func(Config) -> Device`: begin a device authorization
 * @field poll {func} `func(Config, deviceCode) -> Poll`: poll once for approval
 * @field authorizeUrl {func} `func(Config, state, challenge) -> string`: the URL a
 *     client opens under `authcode`; "" for a device-only provider
 * @field exchangeCode {func} `func(Config, code, verifier) -> string`: swap an
 *     authorization code for a provider token
 * @field memberships {func} `func(Config, accessToken) -> list of string`: the
 *     organisation ids this token's owner is an **active** member of. Asked once,
 *     at login, because the provider token is discarded immediately afterwards
 *     (8.4) and there is no way to ask again later.
 * @field subject {func} `func(Config, accessToken) -> Subject`: who this token is
 */
export def struct Provider {
    name as string,
    flow as func,
    startDevice as func,
    poll as func,
    authorizeUrl as func,
    exchangeCode as func,
    subject as func,
    memberships as func
};

# The states a poll may report. `slowDown` is deliberately distinct from
# `pending`: both mean keep waiting, but the first also means widen the interval,
# which the registry passes on as a 429 rather than another 202.
export def const STATE_OK as string init "ok";
export def const STATE_PENDING as string init "pending";
export def const STATE_SLOWDOWN as string init "slowDown";
export def const STATE_DENIED as string init "denied";
export def const STATE_EXPIRED as string init "expired";

/**
 * Map the OAuth device-grant error vocabulary (RFC 8628) onto the states this
 * registry serves. Every provider speaking the standard grant shares it, so it
 * lives here rather than being repeated per module.
 *
 * An unrecognised error is **terminal**, not pending: waiting cannot recover
 * from an error we do not know, and treating it as pending would spin a client
 * until its device code expired.
 * @param code {string} the provider's `error` field ("" when the exchange succeeded)
 * @return {string} one of the STATE_ constants
 */
export func pollState(code as string) {
    match ($code) {
        when "" {
            return STATE_OK;
        }
        when "authorization_pending" {
            return STATE_PENDING;
        }
        when "slow_down" {
            return STATE_SLOWDOWN;
        }
        when "access_denied" {
            return STATE_DENIED;
        }
        when "expired_token" {
            return STATE_EXPIRED;
        }
    }
    return STATE_DENIED;
}

/**
 * Join a configured base URL with a path, tolerating a trailing slash on the
 * base and supplying a default when the deployment set none. Self-hosted
 * instances differ from hosted ones only here, so getting it right once removes
 * a whole class of per-provider bug.
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
