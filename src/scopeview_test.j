# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for scopeview.j. Run with:
#
#     jennifer test src/scopeview_test.j
#
# The decisions are tested in scope_test.j; these test the statuses and bodies.

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
        provider: "github",
        id: "1234567",
        login: "alice",
        orgs: {},
        orgsCheckedAt: NOW
    };
}

func stranger() {
    return identity.Subject{
        provider: "github",
        id: "9999999",
        login: "mallory",
        orgs: {},
        orgsCheckedAt: NOW
    };
}

func none() {
    def empty as list of string init [];
    return $empty;
}

# --- claiming -----------------------------------------------------------------

func testAClaimSucceedsUnderDerived() {
    def out as ScopeReply init claim(emptyDb(), derived.policy(), alice(), "alice", none(), NOW);
    testing.assertEqual($out.status, 201);
    testing.assertTrue($out.changed);
    testing.assertEqual(json.asString($out.body, "/scope"), "alice");
    testing.assertTrue(store.ownsNamespace($out.db, "alice", "github", "1234567"));
}

func testTheThreeRefusalsAreDistinguishable() {
    # a typo, a taken name and a policy refusal each get their own status
    testing.assertEqual(claimStatus("@a--b is not a valid scope name"), 400);
    testing.assertEqual(claimStatus("@alice is already yours"), 409);
    testing.assertEqual(claimStatus("@x is claimed by another account; ..."), 409);
    testing.assertEqual(claimStatus("@admin is reserved by this registry; ..."), 409);
    testing.assertEqual(claimStatus("this registry does not accept self-service claims"), 403);
}

func testAMalformedNameIsTheCallersMistake() {
    def out as ScopeReply init claim(emptyDb(), derived.policy(), alice(), "a--b", none(), NOW);
    testing.assertEqual($out.status, 400);
    testing.assertFalse($out.changed);
}

func testAScopeSomebodyElseHoldsIsAConflict() {
    def db as flatdb.DB init claim(emptyDb(), derived.policy(), alice(), "alice", none(), NOW).db;
    def out as ScopeReply init claim($db, derived.policy(), stranger(), "alice", none(), NOW);
    testing.assertEqual($out.status, 409);
    testing.assertContains(json.asString($out.body, "/error"), "another account");
}

func testAPolicyRefusalIsAPermissionsAnswer() {
    def out as ScopeReply init claim(
        emptyDb(),
        operatorPolicy.policy(),
        alice(),
        "alice",
        none(),
        NOW);
    testing.assertEqual($out.status, 403);
}

func testAReservedNameIsRefused() {
    def out as ScopeReply init claim(emptyDb(), derived.policy(), alice(), "alice", ["alice"], NOW);
    testing.assertFalse($out.status == 201);
}

func testAMissingScopeIsA400() {
    testing.assertEqual(claim(emptyDb(), derived.policy(), alice(), "", none(), NOW).status, 400);
}

func testAClaimIsRecorded() {
    def out as ScopeReply init claim(emptyDb(), derived.policy(), alice(), "alice", none(), NOW);
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
    # account ids are what ownership binds to; a public list helps an impersonator
    def out as ScopeReply init listScopes(owned());
    testing.assertFalse(strings.contains(json.encode($out.body), "1234567"));
}

func testACoOwnerCannotChangeTheCoOwners() {
    # otherwise a compromised co-owner could plant accounts or lock the rest out
    def db as flatdb.DB init owners(owned(), alice(), "alice", "999", true, NOW).db;
    def bob as identity.Subject init stranger();
    $bob.id = "999";
    def out as ScopeReply init owners($db, $bob, "alice", "555", true, NOW);
    testing.assertEqual($out.status, 403);
    testing.assertFalse($out.changed);
    testing.assertContains(json.asString($out.body, "/error"), "only the owner");
    testing.assertEqual(owners($db, $bob, "alice", "999", false, NOW).status, 403);
}

func testACoOwnerMustBeAUsableSubject() {
    # subjects are opaque (8.1); only an empty or whitespace-bearing one is refused
    for (def bad in ["", "a b", "x\ty"]) {
        testing.assertEqual(owners(owned(), alice(), "alice", $bad, true, NOW).status, 400);
    }
}

# --- trusted publishers (8.9) -------------------------------------------------

func bindingFields() {
    def f as map of string to string init {"provider": "github-actions", "repositoryId": "42"};
    return $f;
}

func testTheOwnerRegistersAScopeWidePublisher() {
    def out as ScopeReply init publishers(owned(), alice(), "@alice", bindingFields(), true, NOW);
    testing.assertEqual($out.status, 200);
    testing.assertTrue($out.changed);
    testing.assertEqual(store.bindingFor($out.db, "@alice/tool").repositoryId, "42");
    def removed as ScopeReply init publishers(
        $out.db,
        alice(),
        "@alice",
        bindingFields(),
        false,
        NOW);
    testing.assertEqual($removed.status, 200);
    testing.assertFalse(store.hasBinding($removed.db, "@alice"));
    def again as ScopeReply init publishers(
        $removed.db,
        alice(),
        "@alice",
        bindingFields(),
        false,
        NOW);
    testing.assertEqual($again.status, 404);
}

func testOnlyTheOwnerChangesPublishers() {
    # a binding is a standing grant, like a co-owner entry
    testing.assertEqual(
        publishers(owned(), stranger(), "@alice", bindingFields(), true, NOW).status,
        403);
    def db as flatdb.DB init owners(owned(), alice(), "alice", "9999999", true, NOW).db;
    def out as ScopeReply init publishers(
        $db,
        stranger(),
        "@alice/tool",
        bindingFields(),
        true,
        NOW);
    testing.assertEqual($out.status, 403);
    testing.assertContains(json.asString($out.body, "/error"), "only the owner");
}

func testABadPublisherRequestIs400Or404() {
    def noId as map of string to string init {"provider": "github-actions"};
    testing.assertEqual(publishers(owned(), alice(), "@alice", $noId, true, NOW).status, 400);
    testing.assertEqual(publishers(owned(), alice(), "", bindingFields(), true, NOW).status, 400);
    testing.assertEqual(
        publishers(owned(), alice(), "@nobody", bindingFields(), true, NOW).status,
        404);
}
