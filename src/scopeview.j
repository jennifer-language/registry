# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The scope surface over HTTP, as pure data: claiming one, listing them, and
 * changing who may write under one.
 *
 * `scope.claim` and `scope.authorise` make the decisions; this module maps their
 * answers to statuses and bodies, as `apiview` and `publishview` do.
 * @module scopeview
 * @example
 * import "./scopeview.j" as scopeview;
 * def out as scopeview.ScopeReply init scopeview.claim($db, $pol, $who, "alice",
 *     $reserved, $now);
 * # if (out.changed) { store.save(out.db); }
 */

use json;
use strings;
import "flatdb.j" as flatdb;
import "./store.j" as store;
import "./scope.j" as scope;
import "./policy.j" as policy;
import "./identity.j" as identity;
import "./deckname.j" as deckname;
import "./audit.j" as audit;

/**
 * The outcome of a scope operation: the response, and the store it wants saved.
 * @field status {int} the HTTP status
 * @field body {json.Value} the response body
 * @field db {flatdb.DB} the resulting store
 * @field changed {bool} true when the store was edited and should be saved
 * @field event {audit.Event} what to record in the operational log
 */
export def struct ScopeReply {
    status as int,
    body as json.Value,
    db as flatdb.DB,
    changed as bool,
    event as audit.Event
};

func refuse(db as flatdb.DB, status as int, reason as string) {
    def body as json.Value init json.map();
    $body = json.set($body, "/error", $reason);
    return ScopeReply{status: $status, body: $body, db: $db, changed: false, event: audit.none()};
}

/**
 * The HTTP status for a refused claim: `400` for a malformed name, `409` for a
 * name already held (as for a duplicate publish), `403` for a policy refusal.
 * Exported so the mapping is tested directly.
 * @param reason {string} the refusal from `scope.claim`
 * @return {int} the HTTP status to answer with
 */
export func claimStatus(reason as string) {
    if (strings.contains($reason, "not a valid scope name")) {
        return 400;
    }
    if (strings.contains($reason, "already yours")) {
        return 409;
    }
    if (strings.contains($reason, "another account")) {
        return 409;
    }
    if (strings.contains($reason, "reserved by this registry")) {
        return 409;
    }
    return 403;
}

/**
 * Claim a scope for the authenticated caller (specification 8.2).
 *
 * The policy decides whether a self-service claim is allowed: under `derived`,
 * only the caller's own login or an organisation it belongs to; under
 * `firstcome`, any unreserved scope; under `operator`, never.
 * @param db {flatdb.DB} the store
 * @param pol {policy.Policy} the deployment's claim policy
 * @param who {identity.Subject} the authenticated caller
 * @param name {string} the scope being asked for
 * @param reserved {list of string} names the deployment holds back
 * @param now {string} the timestamp (Unix seconds as text)
 * @return {ScopeReply} the outcome, and the store to persist on success
 */
export func claim(
    db as flatdb.DB,
    pol as policy.Policy,
    who as identity.Subject,
    name as string,
    reserved as list of string,
    now as string) {
    if (strings.trim($name) == "") {
        return refuse($db, 400, "missing `scope`");
    }
    def out as scope.ClaimResult init scope.claim($db, $pol, $who, $name, $reserved, $now);
    if (not $out.allowed) {
        return refuse($db, claimStatus($out.reason), $out.reason);
    }
    def folded as string init deckname.fold($name);
    def body as json.Value init json.map();
    $body = json.set($body, "/scope", $folded);
    $body = json.set($body, "/owner", $who.login);
    return ScopeReply{
        status: 201,
        body: $body,
        db: $out.db,
        changed: true,
        event: audit.scopeRegistered($folded, $who.provider, $who.id, $who.login, false)
    };
}

/**
 * Add or remove a co-owner. Only the scope's owner may change the list
 * (specification 2.2); a compromised co-owner could otherwise add accounts that
 * keep write access after its removal, or remove the others.
 * @param db {flatdb.DB} the store
 * @param who {identity.Subject} the authenticated caller
 * @param name {string} the scope
 * @param subject {string} the principal to add or remove
 * @param add {bool} true to add, false to remove
 * @param now {string} unused; kept so the shape matches its siblings
 * @return {ScopeReply} the outcome, and the store to persist on success
 */
export func owners(
    db as flatdb.DB,
    who as identity.Subject,
    name as string,
    subject as string,
    add as bool,
    now as string) {
    def folded as string init deckname.fold(strings.trim($name));
    if (strings.startsWith($folded, "@")) {
        $folded = strings.substring($folded, 1, len($folded));
    }
    if ($folded == "" or strings.trim($subject) == "") {
        return refuse($db, 400, "missing `scope` or `subject`");
    }
    if (not store.hasNamespace($db, $folded)) {
        return refuse($db, 404, "@" + $folded + " is not a registered scope");
    }
    if (not isSubjectId(strings.trim($subject))) {
        return refuse($db, 400, "`subject` is an account id, in digits: " + $subject);
    }
    # Asked of the scope first, so a stranger hears what they would hear on any
    # write; then narrowed to the owner, since `authorise` admits co-owners too.
    def verdict as policy.Decision init scope.authorise($db, $who, $folded);
    if (not $verdict.allowed) {
        return refuse($db, 403, $verdict.reason);
    }
    def ns as store.Namespace init store.getNamespace($db, $folded);
    if (not ($ns.provider == $who.provider and $ns.subject == $who.id)) {
        return refuse($db, 403, "only the owner of @" + $folded + " may change its co-owners");
    }
    if ($ns.subject == strings.trim($subject) and not $add) {
        return refuse(
            $db,
            409,
            "the owner of @" + $folded +
                " cannot be removed as a co-owner; ask an operator to reassign it");
    }
    def before as int init len(store.ownersOf($db, $folded));
    def out as flatdb.DB init $db;
    if ($add) {
        $out = store.addCoOwner($db, $folded, strings.trim($subject));
    } else {
        $out = store.removeCoOwner($db, $folded, strings.trim($subject));
    }
    if (len(store.ownersOf($out, $folded)) == $before) {
        # No change: adding an existing co-owner is idempotent; removing an
        # absent one is a 404.
        if ($add) {
            return ScopeReply{
                status: 200,
                body: ownersBody($out, $folded),
                db: $db,
                changed: false,
                event: audit.none()
            };
        }
        return refuse($db, 404, strings.trim($subject) + " is not a co-owner of @" +
            $folded);
    }
    def event as audit.Event init audit.coOwnerAdded($folded, $ns.provider, strings.trim($subject));
    if (not $add) {
        $event = audit.coOwnerRemoved($folded, $ns.provider, strings.trim($subject));
    }
    return ScopeReply{
        status: 200,
        body: ownersBody($out, $folded),
        db: $out,
        changed: true,
        event: $event
    };
}

# isSubjectId reports whether s is a canonical account id: digits, no sign, no
# leading zero, at most 18 digits. A non-canonical spelling would match nobody,
# or a differently spelled id.
func isSubjectId(s as string) {
    if (len($s) == 0 or len($s) > 18 or (len($s) > 1 and strings.startsWith($s, "0"))) {
        return false;
    }
    for (def ch in strings.chars($s)) {
        if ($ch < "0" or $ch > "9") {
            return false;
        }
    }
    return true;
}

# ownersBody renders a scope's principals.
func ownersBody(db as flatdb.DB, folded as string) {
    def ns as store.Namespace init store.getNamespace($db, $folded);
    def body as json.Value init json.map();
    $body = json.set($body, "/scope", $folded);
    $body = json.set($body, "/provider", $ns.provider);
    $body = json.set($body, "/kind", $ns.kind);
    def ids as json.Value init json.list();
    for (def one in store.ownersOf($db, $folded)) {
        $ids = json.append($ids, "", $one);
    }
    $body = json.set($body, "/owners", $ids);
    return $body;
}

/**
 * Every registered scope, with who holds it.
 *
 * Reports the login, not the subject id: the login is already public on deck
 * pages, while a public list of the ids ownership binds to would help an
 * impersonator. A caller's own id is in their token.
 * @param db {flatdb.DB} the store
 * @return {ScopeReply} a 200 listing the scopes
 */
export func listScopes(db as flatdb.DB) {
    def arr as json.Value init json.list();
    for (def name in store.listNamespaces($db)) {
        def ns as store.Namespace init store.getNamespace($db, $name);
        def one as json.Value init json.map();
        $one = json.set($one, "/scope", $ns.scope);
        $one = json.set($one, "/kind", $ns.kind);
        if ($ns.subject == "") {
            $one = json.set($one, "/status", "reserved");
        } else {
            $one = json.set($one, "/status", "owned");
            $one = json.set($one, "/owner", $ns.login);
        }
        $arr = json.append($arr, "", $one);
    }
    def body as json.Value init json.map();
    $body = json.set($body, "/scopes", $arr);
    return ScopeReply{status: 200, body: $body, db: $db, changed: false, event: audit.none()};
}
