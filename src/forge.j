# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

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
 * @module forge
 * @example
 * import "./forge/gitea.j" as gitea;
 * def f as forge.Forge init gitea.forge();
 * if ($f.handles($cfg, $url)) { def c as string init $f.resolveTag($cfg, $url, "v1"); }
 */

use json;
use strings;
use convert;
import "uri.j" as uri;

/**
 * Where a forge lives and how the registry talks to it.
 * @field name {string} the forge name ("github", "gitlab", "gitea")
 * @field baseUrl {string} the instance root, no trailing slash ("" = the module's default)
 * @field apiToken {string} a service token, where the deployment supplies one
 *     (specification 12.5); "" when the registry has no credential for this forge
 * @field host {string} the hostname whose URLs this instance claims ("" = the module's default)
 */
export def struct Config {
    name as string,
    baseUrl as string,
    apiToken as string,
    host as string
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
 *     file at this path at that commit? Never fetches the content: GitHub and
 *     Gitea read a listing of its directory, GitLab asks with a `HEAD`; throws
 *     when the forge will not say
 * @field permission {func} `func(Config, url, callerToken) -> Permission`: may they push?
 *     Asked with the caller's own token, where identity and forge are one service
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
 * Turn a forge's answer about one ref into presence, or refuse to guess.
 *
 * `200` is present and `404` is absent; anything else throws. The check finds a
 * ref shadowing a commit of the same name, so reading an unanswerable question
 * as "no such ref" would fail open (same rule as `unknown`, specification 7.1).
 * @param status {int} the HTTP status the forge answered with
 * @return {bool} true when the ref exists, false when it provably does not
 */
export func refPresence(status as int) {
    if ($status == 200) {
        return true;
    }
    if ($status == 404) {
        return false;
    }
    throw Error{
        kind: "forge",
        message: "could not tell whether the repository has a ref of that name: " +
            "the forge answered " + convert.toString($status),
        file: "",
        line: 0,
        col: 0
    };
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
    $rest = strings.substring($rest, $scheme + 3, len($rest));
    def slash as int init strings.indexOf($rest, "/");
    if ($slash >= 0) {
        $rest = strings.substring($rest, 0, $slash);
    }
    def at as int init strings.indexOf($rest, "@");
    if ($at >= 0) {
        $rest = strings.substring($rest, $at + 1, len($rest));
    }
    def colon as int init strings.indexOf($rest, ":");
    if ($colon >= 0) {
        $rest = strings.substring($rest, 0, $colon);
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
    $rest = strings.substring($rest, $scheme + 3, len($rest));
    def slash as int init strings.indexOf($rest, "/");
    if ($slash < 0) {
        return "";
    }
    $rest = strings.substring($rest, $slash + 1, len($rest));
    if (strings.endsWith($rest, ".git")) {
        $rest = strings.substring($rest, 0, len($rest) - 4);
    }
    if (strings.endsWith($rest, "/")) {
        $rest = strings.substring($rest, 0, len($rest) - 1);
    }
    return $rest;
}

/**
 * Why a repository URL cannot be published from, or "" when it can. Pure.
 *
 * Adapters build API calls from the configured base URL and `pathOf(url)` only,
 * while the whole URL is recorded and handed to clients. Anything the adapters
 * do not read would let the two disagree, so userinfo, query, fragment and
 * misleading path segments (`..`, an encoded `/`) are refused before any request.
 * The host is judged by `Forge.handles`.
 * @param url {string} the repository URL from the request
 * @return {string} the complaint, or ""
 */
export func repositoryProblem(url as string) {
    def raw as string init strings.trim($url);
    if ($raw == "") {
        return "missing `repository`";
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
    def u as uri.Uri init uri.parse(strings.trim($url));
    def scheme as string init "https";
    def port as string init "";
    if (not (strings.trim($baseUrl) == "")) {
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
 * A repository path split at its last `/` into directory and file name. Pure.
 * A path with no `/` lives at the top: `["", "deck.toml"]`.
 * @param p {string} a path inside the repository, such as `src/deck.j`
 * @return {list of string} the directory and the file name
 */
export func splitPath(p as string) {
    def slash as int init strings.lastIndexOf($p, "/");
    if ($slash < 0) {
        return ["", $p];
    }
    return [strings.substring($p, 0, $slash), strings.substring($p, $slash + 1, len($p))];
}

/**
 * The names of the files in a directory listing, as GitHub, Gitea and GitLab
 * return one: a JSON list of objects carrying `name` and `type`. Pure.
 *
 * Only entries of type `kind` count (`file` on GitHub and Gitea, `blob` on
 * GitLab), so a directory or submodule of the same name is not mistaken for a
 * file. A non-list (a forge's answer when the "directory" is a file) lists
 * nothing.
 * @param listing {json.Value} the decoded response
 * @param kind {string} the type an ordinary file carries on this forge
 * @return {list of string} the file names
 */
export func fileNames(listing as json.Value, kind as string) {
    def out as list of string init [];
    if (not (json.typeOf($listing, "") == "list")) {
        return $out;
    }
    for (def i in 0..json.length($listing, "")) {
        def at as string init "/" + convert.toString($i);
        if (json.has($listing, $at + "/name") and json.has($listing, $at + "/type") and
            json.asString($listing, $at + "/type") == $kind) {
            $out[] = json.asString($listing, $at + "/name");
        }
    }
    return $out;
}

/**
 * Why a tag cannot be published, or "" when it can. Pure.
 *
 * The tag is placed into forge API paths and must not change which path it
 * addresses. Git's ref-name rules refuse most of that (`..`, whitespace, control
 * characters, `?`, `[`, `\`); `%` and `#` are legal in git but would be decoded
 * or cut off on the way to a forge, so they are refused too. An inner `/` is
 * allowed.
 * @param tag {string} the tag named in the request
 * @return {string} the complaint, or ""
 */
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
        if (convert.toCodepoint($c) <= 32 or convert.toCodepoint($c) == 127 or
            strings.contains('~^:?*[\%#', $c)) {
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

