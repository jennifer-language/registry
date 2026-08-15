# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The policy interface: what a deployment permits, as opposed to what the
 * outside world reports.
 *
 * A deployment names three modules - an identity provider, a forge, and a policy
 * (specification 12.6). The first two talk to services. **A policy does not.**
 * It receives facts already gathered - the authenticated subject, the scope being
 * asked for, the outcome of the source-authority check - and answers allow or
 * deny. Two things follow, and both are the point: every decision about who may
 * publish what lands in one small auditable module, and the whole of it is
 * testable without a network.
 *
 * The structs live here rather than in each policy module because a Jennifer
 * struct type is identified by `(module, name)`: three modules each declaring
 * their own `Policy` would declare three incompatible types, and the core could
 * not hold one without knowing which it had.
 *
 * For that same reason the **subject comes from `identity.j`** and is not
 * redeclared here: it is the value an identity provider produced, and a second
 * declaration of the same shape would be a different type that no provider
 * could satisfy.
 *
 * A policy **may only subtract**. It can refuse a claim this document would
 * allow; it can never permit a name outside the naming grammar, because that
 * would emit records a conforming client cannot install.
 * @module policy
 * @example
 * import "./policy/derived.j" as derived;
 * def p as policy.Policy init derived.policy();
 * def d as policy.Decision init $p.mayClaim($subject, "mplx", $reserved);
 */

use strings;

/**
 * An answer, with the reason it was reached. A refusal carries its own
 * explanation because the specification requires refusals to say which of
 * several possible causes applied, rather than returning a bare 403.
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
 * @field nameOk {func} `func(scope, deck) -> Decision`: does this deployment
 *     accept this name? May narrow the grammar, never widen it.
 * @field sourceStance {func} `func() -> string`: "verify" to refuse a publish
 *     whose source authority cannot be established, "record" to accept it and
 *     mark the source unverified.
 */
export def struct Policy {
    name as string,
    mayClaim as func,
    nameOk as func,
    sourceStance as func
};

/**
 * Allow, with a reason.
 * @param reason {string} why it was allowed
 * @return {Decision} an allowing decision
 */
export func allow(reason as string) {
    return Decision{ allowed: true, reason: $reason };
}

/**
 * Refuse, with a reason the caller can be shown.
 * @param reason {string} why it was refused
 * @return {Decision} a refusing decision
 */
export func deny(reason as string) {
    return Decision{ allowed: false, reason: $reason };
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
 * The shared refusal for a reserved scope. Every policy refuses these, so the
 * wording is here rather than repeated three times.
 * @param scope {string} the scope being asked for
 * @return {Decision} a refusing decision naming the cause
 */
export func reservedDenial(scope as string) {
    return deny("the scope @" + $scope + " is reserved; ask an operator");
}

/**
 * The default name check: accept anything the naming grammar accepts. A
 * deployment wanting a narrower namespace supplies its own.
 * @param scope {string} the scope half
 * @param deck {string} the deck half
 * @return {Decision} always allowing
 */
export func acceptAnyName(scope as string, deck as string) {
    return allow("no additional naming restriction");
}
