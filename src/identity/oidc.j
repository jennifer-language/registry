# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * A generic OpenID Connect identity provider, which is the one that matters
 * most: it covers **Authelia**, Keycloak, Dex, and anything else standards
 * compliant, without a module of its own. A bespoke provider is worth writing
 * only where a service deviates from the standard or offers something extra
 * (specification 12.2).
 *
 * Endpoints are read from the provider's **discovery document** at
 * `/.well-known/openid-configuration`, so a deployment configures a `baseUrl`
 * and nothing else. That is the whole reason to prefer OIDC over a hand-written
 * integration: the endpoints are self-describing.
 *
 * **The subject is the `sub` claim**, which is an opaque string rather than a
 * number, and is exactly what specification 8.1 means by a stable subject
 * identifier. The username, where the provider supplies one, comes from
 * `preferred_username` and is a display label only.
 *
 * > **Flow support varies.** The device grant is optional in OIDC. Authelia
 * > appears to implement it, since it carries a `device_code` lifespan setting,
 * > but its documentation does not enumerate grant types; other providers may
 * > offer only authorization code. This module advertises `device` when the
 * > discovery document lists the device endpoint and `authcode` otherwise, so
 * > the decision is taken from the provider rather than assumed.
 * @module oidc
 * @example
 * import "./oidc.j" as oidc;
 * def p as identity.Provider init oidc.provider();
 * def flow as string init $p.flow($cfg);
 */

use json;
use strings;
use convert;
use encoding;
import "http.j" as http;
import "../identity.j" as identity;

def const TIMEOUT_MS as int init 10000;
def const MAX_BYTES as int init 131072;

# The claims the registry needs: an identifier, and a username to show.
def const DEFAULT_SCOPES as string init "openid profile";

# The fixed path every OIDC provider serves its metadata from.
def const DISCOVERY_PATH as string init "/.well-known/openid-configuration";

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

func requireBase(cfg as identity.Config) {
    if (strings.trim($cfg.baseUrl) == "") {
        throw Error{
            kind: "identity",
            message: "the oidc provider needs a baseUrl to discover endpoints from",
            file: "", line: 0, col: 0
        };
    }
    return strings.trim($cfg.baseUrl);
}

/**
 * The URL of the provider's discovery document.
 * @param cfg {identity.Config} the provider configuration
 * @return {string} the absolute URL
 */
export func discoveryUrl(cfg as identity.Config) {
    def base as string init requireBase($cfg);
    return identity.endpoint($base, $base, DISCOVERY_PATH);
}

/**
 * Read one endpoint out of a fetched OIDC discovery document. Pure, so the
 * mapping is testable against a recorded document rather than a live provider.
 * @param doc {json.Value} the decoded discovery document
 * @param field {string} the metadata field, e.g. `token_endpoint`
 * @return {string} the URL, or "" when the provider does not advertise it
 */
export func endpointFrom(doc as json.Value, field as string) {
    if (not json.has($doc, "/" + $field)) {
        return "";
    }
    return json.asString($doc, "/" + $field);
}

/**
 * Which flow a provider supports, from its discovery document. Pure.
 *
 * `device` when the device endpoint is advertised, `authcode` otherwise. Taking
 * this from the document rather than assuming it is what lets one module serve
 * providers with different capabilities.
 * @param doc {json.Value} the decoded discovery document
 * @return {string} "device" or "authcode"
 */
export func flowFrom(doc as json.Value) {
    if (endpointFrom($doc, "device_authorization_endpoint") == "") {
        return "authcode";
    }
    return "device";
}

/**
 * Build a `Subject` from an OIDC `userinfo` payload. Pure.
 *
 * The `sub` claim is required by the standard, and is the only field this
 * registry treats as authoritative.
 * @param cfg {identity.Config} the provider configuration, for its name
 * @param doc {json.Value} the decoded userinfo response
 * @return {identity.Subject} the caller
 * @throws {Error} when the payload carries no `sub`
 */
export func subjectFrom(cfg as identity.Config, doc as json.Value) {
    if (not json.has($doc, "/sub")) {
        throw Error{
            kind: "identity",
            message: "the provider returned no `sub` claim, which OIDC requires",
            file: "", line: 0, col: 0
        };
    }
    def login as string init "";
    if (json.has($doc, "/preferred_username")) {
        $login = json.asString($doc, "/preferred_username");
    }
    def name as string init $cfg.name;
    if ($name == "") {
        $name = "oidc";
    }
    return identity.Subject{
        provider: $name,
        id: json.asString($doc, "/sub"),
        login: $login,
        orgs: [],
        orgsCheckedAt: ""
    };
}

/**
 * Build a `Device` from a device-authorization payload. Pure.
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
    # RFC 8628 names it verification_uri; some providers also send
    # verification_uri_complete, which carries the code already filled in.
    def uri as string init "";
    if (json.has($doc, "/verification_uri")) {
        $uri = json.asString($doc, "/verification_uri");
    }
    return identity.Device{
        deviceCode: json.asString($doc, "/device_code"),
        userCode: json.asString($doc, "/user_code"),
        verificationUri: $uri,
        expiresIn: optInt($doc, "/expires_in", 900),
        interval: optInt($doc, "/interval", 5)
    };
}

/**
 * Build a `Poll` from a token payload. Pure.
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

func scopesFor(cfg as identity.Config) {
    if (strings.trim($cfg.scopes) == "") {
        return DEFAULT_SCOPES;
    }
    return $cfg.scopes;
}

# metadata fetches and decodes the provider's discovery document.
func metadata(cfg as identity.Config) {
    def res as http.Response init http.requestWith("GET", discoveryUrl($cfg), jsonHeaders(),
        "", TIMEOUT_MS, MAX_BYTES);
    return json.decode($res.body);
}

func post(url as string, body as string) {
    def res as http.Response init http.requestWith("POST", $url, jsonHeaders(), $body,
        TIMEOUT_MS, MAX_BYTES);
    return json.decode($res.body);
}

func flowOf(cfg as identity.Config) {
    return flowFrom(metadata($cfg));
}

func start(cfg as identity.Config) {
    def url as string init endpointFrom(metadata($cfg), "device_authorization_endpoint");
    if ($url == "") {
        throw Error{
            kind: "identity",
            message: "this provider does not offer the device grant; use the authcode flow",
            file: "", line: 0, col: 0
        };
    }
    def body as string init formField("client_id", $cfg.clientId) + "&" +
        formField("scope", scopesFor($cfg));
    return deviceFrom(post($url, $body));
}

func pollOnce(cfg as identity.Config, deviceCode as string) {
    def body as string init formField("client_id", $cfg.clientId) + "&" +
        formField("device_code", $deviceCode) + "&" +
        formField("grant_type", "urn:ietf:params:oauth:grant-type:device_code");
    return pollFrom(post(endpointFrom(metadata($cfg), "token_endpoint"), $body));
}

func authorize(cfg as identity.Config, state as string, challenge as string) {
    return endpointFrom(metadata($cfg), "authorization_endpoint") + "?" +
        formField("client_id", $cfg.clientId) + "&" +
        formField("response_type", "code") + "&" +
        formField("scope", scopesFor($cfg)) + "&" +
        formField("state", $state) + "&" +
        formField("code_challenge_method", "S256") + "&" +
        formField("code_challenge", $challenge);
}

func exchange(cfg as identity.Config, code as string, verifier as string) {
    def body as string init formField("client_id", $cfg.clientId) + "&" +
        formField("grant_type", "authorization_code") + "&" +
        formField("code", $code) + "&" +
        formField("code_verifier", $verifier);
    def doc as json.Value init post(endpointFrom(metadata($cfg), "token_endpoint"), $body);
    return json.asString($doc, "/access_token");
}

func subjectOf(cfg as identity.Config, accessToken as string) {
    def url as string init endpointFrom(metadata($cfg), "userinfo_endpoint");
    def h as map of string to string init jsonHeaders();
    $h["Authorization"] = "Bearer " + $accessToken;
    def res as http.Response init http.requestWith("GET", $url, $h, "",
        TIMEOUT_MS, MAX_BYTES);
    if (not ($res.status == 200)) {
        throw Error{
            kind: "identity",
            message: "the provider rejected the token: " + convert.toString($res.status),
            file: "", line: 0, col: 0
        };
    }
    return subjectFrom($cfg, json.decode($res.body));
}

/**
 * The generic OIDC identity provider.
 * @return {identity.Provider} the vtable; every call takes an `identity.Config`
 */
export func provider() {
    return identity.Provider{
        name: "oidc",
        flow: flowOf,
        startDevice: start,
        poll: pollOnce,
        authorizeUrl: authorize,
        exchangeCode: exchange,
        subject: subjectOf,
        memberships: membershipsOf
    };
}
