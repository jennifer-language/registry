# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.28.0

/**
 * The forge interface (specification 12.3): repository contents and push
 * permission.
 *
 * Specification 12.4 allows one or more forges, matched against a version
 * record's `url`; this registry wires exactly one (`config.forge`), and
 * `handles` refuses a URL it does not claim. Each module under `forge/` exports
 * a `forge()` returning a `Forge`, a struct of `func` values.
 *
 * The shared types live here because a struct is identified by `(module, name)`.
 *
 * This module is pure. Each forge module keeps URL parsing and permission
 * interpretation separate from its HTTP call, so those are tested without a
 * socket; the API shapes are taken from documentation, not a live instance.
 * Every HTTP call goes through `outbound.request`, which counts it and logs a
 * failed one under the `Config.trace` it is given.
 * @module forge
 * @example
 * import "./forge/gitea.j" as gitea;
 * def f as forge.Forge init gitea.forge();
 * if ($f.handles($cfg, $url)) { def c as string init $f.resolveTag($cfg, $url, "v1"); }
 */

use json;
use strings;
use convert;
use encoding;
use regex;
import "uri.j" as uri;
import "./outbound.j" as outbound;

/**
 * Where a forge lives and how the registry talks to it.
 * @field name {string} the forge name ("github", "gitlab", "gitea")
 * @field baseUrl {string} the instance root, no trailing slash ("" = the module's default)
 * @field apiToken {string} a service token, where the deployment supplies one
 *     (specification 12.5); "" when the registry has no credential for this forge
 * @field host {string} the hostname whose URLs this instance claims ("" = the module's default)
 * @field trace {outbound.Trace} where the calls are counted and logged (`outbound.none()`
 *     outside a request)
 */
export def struct Config {
    name as string,
    baseUrl as string,
    apiToken as string,
    host as string,
    trace as outbound.Trace
};

/**
 * A repository, identified the way it survives renames.
 * @field id {string} the forge's immutable numeric repository id, as text
 * @field ownerId {string} the numeric id of the owning account, as text
 * @field owner {string} the owner's name, a display label only
 * @field name {string} the repository name, a display label only
 */
export def struct Repo {
    id as string,
    ownerId as string,
    owner as string,
    name as string
};

/**
 * Whether the caller may publish from a repository.
 * @field known {bool} false when the forge could not answer; specification 7.1
 *     requires an unanswerable check to be treated as unverified, never as granted
 * @field push {bool} true when the caller may push
 * @field reason {string} why, phrased for the person who will read it
 */
export def struct Permission {
    known as bool,
    push as bool,
    reason as string
};

/**
 * A forge, as a set of func values.
 *
 * Every function takes the `Config` as its first argument, since Jennifer has no
 * closures. `forge()` takes nothing and returns a vtable; the caller holds the
 * pair.
 * @field name {string} the forge name
 * @field handles {func} `func(Config, url) -> bool`: does this instance claim this URL?
 * @field resolveTag {func} `func(Config, url, tag) -> string`: the commit a tag points at
 * @field readFile {func} `func(Config, url, commit, path) -> string`: a file at a commit
 * @field refExists {func} `func(Config, url, name) -> bool`: is there a branch or
 *     tag of this name? Used to detect a ref standing in front of the commit it
 *     is named after (see `refPresence`)
 * @field fileExists {func} `func(Config, url, commit, path) -> bool`: is there a
 *     file at this path at that commit? GitHub and Gitea ask the contents API
 *     for the path itself (`isFile`), GitLab asks with a `HEAD`; throws when
 *     the forge will not say
 * @field permission {func} `func(Config, url, callerToken) -> Permission`: may they push?
 *     Asked with the caller's own token, where identity and forge are one service. A forge
 *     that answers with a rate limit throws a `ForgeError` (so does `permissionFor`):
 *     it says nothing about access
 * @field permissionFor {func} `func(Config, url, username) -> Permission`: may this
 *     forge user push? Asked with the registry's own token (`Config.apiToken`),
 *     where identity and forge are different services (12.5)
 * @field repo {func} `func(Config, url) -> Repo`: the immutable identity of a repository
 * @field account {func} `func(Config, username) -> Account`: the account with exactly
 *     this username, or `noAccount()`; throws when the forge will not say (12.5)
 * @field accountById {func} `func(Config, id) -> Account`: the account with this
 *     immutable id and its current username, or `noAccount()`; throws likewise
 */
export def struct Forge {
    name as string,
    handles as func,
    resolveTag as func,
    readFile as func,
    refExists as func,
    fileExists as func,
    permission as func,
    permissionFor as func,
    repo as func,
    account as func,
    accountById as func
};

/**
 * A forge account (12.5): the immutable id a link is recorded by, and the
 * username it has now.
 * @field id {string} the forge's immutable numeric account id, as text; "" for none
 * @field login {string} the current username
 */
export def struct Account {
    id as string,
    login as string
};

/**
 * No account.
 * @return {Account} an account with an empty id
 */
export func noAccount() {
    return Account{id: "", login: ""};
}

/**
 * Read one user payload as an `Account`. Pure. GitHub and Gitea name the
 * username `login`, GitLab `username`.
 * @param doc {json.Value} the decoded user object
 * @param loginField {string} the member holding the username
 * @return {Account} the account, or `noAccount()` when a field is missing
 */
export func accountFrom(doc as json.Value, loginField as string) {
    if (not (json.typeOf($doc, "") == "map") or not json.has($doc, "/id") or
        not json.has($doc, "/" + $loginField)) {
        return noAccount();
    }
    return Account{
        id: convert.toString(json.asInt($doc, "/id")),
        login: json.asString($doc, "/" + $loginField)
    };
}

/**
 * The first account of a list payload whose username equals `username`,
 * ignoring case (GitLab's `GET /users?username=`, Gitea's search `data`), or
 * any first account when `username` is "". Pure.
 * @param doc {json.Value} the decoded list
 * @param loginField {string} the member holding the username
 * @param username {string} the username wanted, or "" for the first entry
 * @return {Account} the account, or `noAccount()`
 */
export func accountFromList(doc as json.Value, loginField as string, username as string) {
    if (not (json.typeOf($doc, "") == "list")) {
        return noAccount();
    }
    for (def i in 0..json.length($doc, "")) {
        def a as Account init accountFrom(json.get($doc, "/" + convert.toString($i)), $loginField);
        if (not ($a.id == "") and
            ($username == "" or strings.lower($a.login) == strings.lower($username))) {
            return $a;
        }
    }
    return noAccount();
}

/**
 * The forge account an identity maps onto (12.5): the one the forge found for
 * the username the identity provider asserted, accepted only when the forge
 * reports that same username back (ignoring case). Never a display name. Pure.
 * @param asserted {string} the username the identity provider asserted
 * @param found {Account} what `Forge.account` answered for it
 * @return {Account} the agreed account, or `noAccount()`
 */
export func agreedAccount(asserted as string, found as Account) {
    if ($found.id == "" or $asserted == "" or
        not (strings.lower($found.login) == strings.lower($asserted))) {
        return noAccount();
    }
    return $found;
}

/**
 * Whether `id` is a forge account id: decimal digits only, so it is safe in a
 * request path. Pure.
 * @param id {string} the candidate
 * @return {bool} true for 1 to 18 digits
 */
export func isAccountId(id as string) {
    if (len($id) == 0 or len($id) > 18) {
        return false;
    }
    for (def ch in strings.chars($id)) {
        if ($ch < "0" or $ch > "9") {
            return false;
        }
    }
    return true;
}

/**
 * The error kind a forge read throws for a thing the forge says is not there
 * (404): a tag that was never pushed, a file absent at the commit. It is the
 * publisher's to fix, so a publish answers it with 400 rather than the 503 of a
 * forge that failed. A private repository the registry cannot see answers 404
 * too, so messages say "not found", never "does not exist".
 */
export def const ABSENT as string init "absent";

/**
 * The kind of error a failed forge read throws: `ABSENT` for 404, else "forge".
 * @param status {int} the HTTP status the forge answered with
 * @return {string} the error kind
 */
export func kindOf(status as int) {
    if ($status == 404) {
        return ABSENT;
    }
    return "forge";
}

/**
 * What a forge read throws when the forge answered, or would not be asked:
 * every error of kind `ABSENT` or "forge" is one of these, so its fields are
 * safe to read once the kind matches.
 * @field kind {string} `ABSENT` or "forge"
 * @field message {string} what failed, for the publisher and the operator
 * @field status {int} the HTTP status the forge answered with; 0 when it was not asked
 * @field retryAfter {int} seconds until the forge will answer again when it
 *     refused for a rate limit (`rateLimitWait`), else 0
 * @field credential {string} whose token the request carried: `REGISTRY_CRED`
 *     (the registry's own `Config.apiToken`), `CALLER_CRED` (the publisher's,
 *     in a permission check), or "" (none)
 * @field said {string} the forge's own error message (`saidBy`), "" when none
 */
export def struct ForgeError {
    kind as string,
    message as string,
    status as int,
    retryAfter as int,
    credential as string,
    said as string
};

/** `ForgeError.credential` when the request carried the registry's own token. */
export def const REGISTRY_CRED as string init "registry";
/** `ForgeError.credential` when it carried the publisher's token. */
export def const CALLER_CRED as string init "caller";

/**
 * Whose token a request carries: the caller's when one is given (a permission
 * check asks with it), else the registry's own when configured, else none.
 * Every adapter picks its `Authorization` header the same way. Pure.
 * @param cfg {Config} the forge configuration
 * @param callerToken {string} the caller's token, or ""
 * @return {string} `CALLER_CRED`, `REGISTRY_CRED`, or ""
 */
export func credentialOf(cfg as Config, callerToken as string) {
    if (not ($callerToken == "")) {
        return CALLER_CRED;
    }
    if (not (strings.trim($cfg.apiToken) == "")) {
        return REGISTRY_CRED;
    }
    return "";
}

/**
 * The forge's own error message from a JSON error body (`outbound.messageOf`:
 * at most 200 characters), with every control character made a space so it can
 * go into a reply, and "" if it contains `secret`, so a forge echoing the token
 * it was sent cannot hand it on. Pure.
 * @param body {string} the response body
 * @param secret {string} the token the request carried, or ""
 * @return {string} the message, or ""
 */
export func saidBy(body as string, secret as string) {
    def said as string init outbound.messageOf($body);
    if (not (strings.trim($secret) == "") and strings.contains($said, strings.trim($secret))) {
        return "";
    }
    def out as list of string init [];
    for (def c in strings.chars($said)) {
        def cp as int init convert.toCodepoint($c);
        if ($cp < 32 or ($cp >= 127 and $cp < 160) or $cp == 8232 or $cp == 8233) {
            $out[] = " ";
        } else {
            $out[] = $c;
        }
    }
    return strings.trim(strings.join($out, ""));
}

/**
 * The error for a forge answer that is not the one wanted, with whose token
 * was refused and what the forge said. Pure.
 * @param status {int} the HTTP status
 * @param headers {map of string to string} the response headers, keys lowercased
 * @param body {string} the response body (only its error message is kept)
 * @param credential {string} whose token the request carried (`credentialOf`)
 * @param secret {string} that token, so it is never kept (`saidBy`)
 * @param message {string} what failed
 * @param now {int} the current time (Unix seconds)
 * @return {ForgeError} kind `kindOf(status)`, with `retryAfter` set for a rate limit
 */
export func answered(
    status as int,
    headers as map of string to string,
    body as string,
    credential as string,
    secret as string,
    message as string,
    now as int) {
    return ForgeError{
        kind: kindOf($status),
        message: $message,
        status: $status,
        retryAfter: rateLimitWait($status, $headers, $now),
        credential: $credential,
        said: saidBy($body, $secret)
    };
}

/**
 * Whether a forge refused the registry's own token: a `401` or `403` that is
 * not a rate limit, on a request made with `Config.apiToken`. The request was
 * fine and the registry is misconfigured (an expired token, or one an
 * organisation's policy forbids), so a publish is a 503 that says so. Pure.
 * @param e {ForgeError} the error
 * @return {bool} true when the registry's credential was refused
 */
export func credentialRefused(e as ForgeError) {
    return ($e.status == 401 or $e.status == 403) and $e.retryAfter == 0 and
        $e.credential == REGISTRY_CRED;
}

/**
 * The error for a forge answer that is not the one wanted. Pure.
 * @param status {int} the HTTP status
 * @param headers {map of string to string} the response headers, keys lowercased
 * @param message {string} what failed
 * @param now {int} the current time (Unix seconds)
 * @return {ForgeError} kind `kindOf(status)`, with `retryAfter` set for a rate limit
 */
export func failure(
    status as int,
    headers as map of string to string,
    message as string,
    now as int) {
    return answered($status, $headers, "", "", "", $message, $now);
}

/**
 * The error for a forge that was not asked (no base URL, no token to ask with).
 * @param message {string} why
 * @return {ForgeError} kind "forge", status 0
 */
export func complaint(message as string) {
    return ForgeError{
        kind: "forge",
        message: $message,
        status: 0,
        retryAfter: 0,
        credential: "",
        said: ""
    };
}

# The wait assumed for a rate limit that names no time, and the longest one
# passed on: GitHub's primary window is an hour.
def const DEFAULT_WAIT as int init 60;
def const MAX_WAIT as int init 3600;

/**
 * Seconds until a forge that refused for a rate limit will answer again, or 0
 * when the answer is not a rate limit. Pure.
 *
 * GitHub answers a spent primary limit with `403` or `429` and
 * `x-ratelimit-remaining: 0` (wait until `x-ratelimit-reset`, Unix seconds),
 * and a secondary limit with `retry-after` (seconds). A `403` with neither is
 * a refusal, not a limit. A `429` is a limit on every forge: GitLab sends
 * `retry-after` and `ratelimit-reset`, Gitea and Forgejo `retry-after` when
 * they send anything. The result is between 1 and an hour.
 * @param status {int} the HTTP status
 * @param headers {map of string to string} the response headers, keys lowercased
 * @param now {int} the current time (Unix seconds)
 * @return {int} the wait in seconds, or 0
 */
export func rateLimitWait(status as int, headers as map of string to string, now as int) {
    if (not ($status == 403 or $status == 429)) {
        return 0;
    }
    def after as int init secondsIn($headers, "retry-after");
    if ($after >= 0) {
        return clampWait($after);
    }
    def spent as bool init headerOf($headers, "x-ratelimit-remaining") == "0" or
        headerOf($headers, "ratelimit-remaining") == "0";
    if ($spent or $status == 429) {
        for (def name in ["x-ratelimit-reset", "ratelimit-reset"]) {
            def reset as int init secondsIn($headers, $name);
            if ($reset > 0) {
                return clampWait($reset - $now);
            }
        }
        return DEFAULT_WAIT;
    }
    return 0;
}

func clampWait(seconds as int) {
    if ($seconds < 1) {
        return 1;
    }
    if ($seconds > MAX_WAIT) {
        return MAX_WAIT;
    }
    return $seconds;
}

func headerOf(headers as map of string to string, name as string) {
    for (def k in $headers) {
        if ($k == $name) {
            return strings.trim($headers[$k]);
        }
    }
    return "";
}

# secondsIn reads a header holding a non-negative integer, or -1. An HTTP-date
# `retry-after` is not read: the forges named above send seconds.
func secondsIn(headers as map of string to string, name as string) {
    def v as string init headerOf($headers, $name);
    if ($v == "" or len($v) > 12) {
        return -1;
    }
    for (def ch in strings.chars($v)) {
        if ($ch < "0" or $ch > "9") {
            return -1;
        }
    }
    return convert.toInt($v);
}

/**
 * Turn a forge's answer about one ref into presence, or refuse to guess.
 *
 * `200` is present and `404` is absent; anything else throws a `ForgeError`.
 * The check finds a ref shadowing a commit of the same name, so reading an
 * unanswerable question as "no such ref" would fail open (same rule as
 * `unknown`, specification 7.1).
 * @param status {int} the HTTP status the forge answered with
 * @param headers {map of string to string} the response headers, keys lowercased
 * @param now {int} the current time (Unix seconds)
 * @return {bool} true when the ref exists, false when it provably does not
 */
export func refPresence(status as int, headers as map of string to string, now as int) {
    if ($status == 200) {
        return true;
    }
    if ($status == 404) {
        return false;
    }
    throw failure(
        $status,
        $headers,
        "could not tell whether the repository has a ref of that name: " +
            "the forge answered " + convert.toString($status),
        $now);
}

/**
 * The answer when a forge cannot say; distinct from a refusal.
 * @param reason {string} why the check could not be made
 * @return {Permission} an unknown permission
 */
export func unknown(reason as string) {
    return Permission{known: false, push: false, reason: $reason};
}

/**
 * The answer when a forge says yes.
 * @param reason {string} why access was granted
 * @return {Permission} a granting permission
 */
export func granted(reason as string) {
    return Permission{known: true, push: true, reason: $reason};
}

/**
 * The answer when a forge says no.
 * @param reason {string} why access was refused
 * @return {Permission} a refusing permission
 */
export func refused(reason as string) {
    return Permission{known: true, push: false, reason: $reason};
}

/**
 * The host part of a URL, lowercased, with any userinfo and port removed.
 * Returns "" when the URL has no recognisable host (`file://`, a plain path), so
 * no forge handles it.
 * @param url {string} the repository URL
 * @return {string} the hostname, or ""
 */
export func hostOf(url as string) {
    def rest as string init strings.trim($url);
    def scheme as int init strings.indexOf($rest, "://");
    if ($scheme < 0) {
        return "";
    }
    $rest = $rest[$scheme + 3..len($rest)];
    def slash as int init strings.indexOf($rest, "/");
    if ($slash >= 0) {
        $rest = $rest[..$slash];
    }
    def at as int init strings.indexOf($rest, "@");
    if ($at >= 0) {
        $rest = $rest[$at + 1..len($rest)];
    }
    def colon as int init strings.indexOf($rest, ":");
    if ($colon >= 0) {
        $rest = $rest[..$colon];
    }
    return strings.lower($rest);
}

/**
 * The `owner/name` path of a repository URL, with any `.git` suffix and
 * surrounding slashes removed. Returns "" when the URL does not carry one.
 *
 * Deeper paths are preserved for GitLab's nested groups:
 * `https://gitlab.com/group/sub/project.git` yields `group/sub/project`.
 * @param url {string} the repository URL
 * @return {string} the repository path, or ""
 */
export func pathOf(url as string) {
    def rest as string init strings.trim($url);
    def scheme as int init strings.indexOf($rest, "://");
    if ($scheme < 0) {
        return "";
    }
    $rest = $rest[$scheme + 3..len($rest)];
    def slash as int init strings.indexOf($rest, "/");
    if ($slash < 0) {
        return "";
    }
    $rest = $rest[$slash + 1..len($rest)];
    # The slash first: `o/r.git/` must read as `o/r`, not as `o/r.git`.
    if (strings.endsWith($rest, "/")) {
        $rest = $rest[..len($rest) - 1];
    }
    if (strings.endsWith($rest, ".git")) {
        $rest = $rest[..len($rest) - 4];
    }
    return $rest;
}

/**
 * Why a repository URL cannot be published from, or "" when it can. Pure.
 *
 * Adapters build API calls from the configured base URL and `pathOf(url)` only,
 * while the whole URL is recorded and handed to clients. Anything the adapters
 * do not read would let the two disagree, so userinfo, query, fragment and
 * misleading path segments (`..`, an encoded `/`) are refused before any request,
 * and so is an authority `uri.parse` rejects (a port that is not 0-65535, an
 * unclosed `[`). The host is judged by `Forge.handles`.
 * @param url {string} the repository URL from the request
 * @return {string} the complaint, or ""
 */
export func repositoryProblem(url as string) {
    def raw as string init strings.trim($url);
    if ($raw == "") {
        return "missing `repository`";
    }
    if (malformedAuthority($raw)) {
        return MALFORMED_AUTHORITY;
    }
    def u as uri.Uri init uri.parse($raw);
    if (not ($u.scheme == "https" or $u.scheme == "http")) {
        return "the repository must be an http or https URL";
    }
    if (not ($u.user == "") or not ($u.query == "") or not ($u.fragment == "") or
        strings.contains($raw, "#") or strings.contains($raw, "?")) {
        return "the repository URL must not carry credentials, a query, or a fragment";
    }
    def segments as list of string init strings.split(pathOf($raw), "/");
    if (len($segments) < 2) {
        return "the repository URL must name an owner and a repository";
    }
    for (def seg in $segments) {
        if (not isPathSegment($seg)) {
            return "the repository path has an invalid segment `" + $seg + "`";
        }
    }
    return "";
}

/**
 * Why a repository URL does not address the forge the way the forge is
 * configured, or "". Reads go to the configured API but clients clone from the
 * recorded URL, so a scheme or port the forge does not serve on
 * (`http://github.com/...`, `https://github.com:8080/...`) would send clients
 * somewhere unchecked. Plain http and an explicit port are accepted only where
 * the configured base URL uses them.
 * @param url {string} the repository URL, already past `repositoryProblem`
 * @param baseUrl {string} the forge's configured base URL ("" for the hosted one)
 * @return {string} the complaint, or "" when the URL is acceptable
 */
export func originProblem(url as string, baseUrl as string) {
    if (malformedAuthority(strings.trim($url))) {
        return MALFORMED_AUTHORITY;
    }
    def u as uri.Uri init uri.parse(strings.trim($url));
    def scheme as string init "https";
    def port as string init "";
    if (not (strings.trim($baseUrl) == "")) {
        if (malformedAuthority(strings.trim($baseUrl))) {
            return "the forge's configured base URL has a malformed host or port, so " +
                "no repository URL can be checked against it";
        }
        def b as uri.Uri init uri.parse(strings.trim($baseUrl));
        $scheme = strings.lower($b.scheme);
        $port = $b.port;
    }
    if (not (strings.lower($u.scheme) == $scheme)) {
        return "the repository URL must be " + $scheme + "://, as the forge is";
    }
    if (not ($u.port == $port)) {
        return "the repository URL names a port the forge is not configured on";
    }
    return "";
}

def const MALFORMED_AUTHORITY as string init "the repository URL has a malformed host or port";

/**
 * Whether a URL's host and port cannot be read unambiguously: `uri.parse` throws
 * kind "uri" (a port that is not 0-65535, an unclosed `[`, text after an IP
 * literal's `]`), or, on interpreters whose `uri.parse` is lenient, the parts it
 * returns do not spell the authority as written. A URL without `//` has no
 * authority and is judged elsewhere. Pure; `deckadmin add` shares it.
 * @param raw {string} the URL, already trimmed
 * @return {bool} true when the authority is malformed
 */
export func malformedAuthority(raw as string) {
    def u as uri.Uri;
    try {
        $u = uri.parse($raw);
    } catch (err) {
        if ($err.kind == "uri") {
            return true;
        }
        throw $err;
    }
    def start as int init strings.indexOf($raw, "://");
    if ($start < 0) {
        return false;
    }
    def auth as string init $raw[$start + 3..len($raw)];
    for (def stop in ["/", "?", "#"]) {
        def at as int init strings.indexOf($auth, $stop);
        if ($at >= 0) {
            $auth = $auth[..$at];
        }
    }
    def userEnd as int init strings.lastIndexOf($auth, "@");
    if ($userEnd >= 0) {
        $auth = $auth[$userEnd + 1..len($auth)];
    }
    def spelled as string init $u.host;
    if (not ($u.port == "")) {
        if (not regex.matches('^[0-9]{1,5}$', $u.port) or convert.toInt($u.port) > 65535) {
            return true;
        }
        $spelled = $spelled + ":" + $u.port;
    }
    if (strings.startsWith($u.host, "[") and not strings.endsWith($u.host, "]")) {
        return true;
    }
    return not (strings.lower($auth) == strings.lower($spelled));
}

/**
 * Whether a string is safe to place as one segment of a forge API path: letters,
 * digits, `.`, `_`, `-`, and not a dot segment. Pure. Owners, repository names
 * and usernames fit this on every supported forge; `%` is refused so an encoded
 * `/` or `..` cannot reach a forge that decodes before routing.
 * @param seg {string} the candidate segment
 * @return {bool} true when it can be placed in a path as it is
 */
export func isPathSegment(seg as string) {
    if ($seg == "" or $seg == "." or $seg == "..") {
        return false;
    }
    for (def c in strings.chars($seg)) {
        if (not (($c >= "a" and $c <= "z") or ($c >= "A" and $c <= "Z") or
            ($c >= "0" and $c <= "9") or $c == "." or $c == "_" or $c == "-")) {
            return false;
        }
    }
    return true;
}

/**
 * Whether a contents payload describes an ordinary file, as GitHub and Gitea
 * answer `GET .../contents/<path>`: one object carrying `type`. Pure.
 *
 * A directory answers with a list, which is not a file; a submodule or symlink
 * carries another `type`. Only `kind` counts (`file` on both).
 * @param doc {json.Value} the decoded response
 * @param kind {string} the type an ordinary file carries on this forge
 * @return {bool} true when the path is a file
 */
export func isFile(doc as json.Value, kind as string) {
    if (not (json.typeOf($doc, "") == "map") or not json.has($doc, "/type")) {
        return false;
    }
    return json.typeOf($doc, "/type") == "string" and json.asString($doc, "/type") == $kind;
}

/**
 * One path segment percent-encoded for a request target (RFC 3986), `/`
 * included, so a tag or path can only address the segment it is placed in.
 * @param s {string} the raw segment
 * @return {string} the encoded segment
 */
export func encodeSegment(s as string) {
    return encoding.toText("uri-percent", encoding.encode("utf-8", $s));
}

/**
 * A slash-separated name percent-encoded segment by segment, for a forge that
 * routes a tag such as `release/v2` by its literal slashes.
 * @param s {string} the raw name
 * @return {string} the encoded name, slashes kept
 */
export func encodeSegments(s as string) {
    def parts as list of string init [];
    for (def part in strings.split($s, "/")) {
        $parts[] = encodeSegment($part);
    }
    return strings.join($parts, "/");
}

/**
 * Why a tag cannot be published, or "" when it can. Pure.
 *
 * The tag is placed into forge API paths and must not change which path it
 * addresses. Git's ref-name rules refuse most of that (`..`, whitespace, control
 * characters, `?`, `[`, `\`); `%` and `#` are legal in git but would be decoded
 * or cut off on the way to a forge, so they are refused too, as is anything
 * outside printable ASCII and the URL delimiters a forge might read. An inner
 * `/` is allowed. Adapters percent-encode the tag as well; this grammar is the
 * first guard, not the only one.
 * @param tag {string} the tag named in the request
 * @return {string} the complaint, or ""
 */
# The characters a tag may not carry: git's own refusals, then the URL
# delimiters (`;&=,` and the sub-delims) a forge could read as structure.
def const TAG_REFUSED as string init "~^:?*[\\%#;&=,'\"<>|\{\}`";

export func tagProblem(tag as string) {
    if (strings.trim($tag) == "") {
        return "missing `tag`";
    }
    if (strings.contains($tag, "..") or strings.contains($tag, "//") or
        strings.startsWith($tag, "/") or strings.endsWith($tag, "/") or
        strings.startsWith($tag, ".") or strings.endsWith($tag, ".") or
        strings.endsWith($tag, ".lock") or strings.contains($tag, '@{') or
        strings.contains($tag, "/.")) {
        return "the tag " + $tag + " is not a valid git tag name";
    }
    for (def c in strings.chars($tag)) {
        def cp as int init convert.toCodepoint($c);
        if ($cp <= 32 or $cp >= 127 or strings.contains(TAG_REFUSED, $c)) {
            return "the tag " + $tag + " contains a character a tag cannot carry here";
        }
    }
    return "";
}

/**
 * Read a forge's name for a collaborator's role as a push permission. Pure.
 *
 * GitHub's legacy `permission` field and Gitea's both answer with a role name.
 * Roles are listed explicitly both ways; anything else is unknown, so a role a
 * forge adds later is refused until someone classifies it.
 * @param role {string} the role, such as `write` or `read`
 * @return {Permission} granted, refused, or unknown
 */
export func permissionFromRole(role as string) {
    def r as string init strings.lower(strings.trim($role));
    if ($r == "owner" or $r == "admin" or $r == "maintain" or $r == "write") {
        return granted("the forge account has the " + $r + " role");
    }
    if ($r == "read" or $r == "triage" or $r == "none") {
        return refused("the forge account has the " + $r +
            " role, which cannot push to this repository");
    }
    return unknown("the forge reported a role it was not expected to: `" + $r + "`");
}

/**
 * Read a collaborator-permission payload as a push permission. Pure. GitHub's
 * and Gitea's `GET /repos/{owner}/{repo}/collaborators/{user}/permission` both
 * answer `{"permission": "<role>", ...}`.
 * @param doc {json.Value} the decoded response
 * @return {Permission} granted, refused, or unknown
 */
export func collaboratorPermissionFrom(doc as json.Value) {
    if (not json.has($doc, "/permission")) {
        return unknown("the forge returned no permission for this account");
    }
    return permissionFromRole(json.asString($doc, "/permission"));
}

/**
 * Why a forge account cannot be asked about, or "" when it can. Pure. Shared by
 * every adapter's `permissionFor`.
 * @param cfg {Config} the forge configuration
 * @param username {string} the account to ask about
 * @return {string} the reason, or ""
 */
export func askProblem(cfg as Config, username as string) {
    if (strings.trim($cfg.apiToken) == "") {
        return "the registry holds no forge token to ask with";
    }
    if (not isPathSegment($username)) {
        return "`" + $username + "` is not a forge username the registry can ask about";
    }
    return "";
}

