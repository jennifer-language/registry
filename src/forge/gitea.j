# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * Gitea as a forge, which also covers **Forgejo**: Forgejo is a Gitea fork and
 * its API is compatible, so one module serves both (specification 12.3).
 *
 * Gitea's API is deliberately GitHub-shaped, so the payloads here are nearly the
 * same: `permissions.push` on the repository, `owner.id` for provenance. What
 * differs is the base path (`/api/v1`) and that there is no hosted default,
 * because a Gitea instance is always somebody's own.
 *
 * > **Verified against live codeberg.org** (a Forgejo instance) on 2026-08-16:
 * > `repo` returns the repository and owner ids, `resolveTag` resolves a tag to
 * > its commit, and `readFile` reads a path at a commit. That the same module
 * > serves Gitea and Forgejo is therefore tested, not assumed. **`permission` is
 * > still unverified**, along with the minimum token scope that returns a
 * > populated `permissions`.
 * @module gitea
 * @example
 * import "./gitea.j" as gitea;
 * def f as forge.Forge init gitea.forge();
 */

use json;
use strings;
use convert;
import "http.j" as http;
import "../forge.j" as forge;

def const TIMEOUT_MS as int init 10000;
def const MAX_BYTES as int init 262144;

func jsonHeaders() {
    def h as map of string to string init {};
    $h["Accept"] = "application/json";
    return $h;
}

# requireBase refuses an unset base rather than guessing: there is no hosted
# Gitea a deployment would plausibly mean.
func requireBase(cfg as forge.Config) {
    if (strings.trim($cfg.baseUrl) == "") {
        throw Error{
            kind: "forge",
            message: "the gitea forge needs a baseUrl; there is no hosted default",
            file: "", line: 0, col: 0
        };
    }
    def base as string init strings.trim($cfg.baseUrl);
    if (strings.endsWith($base, "/")) {
        $base = strings.substring($base, 0, len($base) - 1);
    }
    return $base + "/api/v1";
}

/**
 * Whether this instance claims a URL. Pure. An instance with no configured host
 * claims nothing, because guessing would let it answer for a stranger's server.
 * @param cfg {forge.Config} the forge configuration
 * @param url {string} the repository URL
 * @return {bool} true when this forge should handle it
 */
export func handlesUrl(cfg as forge.Config, url as string) {
    def want as string init strings.lower(strings.trim($cfg.host));
    if ($want == "") {
        return false;
    }
    return forge.hostOf($url) == $want;
}

/**
 * Interpret Gitea's repository payload as a push permission. Pure.
 * @param doc {json.Value} the decoded repository response
 * @return {forge.Permission} granted, refused, or unknown
 */
export func permissionFrom(doc as json.Value) {
    if (not json.has($doc, "/permissions/push")) {
        return forge.unknown("the forge returned no push permission for this caller");
    }
    if (json.asBool($doc, "/permissions/push")) {
        return forge.granted("the caller has push access");
    }
    return forge.refused("the caller has no push access to this repository");
}

/**
 * Build a `Repo` from Gitea's repository payload. Pure.
 * @param doc {json.Value} the decoded response
 * @return {forge.Repo} the immutable identity of the repository
 */
export func repoFrom(doc as json.Value) {
    def id as string init "";
    if (json.has($doc, "/id")) {
        $id = convert.toString(json.asInt($doc, "/id"));
    }
    def ownerId as string init "";
    if (json.has($doc, "/owner/id")) {
        $ownerId = convert.toString(json.asInt($doc, "/owner/id"));
    }
    def owner as string init "";
    if (json.has($doc, "/owner/login")) {
        $owner = json.asString($doc, "/owner/login");
    }
    def name as string init "";
    if (json.has($doc, "/name")) {
        $name = json.asString($doc, "/name");
    }
    return forge.Repo{ id: $id, ownerId: $ownerId, owner: $owner, name: $name };
}

/**
 * The commit a tag payload names. Pure. Gitea returns the tag with a nested
 * `commit.sha`, already dereferenced, so annotated tags need no second call.
 * @param doc {json.Value} the decoded tag response
 * @return {string} the commit SHA, or ""
 */
export func tagCommitFrom(doc as json.Value) {
    if (json.has($doc, "/commit/sha")) {
        return json.asString($doc, "/commit/sha");
    }
    if (json.has($doc, "/id")) {
        return json.asString($doc, "/id");
    }
    return "";
}

func get(cfg as forge.Config, path as string, callerToken as string) {
    def h as map of string to string init jsonHeaders();
    if (not ($callerToken == "")) {
        $h["Authorization"] = "token " + $callerToken;
    } elseif (not ($cfg.apiToken == "")) {
        $h["Authorization"] = "token " + $cfg.apiToken;
    }
    return http.requestWith("GET", requireBase($cfg) + $path, $h, "",
        TIMEOUT_MS, MAX_BYTES);
}

func repoPath(url as string) {
    return "/repos/" + forge.pathOf($url);
}

func handles(cfg as forge.Config, url as string) {
    return handlesUrl($cfg, $url);
}

func resolveTag(cfg as forge.Config, url as string, tag as string) {
    def res as http.Response init get($cfg, repoPath($url) + "/tags/" + $tag, "");
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
    def res as http.Response init get($cfg,
        repoPath($url) + "/raw/" + $path + "?ref=" + $commit, "");
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

func permission(cfg as forge.Config, url as string, callerToken as string) {
    if ($callerToken == "" and $cfg.apiToken == "") {
        return forge.unknown("the registry holds no credential this forge accepts");
    }
    def res as http.Response init get($cfg, repoPath($url), $callerToken);
    if (not ($res.status == 200)) {
        return forge.unknown("the forge answered " + convert.toString($res.status) +
            " when asked about this repository");
    }
    return permissionFrom(json.decode($res.body));
}

func repo(cfg as forge.Config, url as string) {
    def res as http.Response init get($cfg, repoPath($url), "");
    if (not ($res.status == 200)) {
        throw Error{
            kind: "forge",
            message: "could not read the repository: the forge answered " +
                convert.toString($res.status),
            file: "", line: 0, col: 0
        };
    }
    return repoFrom(json.decode($res.body));
}

/**
 * The Gitea / Forgejo forge.
 * @return {forge.Forge} the vtable; every call takes a `forge.Config`
 */
export func forge() {
    return forge.Forge{
        name: "gitea",
        handles: handles,
        resolveTag: resolveTag,
        readFile: readFile,
        permission: permission,
        repo: repo
    };
}
