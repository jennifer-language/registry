# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The `firstcome` claim policy: **any authenticated subject may claim any scope
 * that is unclaimed and unreserved.** This is what Packagist and npm do, and it
 * is the least friction a registry can offer.
 *
 * Choose it when the people using the registry are already trusted - a company's
 * internal registry, where an approval queue buys nothing and slows everyone
 * down. The store still binds the scope to the claiming subject's id, so a
 * username change never moves it and nobody else can take it afterwards.
 *
 * What it gives up is that a scope name means nothing about who holds it.
 * `@microsoft` proves only that somebody asked first. On a public registry that
 * is an impersonation surface, and the only defences are the reserved list and
 * an operator willing to take names back. **Names are far cheaper to protect
 * before they are handed out than after**, so a registry that may one day be
 * public should think twice about starting here.
 * @module firstcome
 * @example
 * import "./firstcome.j" as firstcome;
 * def p as policy.Policy init firstcome.policy();
 */

import "../identity.j" as identity;
import "../policy.j" as policy;

# anyUnreserved allows any claim except a reserved name. Whether the scope is
# already taken is the store's question, not the policy's: this predicate is pure
# and sees no database.
func anyUnreserved(subject as identity.Subject, scope as string, reserved as list of string) {
    if (policy.isReserved($scope, $reserved)) {
        return policy.reservedDenial($scope);
    }
    return policy.allow("@" + $scope + " is available");
}

# stance records an unverifiable source rather than refusing it. A registry
# choosing first-come has already decided its users are trusted, and refusing
# every self-hosted forge it cannot query would make it unusable.
func stance() {
    return "record";
}

# anyName applies no narrowing. It is a local wrapper because a func value can
# only be taken from a locally-defined function: `policy.acceptAnyName` in
# expression position reads as a constant lookup and fails.
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
