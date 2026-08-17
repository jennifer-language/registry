# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for scopeview.j. Run with:
#
#     jennifer test src/scopeview_test.j
#
# The decisions live in scope.j and are tested there. What is tested here is the
# translation: which status a caller gets, and whether the answer tells them
# something they can act on.

use testing;
use json;
import "./policy/derived.j" as derived;
import "./policy/operator.j" as operatorPolicy;

def const NOW as string init "1700000000";

func emptyDb() {
    return store.open("/no/such/jvc/scopeview/missing.json");
}

func alice() {
    return identity.Subject{
        provider: "github", id: "1234567", login: "alice",
        orgs: {}, orgsCheckedAt: NOW
    };
}

func stranger() {
    return identity.Subject{
        provider: "github", id: "9999999", login: "mallory",
        orgs: {}, orgsCheckedAt: NOW
    };
}

func none() {
    def empty as list of string init [];
    return $empty;
}

# --- claiming -----------------------------------------------------------------

func testAClaimSucceedsUnderDerived() {
    def out as ScopeReply init claim(emptyDb(), derived.policy(), alice(), "alice",
        none(), NOW);
    testing.assertEqual($out.status, 201);
    testing.assertTrue($out.changed);
    testing.assertEqual(json.asString($out.body, "/scope"), "alice");
    testing.assertTrue(store.ownsNamespace($out.db, "alice", "github", "1234567"));
}

func testTheThreeRefusalsAreDistinguishable() {
    # answering 403 to all of these tells a caller their credentials are wrong
    # when the truth is a typo, a taken name, or a policy that never allows it
    testing.assertEqual(claimStatus("@a--b is not a valid scope name"), 400);
    testing.assertEqual(claimStatus("@alice is already yours"), 409);
    testing.assertEqual(claimStatus("@x is claimed by another account; ..."), 409);
    testing.assertEqual(claimStatus("@admin is reserved by this registry; ..."), 409);
    testing.assertEqual(claimStatus("this registry does not accept self-service claims"), 403);
}

func testAMalformedNameIsTheCallersMistake() {
    def out as ScopeReply init claim(emptyDb(), derived.policy(), alice(), "a--b",
        none(), NOW);
    testing.assertEqual($out.status, 400);
    testing.assertFalse($out.changed);
}

func testAScopeSomebodyElseHoldsIsAConflict() {
    def db as flatdb.DB init claim(emptyDb(), derived.policy(), alice(), "alice",
        none(), NOW).db;
    def out as ScopeReply init claim($db, derived.policy(), stranger(), "alice",
        none(), NOW);
    testing.assertEqual($out.status, 409);
    testing.assertContains(json.asString($out.body, "/error"), "another account");
}

func testAPolicyRefusalIsAPermissionsAnswer() {
    def out as ScopeReply init claim(emptyDb(), operatorPolicy.policy(), alice(),
        "alice", none(), NOW);
    testing.assertEqual($out.status, 403);
}

func testAReservedNameIsRefused() {
    def out as ScopeReply init claim(emptyDb(), derived.policy(), alice(), "alice",
        ["alice"], NOW);
    testing.assertFalse($out.status == 201);
}

func testAMissingScopeIsA400() {
    testing.assertEqual(claim(emptyDb(), derived.policy(), alice(), "", none(),
        NOW).status, 400);
}

func testAClaimIsRecorded() {
    def out as ScopeReply init claim(emptyDb(), derived.policy(), alice(), "alice",
        none(), NOW);
    testing.assertEqual($out.event.fields["scope"], "alice");
    testing.assertEqual($out.event.fields["subject"], "1234567");
}

# --- owners -------------------------------------------------------------------

func owned() {
    return claim(emptyDb(), derived.policy(), alice(), "alice", none(), NOW).db;
}

func testAnOwnerAddsACoOwner() {
    def out as ScopeReply init owners(owned(), alice(), "alice", "999", true, NOW);
    testing.assertEqual($out.status, 200);
    testing.assertTrue($out.changed);
    testing.assertEqual(len(store.ownersOf($out.db, "alice")), 2);
}

func testAStrangerCannotChangeOwners() {
    def out as ScopeReply init owners(owned(), stranger(), "alice", "999", true, NOW);
    testing.assertEqual($out.status, 403);
    testing.assertFalse($out.changed);
}

func testAddingTwiceIsIdempotent() {
    def db as flatdb.DB init owners(owned(), alice(), "alice", "999", true, NOW).db;
    def again as ScopeReply init owners($db, alice(), "alice", "999", true, NOW);
    testing.assertEqual($again.status, 200);
    testing.assertFalse($again.changed);
}

func testRemovingSomebodyWhoIsNotACoOwnerIs404() {
    testing.assertEqual(owners(owned(), alice(), "alice", "999", false, NOW).status, 404);
}

func testTheOwnerCannotBeRemovedThisWay() {
    def out as ScopeReply init owners(owned(), alice(), "alice", "1234567", false, NOW);
    testing.assertEqual($out.status, 409);
    testing.assertContains(json.asString($out.body, "/error"), "reassign");
}

func testAnUnknownScopeIs404() {
    testing.assertEqual(owners(emptyDb(), alice(), "ghost", "999", true, NOW).status, 404);
}

func testAnAtPrefixIsAccepted() {
    # a caller who types the scope the way it appears in a deck name
    testing.assertEqual(owners(owned(), alice(), "@alice", "999", true, NOW).status, 200);
}

# --- listing ------------------------------------------------------------------

func testTheListingReportsOwnedAndReserved() {
    def db as flatdb.DB init owned();
    $db = scope.grant($db, "jennifer", "", "", "", NOW).db;
    def out as ScopeReply init listScopes($db);
    testing.assertEqual($out.status, 200);
    testing.assertEqual(json.length($out.body, "/scopes"), 2);
    testing.assertEqual(json.asString($out.body, "/scopes/0/status"), "owned");
    testing.assertEqual(json.asString($out.body, "/scopes/0/owner"), "alice");
    testing.assertEqual(json.asString($out.body, "/scopes/1/status"), "reserved");
}

func testTheListingDoesNotPublishAccountIds() {
    # a login is on every deck page already; an account id is what ownership
    # binds to, and a public list of them is a list of what an impersonator needs
    def out as ScopeReply init listScopes(owned());
    testing.assertFalse(strings.contains(json.encode($out.body), "1234567"));
}
