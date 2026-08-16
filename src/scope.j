# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Claiming a scope, and authorising a write under one. This is where the three
 * halves finally meet: the **store** holds the binding, the **policy** decides
 * whether a self-claim is allowed, and an **identity provider** supplied the
 * subject.
 *
 * Two operations, and the distinction between them is the whole of section 8:
 *
 * - **`claim`** is a one-time proof, gated by policy. It runs once per scope.
 * - **`authorise`** runs on every later write and never consults the policy or
 *   the provider again - only the recorded binding. That is what makes a rename
 *   a non-event and stops whoever later takes a released username inheriting a
 *   scope (8.1, 8.3).
 *
 * Pure except for the store: no network, no clock. `now` is a parameter.
 * @module scope
 * @example
 * import "./scope.j" as scope;
 * def out as scope.ClaimResult init scope.claim($db, $pol, $who, "acme", $reserved, $now);
 * # if (out.changed) { store.save(out.db); }
 */

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
    return ClaimResult{ allowed: false, reason: $reason, db: $db, changed: false };
}

/**
 * Attempt a self-service claim of a scope.
 *
 * The order matters and is normative-ish: the name is checked first, then
 * whether the scope is already taken, then the policy. A caller asking for a
 * malformed name should be told that, not told it is unavailable; and a caller
 * asking for somebody else's scope should be told **that**, rather than being
 * refused by a policy that would otherwise have allowed it. Conflating those
 * two is how a registry ends up returning a bare 403 to a legitimate question.
 * @param db {flatdb.DB} the store to read and edit
 * @param pol {policy.Policy} the deployment's policy
 * @param who {identity.Subject} the authenticated caller
 * @param scope {string} the scope being asked for
 * @param reserved {list of string} the deployment's reserved names
 * @param now {string} the registration timestamp (Unix seconds as text)
 * @return {ClaimResult} the decision and the store to persist
 */
export func claim(db as flatdb.DB, pol as policy.Policy, who as identity.Subject,
        scope as string, reserved as list of string, now as string) {
    def folded as string init deckname.fold($scope);
    if (not deckname.isScopeIdent($folded)) {
        return refuse($db, "@" + $folded + " is not a valid scope name");
    }
    if ($who.id == "") {
        return refuse($db, "an unauthenticated caller cannot claim a scope");
    }
    if (store.hasNamespace($db, $folded)) {
        # Already bound. Say so specifically: the caller may legitimately hold
        # that username today while an earlier holder still owns the scope
        # (specification 8.2), and a generic refusal would read as a bug.
        if (store.ownsNamespace($db, $folded, $who.provider, $who.id)) {
            return refuse($db, "@" + $folded + " is already yours");
        }
        # A registered scope with no owner is *reserved*, not taken. Saying
        # "another account" there would be false and would send the caller
        # looking for a person who does not exist.
        if (store.getNamespace($db, $folded).subject == "") {
            return refuse($db, "@" + $folded + " is reserved by this registry; " +
                "ask an operator if you have a claim to it");
        }
        return refuse($db, "@" + $folded + " is claimed by another account; " +
            "an operator can reassign it if that is wrong");
    }
    def verdict as policy.Decision init $pol.mayClaim($who, $folded, $reserved);
    if (not $verdict.allowed) {
        return refuse($db, $verdict.reason);
    }
    def out as flatdb.DB init store.registerNamespace($db, store.Namespace{
        scope: $folded,
        provider: $who.provider,
        subject: $who.id,
        login: $who.login,
        registeredAt: $now,
        coOwners: []
    });
    return ClaimResult{
        allowed: true, reason: $verdict.reason, db: $out, changed: true
    };
}

/**
 * Grant a scope to a principal, as an operator. **Bypasses the policy**, because
 * an operator grant is the mechanism by which a deployment covers what
 * derivation cannot: a name the provider does not have, an organisation, a
 * dispute, or a reassignment (specification 8.2).
 *
 * An empty `subject` registers the scope **operator-held**: nobody may claim it
 * and nobody may write under it, which is how a name is reserved.
 * @param db {flatdb.DB} the store to edit
 * @param scope {string} the scope to grant
 * @param provider {string} the identity provider that issued the subject
 * @param subject {string} the principal to bind it to ("" to hold it unowned)
 * @param login {string} the owner's username, a display label
 * @param now {string} the registration timestamp (Unix seconds as text)
 * @return {ClaimResult} the decision and the store to persist
 */
export func grant(db as flatdb.DB, scope as string, provider as string,
        subject as string, login as string, now as string) {
    def folded as string init deckname.fold($scope);
    if (not deckname.isScopeIdent($folded)) {
        return refuse($db, "@" + $folded + " is not a valid scope name");
    }
    def out as flatdb.DB init store.registerNamespace($db, store.Namespace{
        scope: $folded,
        provider: $provider,
        subject: $subject,
        login: $login,
        registeredAt: $now,
        coOwners: []
    });
    def what as string init "granted @" + $folded;
    if ($subject == "") {
        $what = "reserved @" + $folded + " (operator-held, unowned)";
    }
    return ClaimResult{ allowed: true, reason: $what, db: $out, changed: true };
}

/**
 * May this caller write under this scope? The question every publish, yank, and
 * owner change asks.
 *
 * Answered from the recorded binding alone. The policy is not consulted: policy
 * governs who may *acquire* a scope, never what its owner may then do with it.
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
    if (store.ownsNamespace($db, $folded, $who.provider, $who.id)) {
        return policy.allow("@" + $folded + " is yours");
    }
    def ns as store.Namespace init store.getNamespace($db, $folded);
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

/**
 * The scope half of a deck name, folded - the scope an operation on that deck
 * is authorised against.
 * @param name {string} the deck name
 * @return {string} the folded scope, or "" for a bare name
 */
export func scopeOfDeck(name as string) {
    return deckname.scopeOf($name);
}
