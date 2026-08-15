# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The `operator` claim policy: **nobody self-claims anything.** Every scope
 * exists because an operator granted it to a subject.
 *
 * This is the recommended default for a private registry (specification 12.6).
 * Self-service claiming exists to settle competition for names between
 * strangers; inside an organisation there are no strangers, and an
 * operator-granted namespace maps onto teams rather than onto whichever username
 * somebody happens to hold.
 *
 * It is also the strictest option, and the only one under which a namespace can
 * be planned rather than discovered.
 * @module operator
 * @example
 * import "./operator.j" as operator;
 * def p as policy.Policy init operator.policy();
 */

import "../identity.j" as identity;
import "../policy.j" as policy;

# refuse declines every self-claim. An operator grant does not pass through
# `mayClaim` at all, so this is not a refusal of the operator, only of the user.
func refuse(subject as identity.Subject, scope as string, reserved as list of string) {
    return policy.deny("this registry does not accept self-service scope claims; " +
        "ask an operator to grant @" + $scope);
}

# stance refuses a publish whose source authority could not be established.
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
 * The operator-only policy.
 * @return {policy.Policy} a policy that refuses every self-claim
 */
export func policy() {
    return policy.Policy{
        name: "operator",
        mayClaim: refuse,
        nameOk: anyName,
        sourceStance: stance
    };
}
