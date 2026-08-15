# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * GitLab as an identity provider, hosted or self-hosted: the two differ only in
 * `baseUrl`, which is why there is one module rather than two
 * (specification 12.3).
 *
 * GitLab speaks standard OAuth 2.0, so the device-grant vocabulary is the one in
 * `identity.j`. Two things differ from the forge modules elsewhere: the user
 * endpoint is `/api/v4/user`, and GitLab calls the username `username` rather
 * than `login`.
 *
 * > **Unverified.** The device-grant endpoint path here is taken from GitLab's
 * > documented OAuth surface and has **not** been exercised against a live
 * > instance. Confirm it, and confirm that the instance has the device grant
 * > enabled at all, before relying on this module; `authcode` is the fallback.
 * @module gitlab
 * @example
 * import "./gitlab.j" as gitlab;
 * def p as identity.Provider init gitlab.provider();
 * def d as identity.Device init $p.startDevice($cfg);
 */

use json;
use strings;
use convert;
use encoding;
import "http.j" as http;
import "../identity.j" as identity;

def const TIMEOUT_MS as int init 10000;
def const MAX_BYTES as int init 65536;

# Gitea's default scope set. `read:user` is the only one the registry needs;
# organisation reads come later, with the org surface.
def const HOSTED_BASE as string init "https://gitlab.com";

# `read_user` is GitLab's spelling, with an underscore.
def const DEFAULT_SCOPES as string init "read_user";

func formField(name as string, value as string) {
    def raw as bytes init convert.bytesFromString($value, "utf-8");
    return $name + "=" + encoding.toText($raw, "uri-form");
}

func jsonHeaders() {
    def h as map of string to string init {};
    $h["Accept"] = "application/json";
    return $h;
}

func optInt(doc as json.Value, field as string, fallback as int) {
    if (json.has($doc, $field)) {
        return json.asInt($doc, $field);
    }
    return $fallback;
}

# baseFor falls back to gitlab.com, which unlike Gitea is a real hosted service
# a deployment may legitimately mean.
func baseFor(cfg as identity.Config) {
    if (strings.trim($cfg.baseUrl) == "") {
        return HOSTED_BASE;
    }
    return strings.trim($cfg.baseUrl);
}

/**
 * The endpoints this provider uses.
 * @param cfg {identity.Config} the provider configuration
 * @param which {string} "device", "token", "authorize", or "user"
 * @return {string} the absolute URL
 */
export func endpointFor(cfg as identity.Config, which as string) {
    def base as string init baseFor($cfg);
    match ($which) {
        when "device" {
            return identity.endpoint($base, $base, "/oauth/authorize_device");
        }
        when "token" {
            return identity.endpoint($base, $base, "/oauth/token");
        }
        when "authorize" {
            return identity.endpoint($base, $base, "/oauth/authorize");
        }
    }
    return identity.endpoint($base, $base, "/api/v4/user");
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

/**
 * Build a `Subject` from GitLab's `/api/v4/user` payload. Pure.
 * @param cfg {identity.Config} the provider configuration, for its name
 * @param doc {json.Value} the decoded response
 * @return {identity.Subject} the caller
 * @throws {Error} when the payload carries no id
 */
export func subjectFrom(cfg as identity.Config, doc as json.Value) {
    if (not json.has($doc, "/id")) {
        throw Error{
            kind: "identity",
            message: "the instance returned an account with no id",
            file: "", line: 0, col: 0
        };
    }
    def login as string init "";
    if (json.has($doc, "/username")) {
        $login = json.asString($doc, "/username");
    }
    def name as string init $cfg.name;
    if ($name == "") {
        $name = "gitlab";
    }
    return identity.Subject{
        provider: $name,
        id: convert.toString(json.asInt($doc, "/id")),
        login: $login
    };
}

/**
 * Build a `Device` from GitLab's device-code payload. Pure.
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
 * Build a `Poll` from GitLab's token payload. Pure.
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

func post(url as string, body as string) {
    def res as http.Response init http.requestWith("POST", $url, jsonHeaders(), $body,
        TIMEOUT_MS, MAX_BYTES);
    return json.decode($res.body);
}

func flowOf(cfg as identity.Config) {
    return "device";
}

func start(cfg as identity.Config) {
    def body as string init formField("client_id", $cfg.clientId) + "&" +
        formField("scope", scopesFor($cfg));
    return deviceFrom(post(endpointFor($cfg, "device"), $body));
}

func pollOnce(cfg as identity.Config, deviceCode as string) {
    def body as string init formField("client_id", $cfg.clientId) + "&" +
        formField("device_code", $deviceCode) + "&" +
        formField("grant_type", "urn:ietf:params:oauth:grant-type:device_code");
    return pollFrom(post(endpointFor($cfg, "token"), $body));
}

func authorize(cfg as identity.Config, state as string, challenge as string) {
    return endpointFor($cfg, "authorize") + "?" +
        formField("client_id", $cfg.clientId) + "&" +
        formField("response_type", "code") + "&" +
        formField("state", $state) + "&" +
        formField("code_challenge_method", "S256") + "&" +
        formField("code_challenge", $challenge);
}

func exchange(cfg as identity.Config, code as string, verifier as string) {
    def body as string init formField("client_id", $cfg.clientId) + "&" +
        formField("grant_type", "authorization_code") + "&" +
        formField("code", $code) + "&" +
        formField("code_verifier", $verifier);
    def doc as json.Value init post(endpointFor($cfg, "token"), $body);
    return json.asString($doc, "/access_token");
}

func subjectOf(cfg as identity.Config, accessToken as string) {
    def h as map of string to string init jsonHeaders();
    $h["Authorization"] = "Bearer " + $accessToken;
    def res as http.Response init http.requestWith("GET", endpointFor($cfg, "user"), $h,
        "", TIMEOUT_MS, MAX_BYTES);
    if (not ($res.status == 200)) {
        throw Error{
            kind: "identity",
            message: "the instance rejected the token: " + convert.toString($res.status),
            file: "", line: 0, col: 0
        };
    }
    return subjectFrom($cfg, json.decode($res.body));
}

/**
 * The GitLab identity provider.
 * @return {identity.Provider} the vtable; every call takes an `identity.Config`
 */
export func provider() {
    return identity.Provider{
        name: "gitlab",
        flow: flowOf,
        startDevice: start,
        poll: pollOnce,
        authorizeUrl: authorize,
        exchangeCode: exchange,
        subject: subjectOf
    };
}
