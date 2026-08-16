# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The scopes a deployment holds back from self-service claiming.
 *
 * **What belongs here, and what deliberately does not.**
 *
 * This list covers names whose *meaning* would mislead a reader no matter who
 * holds them: names that imply the registry itself is speaking (`official`,
 * `admin`, `security`), names that read as infrastructure (`api`, `www`,
 * `static`), and the project's own names. A deck under `@official` would carry
 * an endorsement nobody granted, and that is true whether the holder is a
 * squatter or a well-meaning volunteer.
 *
 * **Brand names are not here, and that is a decision rather than an oversight.**
 * The obvious ask is to add `microsoft`, `google`, and so on. Three reasons not
 * to:
 *
 * - **The claim policy already prevents it.** Under `derived` (12.7, what the
 *   official registry runs) a scope may only be claimed by the account whose
 *   provider identity *is* that name, so `@microsoft` is claimable only by the
 *   GitHub account called `microsoft`. The provider is the allocator, and it
 *   settled the question before this registry saw it. A brand list would only
 *   add anything under `firstcome`.
 * - **The list has no edge.** Every trademark in every jurisdiction is the true
 *   extent of it, so any actual list is a handful of famous names and a false
 *   sense of coverage. Whoever reads it will assume the absent ones were
 *   considered.
 * - **It promises adjudication this registry cannot perform.** Reserving
 *   `microsoft` implies somebody is deciding who deserves it. Nobody here is.
 *   The dispute path in section 10 is the honest mechanism, and it is reactive
 *   by design.
 *
 * A private deployment with different needs supplies its own list; that is why
 * this is data rather than a rule.
 * @module reserved
 * @example
 * import "./reserved.j" as reserved;
 * def held as list of string init reserved.defaults();
 */

use strings;
use maps;
import "./deckname.j" as deckname;

/**
 * Scopes that would read as the registry speaking for itself, or as a
 * privileged authority. A deck published under any of these inherits trust the
 * registry never granted.
 * @return {list of string} the reserved names
 */
export func authority() {
    return [
        "official", "admin", "administrator", "root", "superuser", "sudo",
        "system", "security", "abuse", "legal", "moderator", "moderation",
        "staff", "team", "owner", "support", "help", "contact", "billing",
        "trust", "verified", "core", "internal"
    ];
}

/**
 * Scopes that read as infrastructure rather than as somebody's namespace. These
 * are the ones a reader mistakes for part of the service, and the ones most
 * likely to collide with a future route or subdomain.
 * @return {list of string} the reserved names
 */
export func infrastructure() {
    return [
        "api", "www", "web", "app", "cdn", "static", "assets", "media",
        "registry", "index", "search", "health", "status", "metrics",
        "deck", "decks", "docs", "doc", "manual", "reference", "spec", "specs",
        "download", "downloads", "mirror", "mirrors", "packages", "repo"
    ];
}

/**
 * The project's own names. Held so the registry, the client, and the language
 * cannot be impersonated by whoever registers first.
 * @return {list of string} the reserved names
 */
export func project() {
    return [
	    "jennifer", "jvc", "grimoire", "deck", "registry", 
        "deckregistry", "jennifer-lang"
	];
}

/**
 * Placeholder names. Not dangerous, but a deck under `@test` or `@example` is
 * noise in a shared namespace, and `@null` / `@undefined` are the strings a
 * broken client sends when it means nothing at all.
 * @return {list of string} the reserved names
 */
export func placeholder() {
    return [
        "test", "testing", "example", "examples", "sample", "samples", "demo",
        "tmp", "temp", "foo", "bar", "baz", "null", "undefined", "none",
        "nil", "unknown", "anonymous", "nobody", "default"
    ];
}

/**
 * Every reserved scope, deduplicated and folded.
 *
 * Grouped above by *why* each name is held, because a list this long is
 * otherwise unmaintainable: the next person needs to know which pile a
 * candidate belongs in, and whether it belongs in any.
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
 * Is every default a name the grammar would actually accept?
 *
 * A reserved scope that could never be claimed anyway is dead weight, and worse,
 * it hides a typo: `jennifer-lang` reserves something real, `jennifer_lang`
 * reserves nothing and nobody notices. Exported so a test asserts it rather than
 * a reader trusting it.
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
