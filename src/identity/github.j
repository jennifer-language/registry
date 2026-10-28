# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * GitHub as an identity provider: the OAuth 2.0 device authorization grant
 * (RFC 8628), which the public registry runs (specification 12.7).
 *
 * The registry drives the flow; the client never talks to GitHub or holds a
 * GitHub token, so the OAuth application and its scopes stay here. The device
 * grant needs no client secret.
 *
 * Parsing (`subjectFrom` and friends) is separate from the requests, so it is
 * tested without a socket.
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
use time;
import "http.j" as http;
import "../identity.j" as identity;

# The hosted endpoints. A GitHub Enterprise instance overrides `baseUrl`, and
# the API is then addressed from the same root. Unverified: GitHub Enterprise
# Server documents its REST API under `https://HOST/api/v3/`, so a deployment
# may need that suffix in `baseUrl` for the API calls, which would then break
# the web endpoints. Test against an instance before relying on it.
def const WEB_BASE as string init "https://github.com";
def const API_BASE as string init "https://api.github.com";

def const TIMEOUT_MS as int init 10000;
def const MAX_BYTES as int init 65536;
# The token poll reads more: GitHub answers a spent device code with a 160 KB
# HTML error page, and only its status says what happened.
def const POLL_MAX_BYTES as int init 524288;

# The narrowest scopes that work (specification 8.6): the account's id and login,
# and organisation membership. No `repo` scope, since decks are public.
def const DEFAULT_SCOPES as string init "read:user read:org";

# Retries on a GitHub 5xx and the delay between them; small, because a person is
# waiting on the request.
def const RETRY_TRIES as int init 3;
def const RETRY_DELAY_MS as int init 400;

# getRetrying issues a GET and retries a 5xx a couple of times. The device code
# is already spent when the account is read, so a transient 503 would otherwise
# cost the person the whole flow. A 4xx is a real answer and is not retried.
func getRetrying(url as string, headers as map of string to string) {
    def res as http.Response init http.requestWith(
        "GET",
        $url,
        $headers,
        "",
        TIMEOUT_MS,
        MAX_BYTES);
    def attempt as int init 1;
    while ($res.status >= 500 and $attempt < RETRY_TRIES) {
        time.sleep(time.fromMilliseconds(RETRY_DELAY_MS * $attempt));
        $res = http.requestWith("GET", $url, $headers, "", TIMEOUT_MS, MAX_BYTES);
        $attempt = $attempt + 1;
    }
    return $res;
}

# formField encodes one form-urlencoded pair.
func formField(name as string, value as string) {
    def raw as bytes init convert.bytesFromString($value, "utf-8");
    return $name + "=" + encoding.toText($raw, "uri-form");
}

# jsonHeaders asks GitHub for JSON; the OAuth endpoints default to
# form-urlencoded.
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
 * Build a `Subject` from GitHub's `/user` payload. Pure.
 *
 * `id` is GitHub's numeric account id as text; `login` is a display label and
 * never authoritative (specification 8.1).
 * @param doc {json.Value} the decoded `/user` response
 * @return {identity.Subject} the caller
 * @throws {Error} when the payload carries no id
 */
export func subjectFrom(doc as json.Value) {
    if (not json.has($doc, "/id")) {
        throw Error{
            kind: "identity",
            message: "GitHub returned an account with no id",
            file: "",
            line: 0,
            col: 0
        };
    }
    def login as string init "";
    if (json.has($doc, "/login")) {
        $login = json.asString($doc, "/login");
    }
    return identity.Subject{
        provider: "github",
        id: convert.toString(json.asInt($doc, "/id")),
        login: $login,
        orgs: {},
        orgsCheckedAt: ""
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
            file: "",
            line: 0,
            col: 0
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
        return identity.Poll{state: $state, accessToken: "", detail: $code};
    }
    return identity.Poll{
        state: identity.STATE_OK,
        accessToken: json.asString($doc, "/access_token"),
        detail: ""
    };
}

/**
 * Build a `Poll` from the token endpoint's raw answer. Pure.
 *
 * A 500 is what GitHub answers for a device code that was already exchanged
 * (observed 2026-10-28, an HTML page), so it is `STATE_SPENT`: polling again
 * cannot succeed. Any other 5xx, a body that is not JSON, or one with neither a
 * token nor an error throws, which the caller reports as a provider it could
 * not reach (502, retried by clients).
 * @param status {int} the HTTP status
 * @param body {string} the response body
 * @return {identity.Poll} the outcome
 * @throws {Error} kind "identity" for a provider fault worth retrying
 */
export func pollFromResponse(status as int, body as string) {
    if ($status == 500) {
        return identity.Poll{
            state: identity.STATE_SPENT,
            accessToken: "",
            detail: "GitHub answered HTTP 500"
        };
    }
    def answered as string init "GitHub answered HTTP " + convert.toString($status);
    if ($status > 500) {
        throw Error{kind: "identity", message: $answered};
    }
    def doc as json.Value;
    try {
        $doc = json.decode($body);
    } catch (err) {
        throw Error{kind: "identity", message: $answered + " without JSON"};
    }
    # Neither an error nor a token is not a login: issuing on it would bind an
    # empty provider token.
    if (not json.has($doc, "/error") and not hasText($doc, "/access_token")) {
        throw Error{kind: "identity", message: $answered + " with no token and no error"};
    }
    return pollFrom($doc);
}

# hasText reports whether a field is present as a non-empty string.
func hasText(doc as json.Value, field as string) {
    return json.has($doc, $field) and json.typeOf($doc, $field) == "string" and
        not (json.asString($doc, $field) == "");
}

/**
 * The organisation ids an account may act for, read from GitHub's memberships
 * payload. Pure.
 *
 * Two cases are excluded (8.7):
 *
 * - `state: "pending"` is an unaccepted invitation; counting it would let
 *   anyone who gets invited publish under the organisation's name.
 * - `role: "billing_manager"` is a finance role with no access to code.
 *
 * `admin` and `member` both count, this deployment's answer to 8.7's open
 * question; requiring `admin` would exclude most engineers who publish.
 * @param doc {json.Value} the decoded `/user/memberships/orgs` response
 * @return {map of string to string} folded organisation login -> numeric id
 */
export func membershipsFrom(doc as json.Value) {
    def out as map of string to string init {};
    if (not (json.typeOf($doc, "") == "list")) {
        return $out;
    }
    def n as int init json.length($doc, "");
    def i as int init 0;
    while ($i < $n) {
        def at as string init "/" + convert.toString($i);
        $i = $i + 1;
        if (not json.has($doc, $at + "/state")) {
            continue;
        }
        if (not (json.asString($doc, $at + "/state") == "active")) {
            continue;
        }
        if (json.has($doc, $at + "/role")) {
            if (json.asString($doc, $at + "/role") == "billing_manager") {
                continue;
            }
        }
        if (not json.has($doc, $at + "/organization/id")) {
            continue;
        }
        if (not json.has($doc, $at + "/organization/login")) {
            continue;
        }
        # Keyed by folded login (how a claim names it), valued by id (what
        # ownership binds to).
        def login as string init json.asString($doc, $at + "/organization/login");
        $out[strings.lower($login)] = convert.toString(json.asInt($doc, $at + "/organization/id"));
    }
    return $out;
}

/**
 * The endpoints this provider uses, given a configured base.
 * @param cfg {identity.Config} the provider configuration
 * @param which {string} "device", "token", "memberships", or "user" (the default)
 * @return {string} the absolute URL
 */
export func endpointFor(cfg as identity.Config, which as string) {
    match ($which) {
        when "device" { return identity.endpoint($cfg.baseUrl, WEB_BASE, "/login/device/code"); }
        when "token" {
            return identity.endpoint($cfg.baseUrl, WEB_BASE, "/login/oauth/access_token");
        }
    }
    if ($which == "memberships") {
        # Filtered to `active` by the API too, for fewer rows; `membershipsFrom`
        # still checks. One page of 100: an account in more organisations than
        # that has the rest silently left out.
        return identity.endpoint(
            $cfg.baseUrl,
            API_BASE,
            "/user/memberships/orgs?state=active&per_page=100");
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
    def res as http.Response init http.requestWith(
        "POST",
        $url,
        jsonHeaders(),
        $body,
        TIMEOUT_MS,
        MAX_BYTES);
    return json.decode($res.body);
}

# --- the Provider vtable ----------------------------------------------------

# discoverOf: GitHub's endpoints are fixed, so there is nothing to fetch.
func discoverOf(cfg as identity.Config) {
    return "";
}

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
    def res as http.Response init http.requestWith(
        "POST",
        endpointFor($cfg, "token"),
        jsonHeaders(),
        $body,
        TIMEOUT_MS,
        POLL_MAX_BYTES);
    return pollFromResponse($res.status, $res.body);
}

# authorize is unused: this provider runs the device flow.
func authorize(cfg as identity.Config) {
    return "";
}

# exchange is unused for the same reason.
func exchange(cfg as identity.Config, code as string, verifier as string, redirectUri as string) {
    return "";
}

# subjectOf reads the account a provider token belongs to.
func subjectOf(cfg as identity.Config, accessToken as string) {
    def h as map of string to string init jsonHeaders();
    $h["Authorization"] = "Bearer " + $accessToken;
    $h["User-Agent"] = "jennifer-registry";
    def res as http.Response init getRetrying(endpointFor($cfg, "user"), $h);
    if ($res.status >= 500) {
        # GitHub could not answer; say so, so nobody goes checking the token,
        # client id or scopes.
        throw Error{
            kind: "identity",
            message: "the GitHub API is unavailable (HTTP " +
                convert.toString($res.status) + " after " +
                convert.toString(RETRY_TRIES) + " attempts); the login can be " +
                "retried once it recovers",
            file: "",
            line: 0,
            col: 0
        };
    }
    if (not ($res.status == 200)) {
        throw Error{
            kind: identity.rejectionKind($res.status),
            message: "GitHub rejected the token: " + convert.toString($res.status),
            file: "",
            line: 0,
            col: 0
        };
    }
    return subjectFrom(json.decode($res.body));
}

# membershipsOf asks which organisations the token's owner actively belongs to.
# `membershipsFrom` decides which rows count. A failure yields no orgs instead
# of failing the login, so plain user logins never depend on this call; a
# transient failure then shows as "you may not write under @acme".
func membershipsOf(cfg as identity.Config, accessToken as string) {
    def h as map of string to string init jsonHeaders();
    $h["Authorization"] = "Bearer " + $accessToken;
    $h["User-Agent"] = "jennifer-registry";
    def none as map of string to string init {};
    def res as http.Response init getRetrying(endpointFor($cfg, "memberships"), $h);
    if (not ($res.status == 200)) {
        return $none;
    }
    return membershipsFrom(json.decode($res.body));
}

/**
 * The GitHub identity provider.
 * @return {identity.Provider} the vtable; every call takes an `identity.Config`
 */
export func provider() {
    return identity.Provider{
        name: "github",
        discover: discoverOf,
        flow: flowOf,
        startDevice: start,
        poll: pollOnce,
        authorizeUrl: authorize,
        exchangeCode: exchange,
        scopes: scopesFor,
        subject: subjectOf,
        memberships: membershipsOf
    };
}
