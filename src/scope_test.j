# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for scope.j. Run with:
#
#     jennifer test src/scope_test.j
#
# This module carries the decisions section 8 is about, so the tests are written
# against the properties rather than the implementation: a rename must not move a
# scope, a released username must not inherit one, and a refusal must say which
# of several causes applied.

use testing;
import "./policy/derived.j" as derived;
import "./policy/firstcome.j" as firstcome;
import "./policy/operator.j" as operatorPolicy;

def const NOW as string init "1700000000";

func emptyDb() {
    return store.open("/no/such/jvc/scope/missing.json");
}

func noReserved() {
    def none as list of string init [];
    return $none;
}

# alice is the ordinary caller: GitHub subject 1234567, username "alice".
func alice() {
    return identity.Subject{ provider: "github", id: "1234567", login: "alice" };
}

# mallory holds the *same username* alice used to have, on a different account.
# This is the case section 8.1 exists for.
func mallory() {
    return identity.Subject{ provider: "github", id: "9999999", login: "alice" };
}

# --- claiming ---------------------------------------------------------------

func testAClaimBindsTheScopeToTheSubject() {
    def out as ClaimResult init claim(emptyDb(), derived.policy(), alice(), "alice",
        noReserved(), NOW);
    testing.assertTrue($out.allowed);
    testing.assertTrue($out.changed);
    def ns as store.Namespace init store.getNamespace($out.db, "alice");
    # the id is what binds; the login rides along as a label
    testing.assertEqual($ns.subject, "1234567");
    testing.assertEqual($ns.provider, "github");
    testing.assertEqual($ns.login, "alice");
}

func testAClaimIsFolded() {
    def out as ClaimResult init claim(emptyDb(), firstcome.policy(), alice(), "@ACME",
        noReserved(), NOW);
    testing.assertFalse($out.allowed);
    # "@ACME" is not a scope name; the @ belongs to the deck name, not the scope
    def ok as ClaimResult init claim(emptyDb(), firstcome.policy(), alice(), "ACME",
        noReserved(), NOW);
    testing.assertTrue($ok.allowed);
    testing.assertTrue(store.hasNamespace($ok.db, "acme"));
}

func testAMalformedScopeIsRefusedBeforeAnythingElse() {
    # told what is wrong with the name, not that it is unavailable
    def out as ClaimResult init claim(emptyDb(), firstcome.policy(), alice(), "a--b",
        noReserved(), NOW);
    testing.assertFalse($out.allowed);
    testing.assertContains($out.reason, "not a valid scope name");
}

func testAnUnauthenticatedCallerClaimsNothing() {
    def nobody as identity.Subject init identity.Subject{
        provider: "", id: "", login: ""
    };
    def out as ClaimResult init claim(emptyDb(), firstcome.policy(), $nobody, "acme",
        noReserved(), NOW);
    testing.assertFalse($out.allowed);
}

func testThePolicyGatesTheClaim() {
    # the same request, three policies, three answers
    def db as flatdb.DB init emptyDb();
    testing.assertTrue(claim($db, firstcome.policy(), alice(), "acme",
        noReserved(), NOW).allowed);
    testing.assertFalse(claim($db, derived.policy(), alice(), "acme",
        noReserved(), NOW).allowed);
    testing.assertFalse(claim($db, operatorPolicy.policy(), alice(), "alice",
        noReserved(), NOW).allowed);
}

func testAReservedScopeIsRefused() {
    def out as ClaimResult init claim(emptyDb(), firstcome.policy(), alice(), "jennifer",
        ["jennifer"], NOW);
    testing.assertFalse($out.allowed);
    testing.assertContains($out.reason, "reserved");
}

# --- the rename case --------------------------------------------------------

func claimed() {
    return claim(emptyDb(), derived.policy(), alice(), "alice", noReserved(), NOW).db;
}

func testWhoeverTakesAReleasedUsernameDoesNotInheritTheScope() {
    # the whole reason ownership binds to an id: mallory holds the username
    # "alice" now, and derived policy would happily let them derive @alice
    def out as ClaimResult init claim(claimed(), derived.policy(), mallory(), "alice",
        noReserved(), NOW);
    testing.assertFalse($out.allowed);
    testing.assertContains($out.reason, "another account");
}

func testTheRefusalDistinguishesTakenFromDisallowed() {
    # a caller re-claiming their own scope is told that, not told it is taken
    def out as ClaimResult init claim(claimed(), derived.policy(), alice(), "alice",
        noReserved(), NOW);
    testing.assertFalse($out.allowed);
    testing.assertContains($out.reason, "already yours");
}

func testARenameDoesNotMoveTheScope() {
    # alice renames to alicia: same id, new login. The scope stays hers.
    def renamed as identity.Subject init identity.Subject{
        provider: "github", id: "1234567", login: "alicia"
    };
    testing.assertTrue(authorise(claimed(), $renamed, "alice").allowed);
}

func testSheMayAlsoClaimTheNewName() {
    def renamed as identity.Subject init identity.Subject{
        provider: "github", id: "1234567", login: "alicia"
    };
    def out as ClaimResult init claim(claimed(), derived.policy(), $renamed, "alicia",
        noReserved(), NOW);
    testing.assertTrue($out.allowed);
}

# --- operator grants --------------------------------------------------------

func testAGrantBypassesThePolicy() {
    # what covers a name the provider does not have: the jennifer-language org
    # cannot derive @jennifer, so an operator binds it
    def out as ClaimResult init grant(emptyDb(), "jennifer", "github", "42", "orgbot", NOW);
    testing.assertTrue($out.allowed);
    testing.assertTrue(store.ownsNamespace($out.db, "jennifer", "github", "42"));
}

func testAGrantWithNoSubjectReservesTheName() {
    def out as ClaimResult init grant(emptyDb(), "jennifer", "", "", "", NOW);
    testing.assertTrue($out.allowed);
    testing.assertContains($out.reason, "operator-held");
    # registered, so nobody may claim it
    testing.assertFalse(claim($out.db, firstcome.policy(), alice(), "jennifer",
        noReserved(), NOW).allowed);
    # and bound to nobody, so nobody may write under it either
    testing.assertFalse(authorise($out.db, alice(), "jennifer").allowed);
}

func testAGrantCanReassign() {
    # a dispute, a departure, or a deleted account (specification 10)
    def db as flatdb.DB init claimed();
    testing.assertTrue(store.ownsNamespace($db, "alice", "github", "1234567"));
    def out as ClaimResult init grant($db, "alice", "github", "9999999", "alice", NOW);
    testing.assertTrue($out.allowed);
    testing.assertFalse(store.ownsNamespace($out.db, "alice", "github", "1234567"));
    testing.assertTrue(store.ownsNamespace($out.db, "alice", "github", "9999999"));
}

func testAGrantRejectsAMalformedScope() {
    testing.assertFalse(grant(emptyDb(), "a--b", "github", "1", "x", NOW).allowed);
}

# --- authorising a write ----------------------------------------------------

func testTheOwnerMayWrite() {
    testing.assertTrue(authorise(claimed(), alice(), "alice").allowed);
}

func testAStrangerMayNot() {
    def out as policy.Decision init authorise(claimed(), mallory(), "alice");
    testing.assertFalse($out.allowed);
    testing.assertContains($out.reason, "belongs to");
}

func testAnUnregisteredScopeIsNotAWriteTarget() {
    def out as policy.Decision init authorise(emptyDb(), alice(), "nobody");
    testing.assertFalse($out.allowed);
    testing.assertContains($out.reason, "not a registered scope");
}

func testAuthorisationIgnoresTheProviderWhenItDiffers() {
    # the same numeric id from a different provider is a different principal
    def elsewhere as identity.Subject init identity.Subject{
        provider: "gitea", id: "1234567", login: "alice"
    };
    testing.assertFalse(authorise(claimed(), $elsewhere, "alice").allowed);
}

func testAuthorisationFoldsTheScope() {
    testing.assertTrue(authorise(claimed(), alice(), "ALICE").allowed);
}

func testScopeOfDeckIsTheAuthorisationTarget() {
    testing.assertEqual(scopeOfDeck("@Acme/Tool"), "acme");
    testing.assertEqual(scopeOfDeck("bare"), "");
}
