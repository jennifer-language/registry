# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The policy interface: what a deployment permits.
 *
 * A deployment names an identity provider, a forge, and a policy (specification
 * 12.6). A policy does no I/O: it receives facts already gathered (the subject,
 * the requested scope, the source-authority outcome) and answers allow or deny,
 * so every publishing decision sits in one auditable, network-free module.
 *
 * The structs live here because a struct type is identified by
 * `(module, name)`: a `Policy` declared in each policy module would be three
 * incompatible types. For the same reason the subject is `identity.Subject`,
 * not redeclared.
 *
 * A policy may only subtract. It can refuse a claim the specification allows,
 * never permit a name outside the naming grammar, since a conforming client
 * could not install the record.
 * @module policy
 * @example
 * import "./policy/derived.j" as derived;
 * def p as policy.Policy init derived.policy();
 * def d as policy.Decision init $p.mayClaim($subject, "mplx", $reserved);
 */

use strings;

/**
 * An answer, with its reason. The specification requires a refusal to name its
 * cause.
 * @field allowed {bool} whether the action is permitted
 * @field reason {string} why, phrased for the person who will read it
 */
export def struct Decision {
    allowed as bool,
    reason as string
};

/**
 * A deployment's policy, as a set of pure predicates.
 * @field name {string} the policy's name, as configured
 * @field mayClaim {func} `func(identity.Subject, scope, reserved) -> Decision`:
 *     may this subject self-claim this scope? Operator grants skip this.
 */
export def struct Policy {
    name as string,
    mayClaim as func
};

/**
 * Allow, with a reason.
 * @param reason {string} why it was allowed
 * @return {Decision} an allowing decision
 */
export func allow(reason as string) {
    return Decision{allowed: true, reason: $reason};
}

/**
 * Refuse, with a reason the caller can be shown.
 * @param reason {string} why it was refused
 * @return {Decision} a refusing decision
 */
export func deny(reason as string) {
    return Decision{allowed: false, reason: $reason};
}

/**
 * Report whether a scope is on the reserved list. The comparison is against the
 * folded name, so reserving `Jennifer` also reserves `jennifer`.
 * @param scope {string} the scope being asked for
 * @param reserved {list of string} the deployment's reserved names
 * @return {bool} true when the scope is reserved
 */
export func isReserved(scope as string, reserved as list of string) {
    def want as string init strings.lower(strings.trim($scope));
    for (def name in $reserved) {
        if (strings.lower(strings.trim($name)) == $want) {
            return true;
        }
    }
    return false;
}

/**
 * The refusal every policy gives for a reserved scope.
 * @param scope {string} the scope being asked for
 * @return {Decision} a refusing decision naming the cause
 */
export func reservedDenial(scope as string) {
    return deny("the scope @" + $scope + " is reserved; ask an operator");
}

