# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The forge interface (specification 12.3): what is in this repository, and who
 * may push to it?
 *
 * A deployment configures **one or more** forges, matched against a version
 * record's `url`, which is what lets one registry accept an internal Forgejo and
 * public GitHub in a single dependency graph. Each module under `forge/` exports
 * a `forge()` returning a `Forge` - a struct of `func` values.
 *
 * The shared types live here for the same reason as in `identity.j`: a struct is
 * identified by `(module, name)`.
 *
 * This module is pure. Each forge module keeps its URL parsing and its
 * permission interpretation separate from its one HTTP call, so those can be
 * tested without a socket, which matters here because the API shapes are taken
 * from documentation rather than from a live instance.
 * @module forge
 * @example
 * import "./forge/gitea.j" as gitea;
 * def f as forge.Forge init gitea.forge();
 * if ($f.handles($cfg, $url)) { def c as string init $f.resolveTag($cfg, $url, "v1"); }
 */

use strings;

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
 * @field known {bool} false when the forge could not answer at all, which is
 *     **not** the same as a refusal: specification 7.1 requires an unanswerable
 *     check to be treated as unverified, never as granted
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
 * **Every function takes the `Config` as its first argument**, for the same
 * reason as in `identity.j`: Jennifer has no closures, so a forge cannot be built
 * around a configuration it remembers. `forge()` takes nothing and returns a
 * vtable; the caller holds the pair.
 * @field name {string} the forge name
 * @field handles {func} `func(Config, url) -> bool`: does this instance claim this URL?
 * @field resolveTag {func} `func(Config, url, tag) -> string`: the commit a tag points at
 * @field readFile {func} `func(Config, url, commit, path) -> string`: a file at a commit
 * @field permission {func} `func(Config, url, callerToken) -> Permission`: may they push?
 * @field repo {func} `func(Config, url) -> Repo`: the immutable identity of a repository
 */
export def struct Forge {
    name as string,
    handles as func,
    resolveTag as func,
    readFile as func,
    permission as func,
    repo as func
};

/**
 * The answer when a forge cannot say. Kept here so every module words it the
 * same way, and so the distinction from a refusal is impossible to lose.
 * @param reason {string} why the check could not be made
 * @return {Permission} an unknown permission
 */
export func unknown(reason as string) {
    return Permission{ known: false, push: false, reason: $reason };
}

/**
 * The answer when a forge says yes.
 * @param reason {string} why access was granted
 * @return {Permission} a granting permission
 */
export func granted(reason as string) {
    return Permission{ known: true, push: true, reason: $reason };
}

/**
 * The answer when a forge says no.
 * @param reason {string} why access was refused
 * @return {Permission} a refusing permission
 */
export func refused(reason as string) {
    return Permission{ known: true, push: false, reason: $reason };
}

/**
 * The host part of a URL, lowercased, with any userinfo and port removed.
 * Returns "" when the URL has no recognisable host, which is how a `file://` or
 * a plain path falls through to "no forge handles this".
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
 * Deeper paths are preserved, because GitLab nests groups: a URL of
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
