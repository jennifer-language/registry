# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The scopes a deployment holds back from self-service claiming.
 *
 * It covers names that mislead whoever holds them: names that imply the registry
 * itself is speaking (`official`, `admin`, `security`), names that read as
 * infrastructure (`api`, `www`, `static`), and the project's own names.
 *
 * Brand names are not listed, for three reasons:
 *
 * - Under `derived` (12.7, what the official registry runs) a scope is claimable
 *   only by the account whose provider identity is that name, so `@microsoft`
 *   belongs to the GitHub account `microsoft`. A brand list would only matter
 *   under `firstcome`.
 * - The list has no edge: any real list is a handful of famous names, and
 *   readers would assume the absent ones were considered.
 * - Reserving a brand implies an adjudication nobody here performs. The dispute
 *   path in section 10 is the mechanism, and it is reactive.
 *
 * A private deployment supplies its own list; this is data, not a rule.
 * @module reserved
 * @example
 * import "./reserved.j" as reserved;
 * def held as list of string init reserved.defaults();
 */

use strings;
use maps;
import "./deckname.j" as deckname;

/**
 * Scopes that read as the registry speaking for itself, or as a privileged
 * authority; a deck under one would inherit trust nobody granted.
 * @return {list of string} the reserved names
 */
export func authority() {
    return [
        "official",
        "admin",
        "administrator",
        "root",
        "superuser",
        "sudo",
        "system",
        "security",
        "abuse",
        "legal",
        "moderator",
        "moderation",
        "staff",
        "team",
        "owner",
        "support",
        "help",
        "contact",
        "billing",
        "trust",
        "verified",
        "core",
        "internal"
    ];
}

/**
 * Scopes that read as part of the service, and may collide with a future route
 * or subdomain.
 * @return {list of string} the reserved names
 */
export func infrastructure() {
    return [
        "api",
        "www",
        "web",
        "app",
        "cdn",
        "static",
        "assets",
        "media",
        "registry",
        "index",
        "search",
        "health",
        "status",
        "metrics",
        "deck",
        "decks",
        "docs",
        "doc",
        "manual",
        "reference",
        "spec",
        "specs",
        "download",
        "downloads",
        "mirror",
        "mirrors",
        "packages",
        "repo"
    ];
}

/**
 * The project's own names, so the registry, the client, and the language cannot
 * be impersonated by whoever registers first. `deckyard` is the community deck
 * organisation: not part of the project, but a name its decks are trusted by.
 * @return {list of string} the reserved names
 */
export func project() {
    return [
        "jennifer",
        "jvc",
        "grimoire",
        "deck",
        "registry",
        "deckregistry",
        "jennifer-lang",
		"jennifer-language",
        "deckyard"
    ];
}

/**
 * Placeholder names: `@test` or `@example` would be noise, and `@null` /
 * `@undefined` are what a broken client sends for nothing.
 * @return {list of string} the reserved names
 */
export func placeholder() {
    return [
        "test",
        "testing",
        "example",
        "examples",
        "sample",
        "samples",
        "demo",
        "tmp",
        "temp",
        "foo",
        "bar",
        "baz",
        "null",
        "undefined",
        "none",
        "nil",
        "unknown",
        "anonymous",
        "nobody",
        "default"
    ];
}

/**
 * Every reserved scope, deduplicated and folded. The groups above say why each
 * name is held.
 * @return {list of string} the full reserved list
 */
export func defaults() {
    def out as list of string init [];
    def seen as map of string to bool init {};
    for (def group in [authority(), infrastructure(), project(), placeholder()]) {
        for (def name in $group) {
            def folded as string init deckname.fold(strings.trim($name));
            if (not maps.has($seen, $folded)) {
                $seen[$folded] = true;
                $out[] = $folded;
            }
        }
    }
    return $out;
}

/**
 * The names the scope grammar rejects. An invalid reserved name hides a typo:
 * `jennifer-lang` reserves something, `jennifer_lang` reserves nothing. Exported
 * so a test asserts the defaults are all valid.
 * @param names {list of string} the names to check
 * @return {list of string} those that are not valid scope names ([] when all are)
 */
export func invalidAmong(names as list of string) {
    def bad as list of string init [];
    for (def name in $names) {
        if (not deckname.isScopeIdent($name)) {
            $bad[] = $name;
        }
    }
    return $bad;
}
