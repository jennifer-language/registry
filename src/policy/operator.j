# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The `operator` claim policy: nobody self-claims; every scope is granted by an
 * operator.
 *
 * The recommended default for a private registry (specification 12.6), where
 * namespaces map onto teams rather than usernames. It is the strictest option.
 * @module operator
 * @example
 * import "./operator.j" as operator;
 * def p as policy.Policy init operator.policy();
 */

import "../identity.j" as identity;
import "../policy.j" as policy;

# refuse declines every self-claim. Operator grants do not pass through `mayClaim`.
func refuse(subject as identity.Subject, scope as string, reserved as list of string) {
    return policy.deny("this registry does not accept self-service scope claims; " +
        "ask an operator to grant @" + $scope);
}

/**
 * The operator-only policy.
 * @return {policy.Policy} a policy that refuses every self-claim
 */
export func policy() {
    return policy.Policy{name: "operator", mayClaim: refuse};
}
