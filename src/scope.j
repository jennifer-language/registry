# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Claiming a scope, and authorising a write under one. The store holds the
 * binding, the policy decides whether a self-claim is allowed, and an identity
 * provider supplies the subject.
 *
 * - `claim` is a one-time proof, gated by policy.
 * - `authorise` runs on every later write and consults only the recorded
 *   binding, never the policy or the provider, so a rename changes nothing and
 *   whoever takes a released username does not inherit a scope (8.1, 8.3).
 *
 * Pure except for the store: no network, no clock. `now` is a parameter.
 * @module scope
 * @example
 * import "./scope.j" as scope;
 * def out as scope.ClaimResult init scope.claim($db, $pol, $who, "acme", $reserved, $now);
 * # if (out.changed) { store.save(out.db); }
 */

use maps;
import "flatdb.j" as flatdb;
import "./store.j" as store;
import "./policy.j" as policy;
import "./identity.j" as identity;
import "./deckname.j" as deckname;

/**
 * The outcome of a claim: the decision, and the store it wants persisted.
 * @field allowed {bool} whether the scope was claimed
 * @field reason {string} why, phrased for the person who will read it
 * @field db {flatdb.DB} the resulting store
 * @field changed {bool} true when the store was edited and should be saved
 */
export def struct ClaimResult {
    allowed as bool,
    reason as string,
    db as flatdb.DB,
    changed as bool
};

# refuse builds a ClaimResult that leaves the store untouched.
func refuse(db as flatdb.DB, reason as string) {
    return ClaimResult{allowed: false, reason: $reason, db: $db, changed: false};
}

/**
 * Attempt a self-service claim of a scope.
 *
 * Checks run in order: the name, then whether the scope is taken, then the
 * policy, so a malformed name or somebody else's scope is reported as such
 * rather than as a policy refusal.
 * @param db {flatdb.DB} the store to read and edit
 * @param pol {policy.Policy} the deployment's policy
 * @param who {identity.Subject} the authenticated caller
 * @param scope {string} the scope being asked for
 * @param reserved {list of string} the deployment's reserved names
 * @param now {string} the registration timestamp (Unix seconds as text)
 * @return {ClaimResult} the decision and the store to persist
 */
export func claim(
    db as flatdb.DB,
    pol as policy.Policy,
    who as identity.Subject,
    scope as string,
    reserved as list of string,
    now as string) {
    def folded as string init deckname.fold($scope);
    if (not deckname.isScopeIdent($folded)) {
        return refuse($db, "@" + $folded + " is not a valid scope name");
    }
    if ($who.id == "") {
        return refuse($db, "an unauthenticated caller cannot claim a scope");
    }
    if (store.hasNamespace($db, $folded)) {
        # The caller may hold that username today while an earlier holder still
        # owns the scope (specification 8.2), so the refusal says which case.
        if (store.ownsNamespace($db, $folded, $who.provider, $who.id)) {
            return refuse($db, "@" + $folded + " is already yours");
        }
        # A registered scope with no owner is reserved, not claimed by anyone.
        if (store.getNamespace($db, $folded).subject == "") {
            return refuse(
                $db,
                "@" + $folded + " is reserved by this registry; " +
                    "ask an operator if you have a claim to it");
        }
        return refuse(
            $db,
            "@" + $folded + " is claimed by another account; " +
                "an operator can reassign it if that is wrong");
    }
    def verdict as policy.Decision init $pol.mayClaim($who, $folded, $reserved);
    if (not $verdict.allowed) {
        return refuse($db, $verdict.reason);
    }
    # Claiming an organisation binds the scope to the organisation's id, not the
    # claimant's (8.7); every later write re-checks membership.
    def owner as string init $who.id;
    def label as string init $who.login;
    def kind as string init store.SCOPE_USER;
    if (maps.has($who.orgs, $folded)) {
        $owner = $who.orgs[$folded];
        $label = $folded;
        $kind = store.SCOPE_ORG;
    }
    def out as flatdb.DB init store.registerNamespace(
        $db,
        store.Namespace{
            scope: $folded,
            provider: $who.provider,
            subject: $owner,
            login: $label,
            registeredAt: $now,
            kind: $kind,
            coOwners: []
        });
    return ClaimResult{allowed: true, reason: $verdict.reason, db: $out, changed: true};
}

/**
 * Grant a scope to a principal, as an operator. Bypasses the policy: an operator
 * grant covers what derivation cannot, such as a name the provider does not
 * have, an organisation, a dispute, or a reassignment (specification 8.2).
 *
 * An empty `subject` registers the scope operator-held: nobody may claim it or
 * write under it.
 * @param db {flatdb.DB} the store to edit
 * @param scope {string} the scope to grant
 * @param provider {string} the identity provider that issued the subject
 * @param subject {string} the principal to bind it to ("" to hold it unowned)
 * @param login {string} the owner's username, a display label
 * @param now {string} the registration timestamp (Unix seconds as text)
 * @return {ClaimResult} the decision and the store to persist
 */
export func grant(
    db as flatdb.DB,
    scope as string,
    provider as string,
    subject as string,
    login as string,
    now as string) {
    return grantAs($db, $scope, $provider, $subject, $login, store.SCOPE_USER, $now);
}

/**
 * Grant a scope, saying whether its principal is a person or an organisation.
 *
 * A user scope compares the caller's own id; an organisation scope asks whether
 * they are an active member (8.7). `store` reads an unrecognised kind as `user`,
 * the narrower one.
 * @param db {flatdb.DB} the store to edit
 * @param scope {string} the scope to grant
 * @param provider {string} the identity provider that issued the subject
 * @param subject {string} the principal, or "" to hold it unowned
 * @param login {string} the owner's name, a display label
 * @param kind {string} `store.SCOPE_USER` or `store.SCOPE_ORG`
 * @param now {string} the registration timestamp (Unix seconds as text)
 * @return {ClaimResult} the decision and the store to persist
 */
export func grantAs(
    db as flatdb.DB,
    scope as string,
    provider as string,
    subject as string,
    login as string,
    kind as string,
    now as string) {
    def folded as string init deckname.fold($scope);
    if (not deckname.isScopeIdent($folded)) {
        return refuse($db, "@" + $folded + " is not a valid scope name");
    }
    def out as flatdb.DB init store.registerNamespace(
        $db,
        store.Namespace{
            scope: $folded,
            provider: $provider,
            subject: $subject,
            login: $login,
            registeredAt: $now,
            kind: $kind,
            coOwners: []
        });
    def what as string init "granted @" + $folded;
    if ($kind == store.SCOPE_ORG) {
        $what = "granted @" + $folded + " to an organisation";
    }
    if ($subject == "") {
        $what = "reserved @" + $folded + " (operator-held, unowned)";
    }
    return ClaimResult{allowed: true, reason: $what, db: $out, changed: true};
}

/**
 * Whether the caller may write under a scope; asked by every publish, yank, and
 * owner change. Answered from the recorded binding alone: policy governs who may
 * acquire a scope, not what its owner does with it.
 * @param db {flatdb.DB} the store to read
 * @param who {identity.Subject} the authenticated caller
 * @param scope {string} the scope being written under
 * @return {policy.Decision} allow, or refuse with the reason
 */
export func authorise(db as flatdb.DB, who as identity.Subject, scope as string) {
    def folded as string init deckname.fold($scope);
    if (not store.hasNamespace($db, $folded)) {
        return policy.deny("@" + $folded + " is not a registered scope");
    }
    def ns as store.Namespace init store.getNamespace($db, $folded);
    if ($ns.kind == store.SCOPE_ORG) {
        return authoriseOrg($ns, $who, $folded);
    }
    if (store.ownsNamespace($db, $folded, $who.provider, $who.id)) {
        return policy.allow("@" + $folded + " is yours");
    }
    if ($ns.subject == "") {
        return policy.deny("@" + $folded +
            " is held by an operator and has no owner to publish under it");
    }
    def owner as string init $ns.login;
    if ($owner == "") {
        $owner = "another account";
    }
    return policy.deny("@" + $folded + " belongs to " + $owner);
}

# authoriseOrg answers for a scope owned by an organisation (specification 8.7).
#
# Any active member qualifies, from the memberships captured at login (8.4);
# the provider module already excludes `pending` invitations and
# `billing_manager`. Memberships are only as fresh as the last login. The 8.7
# window is enforced upstream: `authview.refresh` refuses a login whose
# memberships are older than `Config.orgMaxAge`, and a refresh never advances
# `orgsCheckedAt`, so they age out within that plus one bearer TTL.
func authoriseOrg(ns as store.Namespace, who as identity.Subject, folded as string) {
    if (not ($ns.provider == $who.provider)) {
        return policy.deny("@" + $folded + " belongs to an organisation on " +
            $ns.provider);
    }
    for (def name in $who.orgs) {
        if ($who.orgs[$name] == $ns.subject) {
            return policy.allow("@" + $folded + " is your organisation");
        }
    }
    def label as string init $ns.login;
    if ($label == "") {
        $label = "an organisation";
    }
    return policy.deny("@" + $folded + " belongs to " + $label +
        ", and you are not an active member of it");
}

/**
 * The folded scope of a deck name, which an operation on that deck is
 * authorised against.
 * @param name {string} the deck name
 * @return {string} the folded scope, or "" for a bare name
 */
export func scopeOfDeck(name as string) {
    return deckname.scopeOf($name);
}
