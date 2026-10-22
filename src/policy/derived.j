# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The `derived` claim policy: a subject may claim only the scope matching its
 * own provider username, or an organisation it belongs to. The official public
 * registry runs it (specification 12.7).
 *
 * It is the strictest self-service option: nobody claims `@microsoft` without
 * controlling the account of that name, which stops exact impersonation without
 * an approval queue. Limits:
 *
 * - It does not stop typosquatting: whoever registers `micr0soft` upstream may
 *   claim `@micr0soft`. Only a reserved list and takedown address that.
 * - It cannot express a name the provider does not have (the organisation
 *   `jennifer-language` cannot derive `@jennifer`); those need an operator grant.
 *
 * The claim is a one-time proof: once a scope is bound to a subject id, the
 * policy is not consulted again and a rename does not move the scope (8.3).
 * @module derived
 * @example
 * import "./derived.j" as derived;
 * def p as policy.Policy init derived.policy();
 */

use strings;
use maps;
use lists;
import "../identity.j" as identity;
import "../policy.j" as policy;

# matchesLogin allows a claim only where the folded scope equals the folded
# provider username; scopes are stored lowercased.
func matchesLogin(subject as identity.Subject, scope as string, reserved as list of string) {
    if (policy.isReserved($scope, $reserved)) {
        return policy.reservedDenial($scope);
    }
    def want as string init strings.lower(strings.trim($scope));
    def have as string init strings.lower(strings.trim($subject.login));
    if ($have == "") {
        return policy.deny("this identity has no username to derive a scope from");
    }
    if ($want == $have) {
        return policy.allow("@" + $scope + " matches your " + $subject.provider +
            " username");
    }
    # An organisation the caller actively belongs to (8.7). The scope binds to
    # the organisation, not the claimant, so a member who leaves keeps nothing.
    if (maps.has($subject.orgs, $want)) {
        return policy.allow("@" + $scope + " is a " + $subject.provider +
            " organisation you belong to");
    }
    # The refusal lists the organisations the token carries: GitHub withholds
    # any organisation with third-party application restrictions that has not
    # approved this registry, so a member may be missing from the list.
    return policy.deny("@" + $scope + " is neither your " + $subject.provider +
        " username (" + $subject.login + ") nor one of the organisations your " +
        "login carries (" + seenList($subject) + "). If you belong to it, your " +
        $subject.provider + " may not be disclosing it to this registry: " +
        "approve this application for the organisation and log in again, or " +
        "ask an operator to grant the scope");
}

# seenList renders the organisations a token carries, for a refusal message.
func seenList(subject as identity.Subject) {
    if (len($subject.orgs) == 0) {
        return "none";
    }
    return strings.join(lists.sort(maps.keys($subject.orgs)), ", ");
}

# stance refuses a publish whose source authority could not be established.
func stance() {
    return "verify";
}

# anyName applies no narrowing. A local wrapper, because a func value can only
# be taken from a locally-defined function.
func anyName(scope as string, deck as string) {
    return policy.acceptAnyName($scope, $deck);
}

/**
 * The derive-from-username policy.
 * @return {policy.Policy} a policy allowing only a self-named or organisation scope
 */
export func policy() {
    return policy.Policy{
        name: "derived",
        mayClaim: matchesLogin,
        nameOk: anyName,
        sourceStance: stance
    };
}
