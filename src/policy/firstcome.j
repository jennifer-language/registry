# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The `firstcome` claim policy: any authenticated subject may claim any scope
 * that is unclaimed and unreserved, as on Packagist and npm.
 *
 * Suited to a registry whose users are already trusted, such as a company's
 * internal one. The scope still binds to the claimant's id, so a username
 * change does not move it.
 *
 * A scope name says nothing about its holder: on a public registry `@microsoft`
 * is an impersonation surface, defended only by the reserved list and operator
 * takedown. Names are cheaper to protect before they are handed out, so avoid
 * it for a registry that may become public.
 * @module firstcome
 * @example
 * import "./firstcome.j" as firstcome;
 * def p as policy.Policy init firstcome.policy();
 */

import "../identity.j" as identity;
import "../policy.j" as policy;

# anyUnreserved allows any claim except a reserved name. Whether the scope is
# taken is checked by the caller against the store.
func anyUnreserved(subject as identity.Subject, scope as string, reserved as list of string) {
    if (policy.isReserved($scope, $reserved)) {
        return policy.reservedDenial($scope);
    }
    return policy.allow("@" + $scope + " is available");
}

# stance asks to record an unverifiable source rather than refuse it: the users
# are trusted, and refusing every forge it cannot query would make it unusable.
# Nothing consults `sourceStance` yet, so publishes are refused all the same.
func stance() {
    return "record";
}

# anyName applies no narrowing. A local wrapper, because a func value can only
# be taken from a locally-defined function.
func anyName(scope as string, deck as string) {
    return policy.acceptAnyName($scope, $deck);
}

/**
 * The first-come policy.
 * @return {policy.Policy} a policy allowing any unreserved scope
 */
export func policy() {
    return policy.Policy{
        name: "firstcome",
        mayClaim: anyUnreserved,
        nameOk: anyName,
        sourceStance: stance
    };
}
