# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for publishview.j. Run with:
#
#     jennifer test src/publishview_test.j
#
# The tests assert the order of the checks as well as their outcomes: a late
# refusal can reveal something about a deck the caller has no rights to.

use testing;
use json;

def const NOW as string init "1700000000";
def const COMMIT as string init "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293";
def const AUD as string init "jennifer-registry";
def const ISS as string init "https://token.actions.githubusercontent.com";
def const REPO_ID as string init "123456789";

func emptyDb() {
    return store.open("/no/such/jvc/publish/missing.json");
}

# owned returns a store where @acme belongs to GitHub subject 1234567.
func owned() {
    return scope.grant(emptyDb(), "acme", "github", "1234567", "alice", NOW).db;
}

func alice() {
    return identity.Subject{
        provider: "github",
        id: "1234567",
        login: "alice",
        orgs: {},
        orgsCheckedAt: ""
    };
}

func stranger() {
    return identity.Subject{
        provider: "github",
        id: "9999999",
        login: "mallory",
        orgs: {},
        orgsCheckedAt: ""
    };
}

func manifestText() {
    return '[package]
name = "@acme/routeros"
version = "0.1.0"
description = "MikroTik RouterOS client"

[decks]
"@acme/net" = "^1.0.0"
';
}

func source() {
    return Source{
        repository: "https://github.com/acme/deck-routeros.git",
        tag: "v0.1.0",
        commit: COMMIT,
        repoId: REPO_ID,
        repoOwnerId: "42",
        repoOwner: "acme",
        manifestText: manifestText(),
        readmeText: "# routeros\n\nA **client**.\n",
        commitShadowed: false,
        entryPresent: true,
        authority: forge.granted("the caller has push access")
    };
}

# --- provenance (6.4, 7.3) ----------------------------------------------------

func testAPublishRecordsTheRepositoryAndItsOwner() {
    def out as PublishReply init byToken(owned(), alice(), source(), NOW);
    def p as store.Provenance init store.provenanceOf($out.db, "@acme/routeros", "0.1.0");
    testing.assertEqual($p.repoId, REPO_ID);
    testing.assertEqual($p.repoOwnerId, "42");
    testing.assertEqual($p.repoOwner, "acme");
    testing.assertEqual($out.event.level, audit.INFO);
}

func testAnOwnerChangeOnTheSameRepositoryIsAWarning() {
    def first as PublishReply init byToken(owned(), alice(), source(), NOW);
    def moved as Source init source();
    $moved.tag = "v0.2.0";
    $moved.manifestText = strings.replace(manifestText(), '"0.1.0"', '"0.2.0"');
    $moved.repoOwnerId = "666";
    $moved.repoOwner = "mallory";
    def out as PublishReply init byToken($first.db, alice(), $moved, NOW);
    testing.assertEqual($out.status, 201);
    testing.assertEqual($out.event.level, audit.WARN);
    testing.assertEqual($out.event.fields["ownerChangedSince"], "0.1.0");
    testing.assertEqual(store.ownerChangeOf($out.db, "@acme/routeros", REPO_ID, "42"), "0.2.0");
}

# --- publishing with a bearer token -------------------------------------------

func testTheOwnerPublishes() {
    def out as PublishReply init byToken(owned(), alice(), source(), NOW);
    testing.assertEqual($out.status, 201);
    testing.assertTrue($out.changed);
    testing.assertEqual(json.asString($out.body, "/name"), "@acme/routeros");
    testing.assertEqual(json.asString($out.body, "/version"), "0.1.0");
    testing.assertTrue(store.hasVersion($out.db, "@acme/routeros", "0.1.0"));
}

func testTheRecordIsPinnedToTheCommit() {
    # the tag is display; the commit is the integrity boundary
    def out as PublishReply init byToken(owned(), alice(), source(), NOW);
    def v as store.DeckVersion init store.getVersionRecord($out.db, "@acme/routeros", "0.1.0");
    testing.assertEqual($v.kind, store.KIND_GIT);
    testing.assertEqual($v.commit, COMMIT);
    testing.assertEqual($v.ref, "v0.1.0");
    testing.assertEqual($v.checksum, "");
    testing.assertFalse($v.yanked);
}

func testTheRecordComesFromTheManifestNotTheRequest() {
    # the deck is read at the commit, so a publisher cannot name somebody's scope
    def out as PublishReply init byToken(owned(), alice(), source(), NOW);
    def v as store.DeckVersion init store.getVersionRecord($out.db, "@acme/routeros", "0.1.0");
    testing.assertEqual($v.description, "MikroTik RouterOS client");
    testing.assertEqual($v.requires["@acme/net"], "^1.0.0");
}

func testAStrangerIsRefused() {
    def out as PublishReply init byToken(owned(), stranger(), source(), NOW);
    testing.assertEqual($out.status, 403);
    testing.assertFalse($out.changed);
    testing.assertContains(json.asString($out.body, "/error"), "belongs to");
}

func testAnUnregisteredScopeIsRefusedBeforeAuthorisation() {
    # told the scope does not exist here, not that they lack rights to it
    def out as PublishReply init byToken(emptyDb(), alice(), source(), NOW);
    testing.assertEqual($out.status, 403);
    testing.assertContains(json.asString($out.body, "/error"), "not registered");
}

func testRepublishingAVersionIsRefused() {
    # a published version is immutable (specification 9)
    def db as flatdb.DB init byToken(owned(), alice(), source(), NOW).db;
    def out as PublishReply init byToken($db, alice(), source(), NOW);
    testing.assertEqual($out.status, 409);
    testing.assertFalse($out.changed);
    testing.assertContains(json.asString($out.body, "/error"), "already published");
}

func testTheConflictCheckComesAfterAuthorisation() {
    # a stranger must not learn which versions exist by watching 409 vs 403
    def db as flatdb.DB init byToken(owned(), alice(), source(), NOW).db;
    def out as PublishReply init byToken($db, stranger(), source(), NOW);
    testing.assertEqual($out.status, 403);
}

func testAMalformedManifestIsA400() {
    def src as Source init source();
    $src.manifestText = "name = \nbroken";
    def out as PublishReply init byToken(owned(), alice(), $src, NOW);
    testing.assertEqual($out.status, 400);
}

func testATagThatDisagreesWithTheManifestIsRefused() {
    # `ref` and `version` must not disagree (7, step 6)
    def src as Source init source();
    $src.tag = "v0.2.0";
    def out as PublishReply init byToken(owned(), alice(), $src, NOW);
    testing.assertEqual($out.status, 400);
    testing.assertContains(json.asString($out.body, "/error"), "disagrees");
    testing.assertFalse($out.changed);
}

func testOneLeadingVIsToleratedAndNoMore() {
    def bare as Source init source();
    $bare.tag = "0.1.0";
    testing.assertEqual(byToken(owned(), alice(), $bare, NOW).status, 201);
    def twice as Source init source();
    $twice.tag = "vv0.1.0";
    testing.assertEqual(byToken(owned(), alice(), $twice, NOW).status, 400);
    def upper as Source init source();
    $upper.tag = "V0.1.0";
    testing.assertEqual(byToken(owned(), alice(), $upper, NOW).status, 400);
}

func testATreeWithoutTheEntryModuleIsRefused() {
    # without `src/<deck>.j` a client installs nothing (6.1, 7 step 8)
    def src as Source init source();
    $src.entryPresent = false;
    def out as PublishReply init byToken(owned(), alice(), $src, NOW);
    testing.assertEqual($out.status, 400);
    testing.assertContains(json.asString($out.body, "/error"), "src/routeros.j");
}

func testTheReleaseChecksBindEveryWayOfPublishing() {
    def src as Source init source();
    $src.tag = "v9.9.9";
    testing.assertEqual(byTrustedPublisher(bound(), claims(), AUD, ISS, $src, NOW).status, 400);
}

func testTheEntryPathComesFromTheManifestName() {
    testing.assertEqual(entryPathFor(manifestText()), "src/routeros.j");
    testing.assertEqual(entryPathFor("not toml ["), "");
}

func testAnUnresolvedTagIsRefused() {
    # an abbreviated or empty SHA must not become the pin
    def src as Source init source();
    $src.commit = "9f2c1d4";
    def out as PublishReply init byToken(owned(), alice(), $src, NOW);
    testing.assertEqual($out.status, 400);
    testing.assertContains(json.asString($out.body, "/error"), "commit SHA");
}

func testAMissingRepositoryOrTagIsA400() {
    def noRepo as Source init source();
    $noRepo.repository = "";
    testing.assertEqual(byToken(owned(), alice(), $noRepo, NOW).status, 400);
    def noTag as Source init source();
    $noTag.tag = "";
    testing.assertEqual(byToken(owned(), alice(), $noTag, NOW).status, 400);
}

func testAPublishIsRecorded() {
    def out as PublishReply init byToken(owned(), alice(), source(), NOW);
    testing.assertEqual($out.event.fields["pin"], COMMIT);
    testing.assertEqual($out.event.fields["via"], "token");
}

func testARefusalIsRecorded() {
    def out as PublishReply init byToken(owned(), stranger(), source(), NOW);
    testing.assertContains($out.event.message, "refused");
    testing.assertEqual($out.event.fields["status"], "403");
}

# --- publishing from CI -------------------------------------------------------

func bound() {
    return store.putBinding(
        owned(),
        trustpub.Binding{
            provider: trustpub.GITHUB,
            repositoryId: REPO_ID,
            repository: "acme/deck-routeros",
            workflow: "acme/deck-routeros/.github/workflows/publish.yml",
            refPattern: "refs/tags/*",
            deck: "@acme/routeros",
            pending: true,
            createdAt: NOW
        });
}

func claims() {
    return trustpub.Claims{
        provider: trustpub.GITHUB,
        issuer: ISS,
        audience: AUD,
        repositoryId: REPO_ID,
        repository: "acme/deck-routeros",
        workflow: "acme/deck-routeros/.github/workflows/publish.yml",
        ref: "refs/tags/v0.1.0",
        sha: COMMIT,
        issuedAt: 0
    };
}

func testACiJobPublishesWithNoCredential() {
    def out as PublishReply init byTrustedPublisher(bound(), claims(), AUD, ISS, source(), NOW);
    testing.assertEqual($out.status, 201);
    testing.assertTrue(store.hasVersion($out.db, "@acme/routeros", "0.1.0"));
    testing.assertEqual($out.event.fields["via"], "trusted-publisher");
}

func testTheFirstPublishSettlesAPendingBinding() {
    testing.assertTrue(store.getBinding(bound(), "@acme/routeros").pending);
    def out as PublishReply init byTrustedPublisher(bound(), claims(), AUD, ISS, source(), NOW);
    testing.assertFalse(store.getBinding($out.db, "@acme/routeros").pending);
}

func testAPendingBindingExpiresUnused() {
    # 8.9: an abandoned pending binding must not hold the name for ever
    def later as string init convert.toString(
        convert.toInt(NOW) + trustpub.PENDING_TTL_SECONDS + 1);
    def out as PublishReply init byTrustedPublisher(bound(), claims(), AUD, ISS, source(), $later);
    testing.assertEqual($out.status, 403);
    testing.assertContains(json.asString($out.body, "/error"), "expired unused");
}

func testADeckWithNoBindingIsRefused() {
    # never auto-bind: whichever repository published first would capture a name
    def out as PublishReply init byTrustedPublisher(owned(), claims(), AUD, ISS, source(), NOW);
    testing.assertEqual($out.status, 403);
    testing.assertContains(json.asString($out.body, "/error"), "no trusted publisher");
}

func testTheBindingIsFoundByTheManifestName() {
    # the binding is looked up by the name read at the commit
    def src as Source init source();
    $src.manifestText = '[package]
name = "@acme/other"
version = "0.1.0"
';
    def out as PublishReply init byTrustedPublisher(bound(), claims(), AUD, ISS, $src, NOW);
    testing.assertEqual($out.status, 403);
    testing.assertContains(json.asString($out.body, "/error"), "no trusted publisher");
}

func testATokenForAnotherAudienceIsRefused() {
    def c as trustpub.Claims init claims();
    $c.audience = "some-other-service";
    def out as PublishReply init byTrustedPublisher(bound(), $c, AUD, ISS, source(), NOW);
    testing.assertEqual($out.status, 403);
    testing.assertContains(json.asString($out.body, "/error"), "audience");
}

func testABranchBuildIsRefused() {
    def c as trustpub.Claims init claims();
    $c.ref = "refs/heads/main";
    testing.assertEqual(byTrustedPublisher(bound(), $c, AUD, ISS, source(), NOW).status, 403);
}

func testTheTokenAndTheSourceMustBeTheSameRepository() {
    # the token's repository and the forge's must agree
    def src as Source init source();
    $src.repoId = "777777";
    def out as PublishReply init byTrustedPublisher(bound(), claims(), AUD, ISS, $src, NOW);
    testing.assertEqual($out.status, 403);
    testing.assertContains(json.asString($out.body, "/error"), "but the source is");
}

func testAForgeThatNamesNoRepositoryIsRefused() {
    # an empty forge id is not agreement
    def src as Source init source();
    $src.repoId = "";
    def out as PublishReply init byTrustedPublisher(bound(), claims(), AUD, ISS, $src, NOW);
    testing.assertEqual($out.status, 403);
    testing.assertFalse($out.changed);
}

func testRepublishingFromCiIsRefused() {
    def db as flatdb.DB init byTrustedPublisher(bound(), claims(), AUD, ISS, source(), NOW).db;
    def out as PublishReply init byTrustedPublisher($db, claims(), AUD, ISS, source(), NOW);
    testing.assertEqual($out.status, 409);
}

func testAnUnregisteredScopeIsRefusedForCiToo() {
    def db as flatdb.DB init store.putBinding(
        emptyDb(),
        trustpub.Binding{
            provider: trustpub.GITHUB,
            repositoryId: REPO_ID,
            repository: "x",
            workflow: "",
            refPattern: "",
            deck: "@acme/routeros",
            pending: true,
            createdAt: NOW
        });
    def out as PublishReply init byTrustedPublisher($db, claims(), AUD, ISS, source(), NOW);
    testing.assertEqual($out.status, 403);
    testing.assertContains(json.asString($out.body, "/error"), "not registered");
}

# --- names that can be read as object ids -------------------------------------
#
# A forge's `?ref=` resolves a name before an object, so a ref shaped like an id
# can shadow that commit. Both the stored tag and the commit read through are
# checked.

func testATagShapedLikeACommitIsRefused() {
    def src as Source init source();
    $src.tag = COMMIT;
    def out as PublishReply init byToken(owned(), alice(), $src, NOW);
    testing.assertEqual($out.status, 400);
    testing.assertFalse($out.changed);
    testing.assertContains(json.asString($out.body, "/error"), "object id");
}

func testAnAbbreviatedHexTagIsRefusedToo() {
    # seven hex digits is where git starts resolving abbreviations
    def src as Source init source();
    $src.tag = "9f2c1d4";
    testing.assertEqual(byToken(owned(), alice(), $src, NOW).status, 400);
}

func testAnUppercaseHexTagIsRefused() {
    # git's hex parsing takes either case
    def src as Source init source();
    $src.tag = "9F2C1D4E5A6B";
    testing.assertEqual(byToken(owned(), alice(), $src, NOW).status, 400);
}

func testAnOrdinaryTagIsUntouched() {
    # the guard must refuse a shape, not tags in general
    testing.assertEqual(byToken(owned(), alice(), source(), NOW).status, 201);
}

func testAShadowedCommitIsRefused() {
    # read through `?ref=<commit>`, a ref of that name answered instead
    def src as Source init source();
    $src.commitShadowed = true;
    def out as PublishReply init byToken(owned(), alice(), $src, NOW);
    testing.assertEqual($out.status, 400);
    testing.assertFalse($out.changed);
    testing.assertContains(json.asString($out.body, "/error"), "shadows the commit");
    testing.assertFalse(store.hasVersion($out.db, "@acme/routeros", "0.1.0"));
}

func testAShadowedCommitIsRefusedFromCiToo() {
    # the shadow check applies to trusted publishing too
    def src as Source init source();
    $src.commitShadowed = true;
    def out as PublishReply init byTrustedPublisher(bound(), claims(), AUD, ISS, $src, NOW);
    testing.assertEqual($out.status, 400);
    testing.assertFalse(store.hasVersion($out.db, "@acme/routeros", "0.1.0"));
}

func testTheNameShapeIsCheckedBeforeTheForgeOutput() {
    # the request's 400 is reported before the forge's
    def src as Source init source();
    $src.tag = COMMIT;
    $src.commit = "not-a-sha";
    testing.assertContains(
        json.asString(byToken(owned(), alice(), $src, NOW).body, "/error"),
        "object id");
}

# --- a reserved scope has no delegate ------------------------------------------
#
# A scope with no subject is reserved. Each of the three credentials answers to
# a different record, so each is checked separately.

# reserved returns a store where @acme is registered but bound to nobody.
func reserved() {
    return scope.grant(emptyDb(), "acme", "", "", "", NOW).db;
}

func testAReservedScopeRefusesABearerToken() {
    def out as PublishReply init byToken(reserved(), alice(), source(), NOW);
    testing.assertEqual($out.status, 403);
    testing.assertFalse($out.changed);
    testing.assertContains(json.asString($out.body, "/error"), "no owner");
}

func testAReservedScopeRefusesATrustedPublisher() {
    # this path never consults the namespace, so the publish must check the owner
    def db as flatdb.DB init store.putBinding(
        reserved(),
        trustpub.Binding{
            provider: trustpub.GITHUB,
            repositoryId: REPO_ID,
            repository: "acme/deck-routeros",
            workflow: "acme/deck-routeros/.github/workflows/publish.yml",
            refPattern: "refs/tags/*",
            deck: "@acme/routeros",
            pending: true,
            createdAt: NOW
        });
    def out as PublishReply init byTrustedPublisher($db, claims(), AUD, ISS, source(), NOW);
    testing.assertEqual($out.status, 403);
    testing.assertFalse($out.changed);
    testing.assertContains(json.asString($out.body, "/error"), "no owner");
    testing.assertFalse(store.hasVersion($out.db, "@acme/routeros", "0.1.0"));
}

func testAReservedScopeRefusesACiToken() {
    def t as citoken.Token init citoken.Token{
        fingerprint: "abc123",
        name: "ci",
        scope: "acme",
        deck: "",
        provider: "github",
        subject: "1234567",
        createdAt: NOW,
        expiresAt: "",
        lastUsedAt: ""
    };
    def out as PublishReply init byCiToken(store.putCiToken(reserved(), $t), $t, source(), NOW);
    testing.assertEqual($out.status, 403);
    testing.assertFalse($out.changed);
    testing.assertContains(json.asString($out.body, "/error"), "no owner");
}

func testAnOwnedScopeStillPublishes() {
    # an owned scope still publishes through the same guard
    testing.assertEqual(byToken(owned(), alice(), source(), NOW).status, 201);
    testing.assertEqual(byTrustedPublisher(bound(), claims(), AUD, ISS, source(), NOW).status, 201);
}

# --- yanking over HTTP --------------------------------------------------------

func published() {
    return byToken(owned(), alice(), source(), NOW).db;
}

func testTheOwnerYanks() {
    def out as PublishReply init setYanked(published(), alice(), "@acme/routeros", "0.1.0", true);
    testing.assertEqual($out.status, 200);
    testing.assertTrue($out.changed);
    testing.assertTrue(store.isYanked($out.db, "@acme/routeros", "0.1.0"));
    testing.assertTrue(json.asBool($out.body, "/yanked"));
}

func testYankingIsReversible() {
    def db as flatdb.DB init setYanked(published(), alice(), "@acme/routeros", "0.1.0", true).db;
    def out as PublishReply init setYanked($db, alice(), "@acme/routeros", "0.1.0", false);
    testing.assertEqual($out.status, 200);
    testing.assertFalse(store.isYanked($out.db, "@acme/routeros", "0.1.0"));
}

func testAYankIsIdempotent() {
    # a retry after a lost response must not read as a failure
    def db as flatdb.DB init setYanked(published(), alice(), "@acme/routeros", "0.1.0", true).db;
    def again as PublishReply init setYanked($db, alice(), "@acme/routeros", "0.1.0", true);
    testing.assertEqual($again.status, 200);
    testing.assertFalse($again.changed);
    testing.assertEqual($again.event.level, "");
}

func testAStrangerCannotYank() {
    def out as PublishReply init setYanked(
        published(),
        stranger(),
        "@acme/routeros",
        "0.1.0",
        true);
    testing.assertEqual($out.status, 403);
    testing.assertFalse(store.isYanked($out.db, "@acme/routeros", "0.1.0"));
}

func testAuthorisationComesBeforeExistence() {
    # a stranger must not learn which versions exist by watching 404 vs 403
    def out as PublishReply init setYanked(
        published(),
        stranger(),
        "@acme/routeros",
        "9.9.9",
        true);
    testing.assertEqual($out.status, 403);
}

func testYankingAnUnknownVersionIs404ForTheOwner() {
    def out as PublishReply init setYanked(published(), alice(), "@acme/routeros", "9.9.9", true);
    testing.assertEqual($out.status, 404);
}

func testYankNeedsBothFields() {
    testing.assertEqual(setYanked(published(), alice(), "", "0.1.0", true).status, 400);
    testing.assertEqual(setYanked(published(), alice(), "@acme/routeros", "", true).status, 400);
}

func testYankRejectsABareName() {
    testing.assertEqual(setYanked(published(), alice(), "routeros", "0.1.0", true).status, 400);
}

func testAYankIsRecorded() {
    def out as PublishReply init setYanked(published(), alice(), "@acme/routeros", "0.1.0", true);
    testing.assertContains($out.event.message, "yanked");
    testing.assertEqual($out.event.fields["version"], "0.1.0");
}

# --- source authority (7.1 route A) -------------------------------------------

func withAuthority(p as forge.Permission) {
    def src as Source init source();
    $src.authority = $p;
    return $src;
}

func ciToken() {
    return citoken.Token{
        fingerprint: "abc123",
        name: "ci",
        scope: "acme",
        deck: "",
        provider: "",
        subject: "",
        createdAt: NOW,
        expiresAt: "",
        lastUsedAt: ""
    };
}

# withCiToken is owned() with ciToken() on record, as minted.
func withCiToken() {
    return store.putCiToken(owned(), ciToken());
}

func testARevokedCiTokenDoesNotPublish() {
    # revoked during the forge calls, it must not publish
    def out as PublishReply init byCiToken(owned(), ciToken(), source(), NOW);
    testing.assertEqual($out.status, 401);
    testing.assertFalse($out.changed);
    testing.assertContains(json.asString($out.body, "/error"), "revoked");
}

func testAnOwnerWithoutPushAccessIsRefused() {
    # owning @acme does not make somebody else's repository yours to publish
    def out as PublishReply init byToken(
        owned(),
        alice(),
        withAuthority(forge.refused("no push access")),
        NOW);
    testing.assertEqual($out.status, 403);
    testing.assertFalse($out.changed);
    testing.assertContains(json.asString($out.body, "/error"), "may not publish from");
}

func testAnUnansweredCheckIsNotPermission() {
    # unknown is refused, never treated as granted (7.1)
    def out as PublishReply init byToken(
        owned(),
        alice(),
        withAuthority(forge.unknown("no forge credential on record")),
        NOW);
    testing.assertEqual($out.status, 403);
    testing.assertContains(json.asString($out.body, "/error"), "could not establish");
}

func testTheSourceCheckComesAfterTheScopeCheck() {
    # a stranger is refused on the scope, so learns nothing about the repository
    def out as PublishReply init byToken(
        owned(),
        stranger(),
        withAuthority(forge.refused("no push access")),
        NOW);
    testing.assertEqual($out.status, 403);
    testing.assertFalse(strings.contains(
        json.asString($out.body, "/error"),
        "may not publish from"));
}

func testTheSourceCheckComesBeforeTheConflictCheck() {
    def first as PublishReply init byToken(owned(), alice(), source(), NOW);
    def again as PublishReply init byToken(
        $first.db,
        alice(),
        withAuthority(forge.refused("no push access")),
        NOW);
    testing.assertEqual($again.status, 403);
}

func testACiTokenNeedsPushAccessToo() {
    # a CI token is name authority only (8.10)
    def out as PublishReply init byCiToken(
        withCiToken(),
        ciToken(),
        withAuthority(forge.unknown("nobody to check")),
        NOW);
    testing.assertEqual($out.status, 403);
    def ok as PublishReply init byCiToken(withCiToken(), ciToken(), source(), NOW);
    testing.assertEqual($ok.status, 201);
}

func testTrustedPublishingNeedsNoForgeAnswer() {
    # its token already proves the repository (route C)
    def out as PublishReply init byTrustedPublisher(
        bound(),
        claims(),
        AUD,
        ISS,
        withAuthority(forge.unknown("not asked")),
        NOW);
    testing.assertEqual($out.status, 201);
}

func testAnOperatorMintedTokenActsForTheScopeOwner() {
    def p as identity.Subject init ciPrincipal(owned(), ciToken(), "@acme/routeros");
    testing.assertEqual($p.id, "1234567");
    testing.assertEqual($p.login, "alice");
    testing.assertEqual($p.provider, "github");
}

func testATokenWithAMinterActsForTheMinter() {
    def t as citoken.Token init ciToken();
    $t.provider = "github";
    $t.subject = "555";
    testing.assertEqual(ciPrincipal(owned(), $t, "@acme/routeros").id, "555");
}

func testAnOrganisationScopeHasNoPersonToCheck() {
    def db as flatdb.DB init scope.grantAs(
        emptyDb(),
        "acme",
        "github",
        "77",
        "acme-org",
        store.SCOPE_ORG,
        NOW).db;
    testing.assertEqual(ciPrincipal($db, ciToken(), "@acme/routeros").id, "");
}

func testASecondBuildOfAPublishedVersionIsRefused() {
    # 1.0.0+b has the precedence of 1.0.0+a (SemVer 10), so it is a republish
    def first as Source init source();
    $first.manifestText = strings.replace(manifestText(), '"0.1.0"', '"0.1.0+a"');
    $first.tag = "v0.1.0+a";
    def db as flatdb.DB init byToken(owned(), alice(), $first, NOW).db;
    testing.assertTrue(store.hasVersion($db, "@acme/routeros", "0.1.0+a"));
    def second as Source init source();
    $second.manifestText = strings.replace(manifestText(), '"0.1.0"', '"0.1.0+b"');
    $second.tag = "v0.1.0+b";
    def out as PublishReply init byToken($db, alice(), $second, NOW);
    testing.assertEqual($out.status, 409);
    testing.assertFalse(store.hasVersion($out.db, "@acme/routeros", "0.1.0+b"));
}

func testATokenForAnotherCommitDoesNotPublish() {
    # a bound workflow running somewhere else must not publish this tag
    def c as trustpub.Claims init claims();
    $c.sha = "0000000000000000000000000000000000000000";
    def out as PublishReply init byTrustedPublisher(bound(), $c, AUD, ISS, source(), NOW);
    testing.assertEqual($out.status, 403);
    testing.assertContains(json.asString($out.body, "/error"), "points at");
}

func testATokenForAnotherTagDoesNotPublish() {
    def c as trustpub.Claims init claims();
    $c.ref = "refs/tags/v0.0.9";
    def out as PublishReply init byTrustedPublisher(bound(), $c, AUD, ISS, source(), NOW);
    testing.assertEqual($out.status, 403);
    testing.assertContains(json.asString($out.body, "/error"), "not for the tag");
}
