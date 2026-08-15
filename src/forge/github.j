# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * GitHub as a forge: resolving a tag, reading `deck.toml` at a commit, and
 * answering whether the caller may push (specification 12.3).
 *
 * **`push` is the requirement, not ownership** (7.1). `GET /repos/{owner}/{repo}`
 * returns a `permissions` object for the authenticated user, which accepts a
 * repository owned by an organisation the caller can write to; an ownership
 * comparison would wrongly reject that.
 *
 * A missing or unusable answer is `unknown`, never a refusal: 7.1 requires an
 * unanswerable check to be treated as unverified rather than as granted, and
 * conflating the two is how a permission system quietly fails open.
 *
 * **Verified against live github.com** on 2026-08-16: `repo` returns the
 * numeric repository and owner ids, `resolveTag` resolves an annotated tag
 * through its tag object to the commit, and `readFile` reads a path at a commit.
 * `permission` is still unverified, because it needs a real caller token.
 * @module github
 * @example
 * import "./github.j" as github;
 * def f as forge.Forge init github.forge();
 * def p as forge.Permission init $f.permission($cfg, $url, $callerToken);
 */

use json;
use strings;
use convert;
import "http.j" as http;
import "../forge.j" as forge;

def const HOSTED_HOST as string init "github.com";
def const API_BASE as string init "https://api.github.com";
def const TIMEOUT_MS as int init 10000;
def const MAX_BYTES as int init 262144;

func jsonHeaders() {
    def h as map of string to string init {};
    $h["Accept"] = "application/vnd.github+json";
    $h["User-Agent"] = "jennifer-registry";
    return $h;
}

func apiBase(cfg as forge.Config) {
    if (strings.trim($cfg.baseUrl) == "") {
        return API_BASE;
    }
    return strings.trim($cfg.baseUrl);
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
 * Interpret GitHub's repository payload as a push permission. Pure, so the
 * decision that gates publishing is testable without a socket.
 * @param doc {json.Value} the decoded `/repos/{owner}/{repo}` response
 * @return {forge.Permission} granted, refused, or unknown
 */
export func permissionFrom(doc as json.Value) {
    if (not json.has($doc, "/permissions")) {
        return forge.unknown("the forge returned no permissions for this caller");
    }
    if (not json.has($doc, "/permissions/push")) {
        return forge.unknown("the forge returned no push permission for this caller");
    }
    if (json.asBool($doc, "/permissions/push")) {
        return forge.granted("the caller has push access");
    }
    return forge.refused("the caller has no push access to this repository");
}

/**
 * Build a `Repo` from GitHub's repository payload. Pure.
 * @param doc {json.Value} the decoded response
 * @return {forge.Repo} the immutable identity of the repository
 */
export func repoFrom(doc as json.Value) {
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
    def id as string init "";
    if (json.has($doc, "/id")) {
        $id = convert.toString(json.asInt($doc, "/id"));
    }
    return forge.Repo{ id: $id, ownerId: $ownerId, owner: $owner, name: $name };
}

/**
 * The commit a tag payload points at. Pure.
 *
 * An annotated tag resolves in two steps: the ref points at a tag object, which
 * points at the commit. A lightweight tag points at the commit directly. Both
 * shapes appear in `/git/ref`, so both are handled here.
 * @param doc {json.Value} the decoded `/git/ref/tags/{tag}` response
 * @return {string} the object SHA the ref names, or ""
 */
export func refTargetFrom(doc as json.Value) {
    if (not json.has($doc, "/object/sha")) {
        return "";
    }
    return json.asString($doc, "/object/sha");
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

func repoPath(url as string) {
    return "/repos/" + forge.pathOf($url);
}

func handles(cfg as forge.Config, url as string) {
    return handlesUrl($cfg, $url);
}

func resolveTag(cfg as forge.Config, url as string, tag as string) {
    def res as http.Response init get($cfg, repoPath($url) + "/git/ref/tags/" + $tag, "");
    if (not ($res.status == 200)) {
        throw Error{
            kind: "forge",
            message: "could not resolve the tag " + $tag + ": the forge answered " +
                convert.toString($res.status),
            file: "", line: 0, col: 0
        };
    }
    def sha as string init refTargetFrom(json.decode($res.body));
    # An annotated tag names a tag object; dereference it to the commit.
    def obj as http.Response init get($cfg, repoPath($url) + "/git/tags/" + $sha, "");
    if ($obj.status == 200) {
        def deref as json.Value init json.decode($obj.body);
        if (json.has($deref, "/object/sha")) {
            return json.asString($deref, "/object/sha");
        }
    }
    return $sha;
}

func readFile(cfg as forge.Config, url as string, commit as string, path as string) {
    def h as map of string to string init jsonHeaders();
    $h["Accept"] = "application/vnd.github.raw";
    if (not ($cfg.apiToken == "")) {
        $h["Authorization"] = "Bearer " + $cfg.apiToken;
    }
    def target as string init apiBase($cfg) + repoPath($url) + "/contents/" + $path +
        "?ref=" + $commit;
    def res as http.Response init http.requestWith("GET", $target, $h, "",
        TIMEOUT_MS, MAX_BYTES);
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
 * The GitHub forge.
 * @return {forge.Forge} the vtable; every call takes a `forge.Config`
 */
export func forge() {
    return forge.Forge{
        name: "github",
        handles: handles,
        resolveTag: resolveTag,
        readFile: readFile,
        permission: permission,
        repo: repo
    };
}
