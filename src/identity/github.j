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
use time;
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

# How hard to try when GitHub answers with a 5xx, and how long to wait between
# attempts. Small numbers: this runs inside a request a person is waiting on.
def const RETRY_TRIES as int init 3;
def const RETRY_DELAY_MS as int init 400;

# getRetrying issues a GET and retries a **5xx** a couple of times.
#
# This exists because of where the call sits. A device code is single use: by the
# time the registry resolves the account, the person has already approved at
# GitHub and their code is spent. Failing there on a transient 503 costs them the
# whole flow and they have to start again - so a blip that lasts a second should
# not be the end of it.
#
# Only 5xx is retried. A 401 or 403 is a real answer and repeating it would just
# be a slower failure, and a louder one from the point of view of GitHub.
func getRetrying(url as string, headers as map of string to string) {
    def res as http.Response init http.requestWith("GET", $url, $headers, "",
        TIMEOUT_MS, MAX_BYTES);
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
 * The organisation ids an account may act for, read from GitHub's memberships
 * payload. **Pure**, so the two exclusions below have tests rather than comments.
 *
 * Two states are not membership, and 8.7 makes both non-negotiable:
 *
 * - **`state: "pending"`** is an invitation nobody accepted. Treating it as
 *   membership would let anyone who can get themselves invited publish under an
 *   organisation's name before a human agreed to it.
 * - **`role: "billing_manager"`** is a finance role with no relationship to
 *   code. It can see invoices; it has no business shipping a release.
 *
 * Everything else - `admin` and `member` - counts, which is this deployment's
 * answer to 8.7's open question. It is the practical end of the range: requiring
 * `admin` would exclude most of the engineers who actually publish.
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
        # Keyed by the folded login, because that is how a claim names it, and
        # valued by the id, because that is what ownership binds to.
        $out[strings.lower(json.asString($doc, $at + "/organization/login"))] =
            convert.toString(json.asInt($doc, $at + "/organization/id"));
    }
    return $out;
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
    if ($which == "memberships") {
        # `active` only, from the API rather than filtered here as well: fewer
        # rows over the wire, and the pure filter above still rejects anything
        # that slips through.
        return identity.endpoint($cfg.baseUrl, API_BASE,
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
    def res as http.Response init getRetrying(endpointFor($cfg, "user"), $h);
    if ($res.status >= 500) {
        # Not a rejection: GitHub could not answer. Worth saying so in those
        # words, because "rejected the token" sends whoever reads it looking at
        # the token, the client id, and the scopes - none of which are at fault.
        throw Error{
            kind: "identity",
            message: "the GitHub API is unavailable (HTTP " +
                convert.toString($res.status) + " after " +
                convert.toString(RETRY_TRIES) + " attempts); the login can be " +
                "retried once it recovers",
            file: "", line: 0, col: 0
        };
    }
    if (not ($res.status == 200)) {
        throw Error{
            kind: "identity",
            message: "GitHub rejected the token: " + convert.toString($res.status),
            file: "", line: 0, col: 0
        };
    }
    return subjectFrom(json.decode($res.body));
}

# membershipsOf asks which organisations the token's owner actively belongs to.
# The one network call; the decision about which rows count is `membershipsFrom`.
# A failure is **not** fatal to a login: an account with no organisation
# memberships and an account whose memberships could not be read look the same
# from here, and refusing the login would make an org-scope feature break plain
# user logins. The cost is that a transient failure silently yields no orgs,
# which shows up as "you may not write under @acme" rather than as an outage.
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
        flow: flowOf,
        startDevice: start,
        poll: pollOnce,
        authorizeUrl: authorize,
        exchangeCode: exchange,
        subject: subjectOf,
        memberships: membershipsOf
    };
}
