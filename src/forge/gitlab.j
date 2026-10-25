# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * GitLab as a forge, hosted or self-hosted: the two differ only in `baseUrl`
 * (specification 12.3).
 *
 * Differences from the GitHub-shaped forges:
 *
 * - a project is addressed by its URL-encoded path, `group%2Fsub%2Fproject`,
 *   and groups nest arbitrarily deep;
 * - permission is an access level. Write is level 30 (developer) or above, from
 *   either a project membership or an inherited group membership;
 * - the owning entity is a `namespace`, which may be a user or a group.
 *
 * > Verified against live gitlab.com on 2026-08-16: `repo`, `resolveTag` and
 * > `readFile`, all through the URL-encoded project path. `permission` is still
 * > unverified: it needs a real caller token, and so does the access-level
 * > threshold above.
 * @module gitlab
 * @example
 * import "./gitlab.j" as gitlab;
 * def f as forge.Forge init gitlab.forge();
 */

use json;
use strings;
use convert;
use encoding;
import "http.j" as http;
import "../forge.j" as forge;

def const HOSTED_HOST as string init "gitlab.com";
def const HOSTED_BASE as string init "https://gitlab.com";
def const TIMEOUT_MS as int init 10000;
def const MAX_BYTES as int init 262144;

# GitLab's access levels. 30 is developer, the lowest that may push.
def const LEVEL_DEVELOPER as int init 30;

func jsonHeaders() {
    def h as map of string to string init {};
    $h["Accept"] = "application/json";
    return $h;
}

func apiBase(cfg as forge.Config) {
    def base as string init strings.trim($cfg.baseUrl);
    if ($base == "") {
        $base = HOSTED_BASE;
    }
    if (strings.endsWith($base, "/")) {
        $base = strings.substring($base, 0, len($base) - 1);
    }
    return $base + "/api/v4";
}

func hostFor(cfg as forge.Config) {
    if (strings.trim($cfg.host) == "") {
        return HOSTED_HOST;
    }
    return strings.lower(strings.trim($cfg.host));
}

/**
 * Whether this instance claims a URL. Pure.
 * @param cfg {forge.Config} the forge configuration
 * @param url {string} the repository URL
 * @return {bool} true when this forge should handle it
 */
export func handlesUrl(cfg as forge.Config, url as string) {
    return forge.hostOf($url) == hostFor($cfg);
}

/**
 * A project's URL-encoded path id, GitLab's address for a nested project. Pure.
 * @param url {string} the repository URL
 * @return {string} the encoded path, e.g. `group%2Fsub%2Fproject`
 */
export func projectId(url as string) {
    def raw as bytes init convert.bytesFromString(forge.pathOf($url), "utf-8");
    return encoding.toText($raw, "uri-percent");
}

/**
 * Interpret a GitLab project payload as a push permission. Pure. The higher of
 * the project and group access levels decides; 30 or above grants write.
 * @param doc {json.Value} the decoded project response
 * @return {forge.Permission} granted, refused, or unknown
 */
export func permissionFrom(doc as json.Value) {
    if (not json.has($doc, "/permissions")) {
        return forge.unknown("the forge returned no permissions for this caller");
    }
    def best as int init 0;
    def seen as bool init false;
    if (json.has($doc, "/permissions/project_access/access_level")) {
        $best = json.asInt($doc, "/permissions/project_access/access_level");
        $seen = true;
    }
    if (json.has($doc, "/permissions/group_access/access_level")) {
        def group as int init json.asInt($doc, "/permissions/group_access/access_level");
        if (not $seen or $group > $best) {
            $best = $group;
        }
        $seen = true;
    }
    if (not $seen) {
        return forge.refused("the caller has no membership of this project");
    }
    if ($best >= LEVEL_DEVELOPER) {
        return forge.granted("the caller has access level " + convert.toString($best));
    }
    return forge.refused("access level " + convert.toString($best) +
        " is below developer, which is the lowest that may push");
}

/**
 * The id of the account with exactly this username, from a `GET /users?username=`
 * answer, or "" when there is none. Pure. Matching is exact and case-insensitive.
 * @param doc {json.Value} the decoded response, a list of users
 * @param username {string} the username asked about
 * @return {string} the numeric id as text, or ""
 */
export func userIdFrom(doc as json.Value, username as string) {
    if (not (json.typeOf($doc, "") == "list")) {
        return "";
    }
    for (def i in 0..json.length($doc, "")) {
        def at as string init "/" + convert.toString($i);
        if (json.has($doc, $at + "/username") and json.has($doc, $at + "/id") and
            strings.lower(json.asString($doc, $at + "/username")) ==
            strings.lower($username)) {
            return convert.toString(json.asInt($doc, $at + "/id"));
        }
    }
    return "";
}

/**
 * Read a project-membership payload (`GET /projects/:id/members/all/:user_id`)
 * as a push permission. Pure. The `all` form includes inherited group access.
 * Developer (30) is the lowest level that may push; an inactive membership
 * grants nothing.
 * @param doc {json.Value} the decoded response
 * @return {forge.Permission} granted, refused, or unknown
 */
export func memberPermissionFrom(doc as json.Value) {
    if (not json.has($doc, "/access_level")) {
        return forge.unknown("the forge returned no access level for this account");
    }
    if (json.has($doc, "/state") and not (json.asString($doc, "/state") == "active")) {
        return forge.refused("the account's membership is " + json.asString($doc, "/state"));
    }
    def level as int init json.asInt($doc, "/access_level");
    if ($level >= LEVEL_DEVELOPER) {
        return forge.granted("the account has access level " + convert.toString($level));
    }
    return forge.refused("access level " + convert.toString($level) +
        " is below developer, which is the lowest that may push");
}

/**
 * Build a `Repo` from a GitLab project payload. Pure. The owner is the project's
 * namespace.
 * @param doc {json.Value} the decoded response
 * @return {forge.Repo} the immutable identity of the repository
 */
export func repoFrom(doc as json.Value) {
    def id as string init "";
    if (json.has($doc, "/id")) {
        $id = convert.toString(json.asInt($doc, "/id"));
    }
    def ownerId as string init "";
    if (json.has($doc, "/namespace/id")) {
        $ownerId = convert.toString(json.asInt($doc, "/namespace/id"));
    }
    def owner as string init "";
    if (json.has($doc, "/namespace/full_path")) {
        $owner = json.asString($doc, "/namespace/full_path");
    }
    def name as string init "";
    if (json.has($doc, "/path")) {
        $name = json.asString($doc, "/path");
    }
    return forge.Repo{id: $id, ownerId: $ownerId, owner: $owner, name: $name};
}

/**
 * The commit a tag payload names. Pure.
 * @param doc {json.Value} the decoded tag response
 * @return {string} the commit SHA, or ""
 */
export func tagCommitFrom(doc as json.Value) {
    if (json.has($doc, "/commit/id")) {
        return json.asString($doc, "/commit/id");
    }
    if (json.has($doc, "/target")) {
        return json.asString($doc, "/target");
    }
    return "";
}

func get(cfg as forge.Config, path as string, callerToken as string) {
    return send($cfg, "GET", $path, $callerToken);
}

func send(cfg as forge.Config, method as string, path as string, callerToken as string) {
    def h as map of string to string init jsonHeaders();
    if (not ($callerToken == "")) {
        $h["Authorization"] = "Bearer " + $callerToken;
    } elseif (not ($cfg.apiToken == "")) {
        $h["Authorization"] = "Bearer " + $cfg.apiToken;
    }
    return http.requestWith($method, apiBase($cfg) + $path, $h, "", TIMEOUT_MS, MAX_BYTES);
}

func handles(cfg as forge.Config, url as string) {
    return handlesUrl($cfg, $url);
}

func resolveTag(cfg as forge.Config, url as string, tag as string) {
    def res as http.Response init get(
        $cfg,
        "/projects/" + projectId($url) + "/repository/tags/" + $tag,
        "");
    if (not ($res.status == 200)) {
        throw Error{
            kind: "forge",
            message: "could not resolve the tag " + $tag + ": the forge answered " +
                convert.toString($res.status),
            file: "",
            line: 0,
            col: 0
        };
    }
    return tagCommitFrom(json.decode($res.body));
}

func readFile(cfg as forge.Config, url as string, commit as string, path as string) {
    def raw as bytes init convert.bytesFromString($path, "utf-8");
    def encoded as string init encoding.toText($raw, "uri-percent");
    def res as http.Response init get(
        $cfg,
        "/projects/" + projectId($url) +
            "/repository/files/" + $encoded + "/raw?ref=" + $commit,
        "");
    if (not ($res.status == 200)) {
        throw Error{
            kind: "forge",
            message: "could not read " + $path + " at " + $commit + ": the forge answered " +
                convert.toString($res.status),
            file: "",
            line: 0,
            col: 0
        };
    }
    return $res.body;
}

# refExists reports whether a branch or tag of this exact name is present. Either
# would shadow a same-named object in a `?ref=` lookup, and GitLab permits ref
# names shaped like object ids.
func refExists(cfg as forge.Config, url as string, name as string) {
    def raw as bytes init convert.bytesFromString($name, "utf-8");
    def encoded as string init encoding.toText($raw, "uri-percent");
    def branch as http.Response init get(
        $cfg,
        "/projects/" + projectId($url) +
            "/repository/branches/" + $encoded,
        "");
    if (forge.refPresence($branch.status)) {
        return true;
    }
    def tag as http.Response init get(
        $cfg,
        "/projects/" + projectId($url) +
            "/repository/tags/" + $encoded,
        "");
    return forge.refPresence($tag.status);
}

# filePath is the files-API address of one path at one commit. The path is one
# segment there, so its slashes are escaped too.
func filePath(url as string, commit as string, path as string) {
    def raw as bytes init convert.bytesFromString($path, "utf-8");
    return "/projects/" + projectId($url) + "/repository/files/" +
        encoding.toText($raw, "uri-percent") + "?ref=" + $commit;
}

# fileExists asks the files API with a `HEAD`, so the file's content is not sent.
# The files API serves blobs only, so a directory is a `404` like a missing path;
# any other failure throws through `refPresence`.
func fileExists(cfg as forge.Config, url as string, commit as string, path as string) {
    def res as http.Response init send($cfg, "HEAD", filePath($url, $commit, $path), "");
    return forge.refPresence($res.status);
}

func permission(cfg as forge.Config, url as string, callerToken as string) {
    if ($callerToken == "" and $cfg.apiToken == "") {
        return forge.unknown("the registry holds no credential this forge accepts");
    }
    def res as http.Response init get($cfg, "/projects/" + projectId($url), $callerToken);
    if (not ($res.status == 200)) {
        return forge.unknown("the forge answered " + convert.toString($res.status) +
            " when asked about this project");
    }
    return permissionFrom(json.decode($res.body));
}

# permissionFor asks, with the registry's own token, what a named account may do
# in this project (12.5, the service-account route): the username is resolved to
# an id, then the membership is read, inherited access included. Anything but a
# stated access level is unknown, which never grants.
func permissionFor(cfg as forge.Config, url as string, username as string) {
    def problem as string init forge.askProblem($cfg, $username);
    if (not ($problem == "")) {
        return forge.unknown($problem);
    }
    def users as http.Response init get($cfg, "/users?username=" + $username, "");
    if (not ($users.status == 200)) {
        return forge.unknown("the forge answered " + convert.toString($users.status) +
            " when asked for the account " + $username);
    }
    def uid as string init userIdFrom(json.decode($users.body), $username);
    if ($uid == "") {
        return forge.unknown("the forge has no account named " + $username);
    }
    def res as http.Response init get(
        $cfg,
        "/projects/" + projectId($url) +
            "/members/all/" + $uid,
        "");
    if (not ($res.status == 200)) {
        return forge.unknown("the forge answered " + convert.toString($res.status) +
            " when asked what " + $username + " may do in this project");
    }
    return memberPermissionFrom(json.decode($res.body));
}

func repo(cfg as forge.Config, url as string) {
    def res as http.Response init get($cfg, "/projects/" + projectId($url), "");
    if (not ($res.status == 200)) {
        throw Error{
            kind: "forge",
            message: "could not read the project: the forge answered " +
                convert.toString($res.status),
            file: "",
            line: 0,
            col: 0
        };
    }
    return repoFrom(json.decode($res.body));
}

/**
 * The GitLab forge.
 * @return {forge.Forge} the vtable; every call takes a `forge.Config`
 */
# account looks up the forge account with exactly this username (12.5). A
# missing account is `noAccount()`; any other failure throws, never "none".
func account(cfg as forge.Config, username as string) {
    def problem as string init forge.askProblem($cfg, $username);
    if (not ($problem == "")) {
        throw Error{kind: "forge", message: $problem};
    }
    def res as http.Response init get($cfg, "/users?username=" + $username, "");
    if ($res.status == 404) {
        return forge.noAccount();
    }
    if (not ($res.status == 200)) {
        throw Error{
            kind: "forge",
            message: "the forge answered " + convert.toString($res.status) +
                " when asked for the account " + $username
        };
    }
    return forge.accountFromList(json.decode($res.body), "username", $username);
}

# accountById resolves an immutable account id to its current username (`GET /users/:id`).
func accountById(cfg as forge.Config, id as string) {
    if (not forge.isAccountId($id)) {
        return forge.noAccount();
    }
    def res as http.Response init get($cfg, "/users/" + $id, "");
    if ($res.status == 404) {
        return forge.noAccount();
    }
    if (not ($res.status == 200)) {
        throw Error{
            kind: "forge",
            message: "the forge answered " + convert.toString($res.status) +
                " when asked for account " + $id
        };
    }
    def found as forge.Account init forge.accountFrom(json.decode($res.body), "username");
    if (not ($found.id == $id)) {
        return forge.noAccount();
    }
    return $found;
}

export func forge() {
    return forge.Forge{
        name: "gitlab",
        handles: handles,
        resolveTag: resolveTag,
        readFile: readFile,
        refExists: refExists,
        fileExists: fileExists,
        permission: permission,
        permissionFor: permissionFor,
        repo: repo,
        account: account,
        accountById: accountById
    };
}
