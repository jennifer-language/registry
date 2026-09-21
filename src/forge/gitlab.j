# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * GitLab as a forge, hosted or self-hosted: the two differ only in `baseUrl`
 * (specification 12.3).
 *
 * GitLab differs from the GitHub-shaped forges in three ways that matter:
 *
 * - a project is addressed by its **URL-encoded path**, `group%2Fsub%2Fproject`,
 *   not by `owner/repo` path segments, and groups nest arbitrarily deep;
 * - permission is an **access level**, not a boolean. Write is level **30**
 *   (developer) or above, and it can arrive as either a project membership or an
 *   inherited group membership, so both are considered;
 * - the owning entity is a `namespace`, which may be a user or a group.
 *
 * > **Verified against live gitlab.com** on 2026-08-16: `repo` returns the
 * > project and namespace ids, `resolveTag` resolves a tag to its commit, and
 * > `readFile` reads a path at a commit, all through the URL-encoded project
 * > path. **`permission` is still unverified** - it needs a real caller token,
 * > and with it the access-level threshold above.
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
 * A project's URL-encoded path id, which is how GitLab addresses a project that
 * may sit several groups deep. Pure.
 * @param url {string} the repository URL
 * @return {string} the encoded path, e.g. `group%2Fsub%2Fproject`
 */
export func projectId(url as string) {
    def raw as bytes init convert.bytesFromString(forge.pathOf($url), "utf-8");
    return encoding.toText($raw, "uri-percent");
}

/**
 * Interpret a GitLab project payload as a push permission. Pure, and the place
 * the access-level threshold is applied.
 *
 * Either a direct project membership or an inherited group membership of level
 * 30 or above grants write, so the higher of the two decides.
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
 * Build a `Repo` from a GitLab project payload. Pure. The owning entity is the
 * project's namespace, which may be a user or a group.
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
    return forge.Repo{ id: $id, ownerId: $ownerId, owner: $owner, name: $name };
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
    def h as map of string to string init jsonHeaders();
    if (not ($callerToken == "")) {
        $h["Authorization"] = "Bearer " + $callerToken;
    } elseif (not ($cfg.apiToken == "")) {
        $h["Authorization"] = "Bearer " + $cfg.apiToken;
    }
    return http.requestWith("GET", apiBase($cfg) + $path, $h, "", TIMEOUT_MS, MAX_BYTES);
}

func handles(cfg as forge.Config, url as string) {
    return handlesUrl($cfg, $url);
}

func resolveTag(cfg as forge.Config, url as string, tag as string) {
    def res as http.Response init get($cfg,
        "/projects/" + projectId($url) + "/repository/tags/" + $tag, "");
    if (not ($res.status == 200)) {
        throw Error{
            kind: "forge",
            message: "could not resolve the tag " + $tag + ": the forge answered " +
                convert.toString($res.status),
            file: "", line: 0, col: 0
        };
    }
    return tagCommitFrom(json.decode($res.body));
}

func readFile(cfg as forge.Config, url as string, commit as string, path as string) {
    def raw as bytes init convert.bytesFromString($path, "utf-8");
    def encoded as string init encoding.toText($raw, "uri-percent");
    def res as http.Response init get($cfg, "/projects/" + projectId($url) +
        "/repository/files/" + $encoded + "/raw?ref=" + $commit, "");
    if (not ($res.status == 200)) {
        throw Error{
            kind: "forge",
            message: "could not read " + $path + " at " + $commit + ": the forge answered " +
                convert.toString($res.status),
            file: "", line: 0, col: 0
        };
    }
    return $res.body;
}

# refExists reports whether a branch or tag of this exact name is present. Both
# namespaces are asked because either would shadow an object of the same name in
# a `?ref=` lookup, and GitLab permits a name shaped like an object id where
# GitHub refuses one.
func refExists(cfg as forge.Config, url as string, name as string) {
    def raw as bytes init convert.bytesFromString($name, "utf-8");
    def encoded as string init encoding.toText($raw, "uri-percent");
    def branch as http.Response init get($cfg, "/projects/" + projectId($url) +
        "/repository/branches/" + $encoded, "");
    if (forge.refPresence($branch.status)) {
        return true;
    }
    def tag as http.Response init get($cfg, "/projects/" + projectId($url) +
        "/repository/tags/" + $encoded, "");
    return forge.refPresence($tag.status);
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

func repo(cfg as forge.Config, url as string) {
    def res as http.Response init get($cfg, "/projects/" + projectId($url), "");
    if (not ($res.status == 200)) {
        throw Error{
            kind: "forge",
            message: "could not read the project: the forge answered " +
                convert.toString($res.status),
            file: "", line: 0, col: 0
        };
    }
    return repoFrom(json.decode($res.body));
}

/**
 * The GitLab forge.
 * @return {forge.Forge} the vtable; every call takes a `forge.Config`
 */
export func forge() {
    return forge.Forge{
        name: "gitlab",
        handles: handles,
        resolveTag: resolveTag,
        readFile: readFile,
        refExists: refExists,
        permission: permission,
        repo: repo
    };
}
