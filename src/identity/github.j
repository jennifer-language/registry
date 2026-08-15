# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * GitHub as an identity provider: the OAuth 2.0 device authorization grant
 * (RFC 8628), which the public registry runs (specification 12.7).
 *
 * **The registry drives the flow; the client never talks to GitHub and never
 * holds a GitHub token.** That keeps the OAuth application, its id, and its
 * scopes here, and keeps clients free of per-registry configuration.
 *
 * The device grant needs no client secret, which is the point of it: there is
 * nothing to leak, because the grant is designed for clients that cannot keep a
 * secret.
 *
 * `subjectFrom` is separated from the request that feeds it, so the parsing is
 * covered by the overlay without a socket.
 * @module github
 * @example
 * import "./github.j" as github;
 * def p as identity.Provider init github.provider();
 * def d as identity.Device init $p.startDevice($cfg);
 */

use json;
use strings;
use convert;
use encoding;
import "http.j" as http;
import "../identity.j" as identity;

# The hosted endpoints. A GitHub Enterprise instance overrides `baseUrl`; the
# API host is derived from it, since Enterprise serves both from one root.
def const WEB_BASE as string init "https://github.com";
def const API_BASE as string init "https://api.github.com";

def const TIMEOUT_MS as int init 10000;
def const MAX_BYTES as int init 65536;

# The narrowest scopes that work (specification 8.6): the account's stable id and
# login, and organisation membership for a later org surface. No `repo` scope:
# decks are public, so contents and permissions are readable without it.
def const DEFAULT_SCOPES as string init "read:user read:org";

# formField encodes one form-urlencoded pair.
func formField(name as string, value as string) {
    def raw as bytes init convert.bytesFromString($value, "utf-8");
    return $name + "=" + encoding.toText($raw, "uri-form");
}

# jsonHeaders asks GitHub for JSON; the OAuth endpoints answer form-urlencoded
# by default, for historical reasons.
func jsonHeaders() {
    def h as map of string to string init {};
    $h["Accept"] = "application/json";
    return $h;
}

# optInt reads an integer field, falling back when the provider omits it.
func optInt(doc as json.Value, field as string, fallback as int) {
    if (json.has($doc, $field)) {
        return json.asInt($doc, $field);
    }
    return $fallback;
}

/**
 * Build a `Subject` from GitHub's `/user` payload. Pure, so the mapping that
 * decides **what scope ownership binds to** is testable without a socket.
 *
 * `id` is GitHub's numeric account id, carried as text because a subject is
 * opaque at this interface; `login` is a display label and is never
 * authoritative (specification 8.1).
 * @param doc {json.Value} the decoded `/user` response
 * @return {identity.Subject} the caller
 * @throws {Error} when the payload carries no id
 */
export func subjectFrom(doc as json.Value) {
    if (not json.has($doc, "/id")) {
        throw Error{
            kind: "identity",
            message: "GitHub returned an account with no id",
            file: "", line: 0, col: 0
        };
    }
    def login as string init "";
    if (json.has($doc, "/login")) {
        $login = json.asString($doc, "/login");
    }
    return identity.Subject{
        provider: "github",
        id: convert.toString(json.asInt($doc, "/id")),
        login: $login
    };
}

/**
 * Build a `Device` from GitHub's device-code payload. Pure.
 * @param doc {json.Value} the decoded response
 * @return {identity.Device} the issued authorization
 * @throws {Error} when the provider refused
 */
export func deviceFrom(doc as json.Value) {
    if (json.has($doc, "/error")) {
        throw Error{
            kind: "identity",
            message: "device authorization refused: " + json.asString($doc, "/error"),
            file: "", line: 0, col: 0
        };
    }
    return identity.Device{
        deviceCode: json.asString($doc, "/device_code"),
        userCode: json.asString($doc, "/user_code"),
        verificationUri: json.asString($doc, "/verification_uri"),
        expiresIn: optInt($doc, "/expires_in", 900),
        interval: optInt($doc, "/interval", 5)
    };
}

/**
 * Build a `Poll` from GitHub's token-exchange payload. Pure.
 * @param doc {json.Value} the decoded response
 * @return {identity.Poll} the outcome
 */
export func pollFrom(doc as json.Value) {
    def code as string init "";
    if (json.has($doc, "/error")) {
        $code = json.asString($doc, "/error");
    }
    def state as string init identity.pollState($code);
    if (not ($state == identity.STATE_OK)) {
        return identity.Poll{ state: $state, accessToken: "" };
    }
    return identity.Poll{
        state: identity.STATE_OK,
        accessToken: json.asString($doc, "/access_token")
    };
}

/**
 * The endpoints this provider uses, given a configured base.
 * @param cfg {identity.Config} the provider configuration
 * @param which {string} "device", "token", or "user"
 * @return {string} the absolute URL
 */
export func endpointFor(cfg as identity.Config, which as string) {
    match ($which) {
        when "device" {
            return identity.endpoint($cfg.baseUrl, WEB_BASE, "/login/device/code");
        }
        when "token" {
            return identity.endpoint($cfg.baseUrl, WEB_BASE, "/login/oauth/access_token");
        }
    }
    return identity.endpoint($cfg.baseUrl, API_BASE, "/user");
}

/**
 * The scopes this provider requests, defaulting when the deployment set none.
 * @param cfg {identity.Config} the provider configuration
 * @return {string} the scope string
 */
export func scopesFor(cfg as identity.Config) {
    if (strings.trim($cfg.scopes) == "") {
        return DEFAULT_SCOPES;
    }
    return $cfg.scopes;
}

# post issues a form-urlencoded POST and returns the decoded JSON body.
func post(url as string, body as string) {
    def res as http.Response init http.requestWith("POST", $url, jsonHeaders(), $body,
        TIMEOUT_MS, MAX_BYTES);
    return json.decode($res.body);
}

# --- the Provider vtable ----------------------------------------------------

# flowOf reports the flow this provider supports.
func flowOf(cfg as identity.Config) {
    return "device";
}

# start begins a device authorization.
func start(cfg as identity.Config) {
    def body as string init formField("client_id", $cfg.clientId) + "&" +
        formField("scope", scopesFor($cfg));
    return deviceFrom(post(endpointFor($cfg, "device"), $body));
}

# pollOnce polls for the user's approval.
func pollOnce(cfg as identity.Config, deviceCode as string) {
    def body as string init formField("client_id", $cfg.clientId) + "&" +
        formField("device_code", $deviceCode) + "&" +
        formField("grant_type", "urn:ietf:params:oauth:grant-type:device_code");
    return pollFrom(post(endpointFor($cfg, "token"), $body));
}

# authorize is unused: this provider runs the device flow, so a client never
# needs an authorization URL of its own.
func authorize(cfg as identity.Config, state as string, challenge as string) {
    return "";
}

# exchange is unused for the same reason.
func exchange(cfg as identity.Config, code as string, verifier as string) {
    return "";
}

# subjectOf reads the account a provider token belongs to.
func subjectOf(cfg as identity.Config, accessToken as string) {
    def h as map of string to string init jsonHeaders();
    $h["Authorization"] = "Bearer " + $accessToken;
    $h["User-Agent"] = "jennifer-registry";
    def res as http.Response init http.requestWith("GET", endpointFor($cfg, "user"), $h,
        "", TIMEOUT_MS, MAX_BYTES);
    if (not ($res.status == 200)) {
        throw Error{
            kind: "identity",
            message: "GitHub rejected the token: " + convert.toString($res.status),
            file: "", line: 0, col: 0
        };
    }
    return subjectFrom(json.decode($res.body));
}

/**
 * The GitHub identity provider.
 * @return {identity.Provider} the vtable; every call takes an `identity.Config`
 */
export func provider() {
    return identity.Provider{
        name: "github",
        flow: flowOf,
        startDevice: start,
        poll: pollOnce,
        authorizeUrl: authorize,
        exchangeCode: exchange,
        subject: subjectOf
    };
}
