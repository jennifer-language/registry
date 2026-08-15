# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The `derived` claim policy: **a subject may claim the scope matching its own
 * provider username, and nothing else.** This is what the official public
 * registry runs (specification 12.7).
 *
 * It is the strictest self-service option. Nobody claims `@microsoft` without
 * controlling the account of that name, which removes exact impersonation
 * without an approval queue.
 *
 * Two things it does **not** do, both worth knowing before choosing it:
 *
 * - **It does not stop typosquatting.** `@micr0soft` is unclaimed, so somebody
 *   who registers that username upstream may claim it legitimately. Only a
 *   reserved list and takedown address that.
 * - **It cannot express a name the provider does not have.** An organisation
 *   called `jennifer-language` cannot derive `@jennifer`, and an account holding
 *   no matching name derives nothing at all. Those cases need an operator grant,
 *   so a registry running this policy still needs the operator door open.
 *
 * The claim is a **one-time proof**. Once a scope is bound to a subject id, this
 * policy is not consulted again, and a later rename does not move the scope
 * (8.3).
 * @module derived
 * @example
 * import "./derived.j" as derived;
 * def p as policy.Policy init derived.policy();
 */

use strings;
import "../identity.j" as identity;
import "../policy.j" as policy;

# matchesLogin allows a claim only where the folded scope equals the folded
# provider username. Folding both sides is what makes the comparison agree with
# the naming grammar, which stores scopes lowercased.
func matchesLogin(subject as identity.Subject, scope as string, reserved as list of string) {
    if (policy.isReserved($scope, $reserved)) {
        return policy.reservedDenial($scope);
    }
    def want as string init strings.lower(strings.trim($scope));
    def have as string init strings.lower(strings.trim($subject.login));
    if ($have == "") {
        return policy.deny("this identity has no username to derive a scope from");
    }
    if (not ($want == $have)) {
        return policy.deny("@" + $scope + " does not match your " + $subject.provider +
            " username (" + $subject.login + "); ask an operator to grant it");
    }
    return policy.allow("@" + $scope + " matches your " + $subject.provider + " username");
}

# stance refuses a publish whose source authority could not be established. A
# public registry has no basis for trusting an unverifiable source.
func stance() {
    return "verify";
}

# anyName applies no narrowing. It is a local wrapper because a func value can
# only be taken from a locally-defined function: `policy.acceptAnyName` in
# expression position reads as a constant lookup and fails.
func anyName(scope as string, deck as string) {
    return policy.acceptAnyName($scope, $deck);
}

/**
 * The derive-from-username policy.
 * @return {policy.Policy} a policy allowing only a self-named scope
 */
export func policy() {
    return policy.Policy{
        name: "derived",
        mayClaim: matchesLogin,
        nameOk: anyName,
        sourceStance: stance
    };
}
