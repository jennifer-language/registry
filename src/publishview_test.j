# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for publishview.j. Run with:
#
#     jennifer test src/publishview_test.j
#
# This is the write path. The tests assert the *order* of its checks as much as
# their outcomes: a publish that is refused for the wrong reason tells a
# publisher to fix the wrong thing, and one that is refused too late has already
# revealed something about a deck the caller has no rights to.

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
    return identity.Subject{ provider: "github", id: "1234567", login: "alice",
        orgs: {}, orgsCheckedAt: "" };
}

func stranger() {
    return identity.Subject{ provider: "github", id: "9999999", login: "mallory",
        orgs: {}, orgsCheckedAt: "" };
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
        commitShadowed: false
    };
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
    # the request names a repository and a tag; everything about the deck is read
    # at the commit, which is what stops a publisher naming somebody's scope
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
    # immutability is absolute: a lockfile that resolved this once must resolve
    # to the same code forever
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

func testAnUnresolvedTagIsRefused() {
    # an abbreviated or empty SHA would be stored as the pin and handed to every
    # client that installs the version
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
    return store.putBinding(owned(), trustpub.Binding{
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
        ref: "refs/tags/v0.1.0"
    };
}

func testACiJobPublishesWithNoCredential() {
    def out as PublishReply init byTrustedPublisher(bound(), claims(), AUD, ISS,
        source(), NOW);
    testing.assertEqual($out.status, 201);
    testing.assertTrue(store.hasVersion($out.db, "@acme/routeros", "0.1.0"));
    testing.assertEqual($out.event.fields["via"], "trusted-publisher");
}

func testTheFirstPublishSettlesAPendingBinding() {
    testing.assertTrue(store.getBinding(bound(), "@acme/routeros").pending);
    def out as PublishReply init byTrustedPublisher(bound(), claims(), AUD, ISS,
        source(), NOW);
    testing.assertFalse(store.getBinding($out.db, "@acme/routeros").pending);
}

func testADeckWithNoBindingIsRefused() {
    # never auto-bind: whichever repository published first would capture a name
    def out as PublishReply init byTrustedPublisher(owned(), claims(), AUD, ISS,
        source(), NOW);
    testing.assertEqual($out.status, 403);
    testing.assertContains(json.asString($out.body, "/error"), "no trusted publisher");
}

func testTheBindingIsFoundByTheManifestName() {
    # a repository bound to one deck must not publish to another by naming it;
    # the lookup uses the name read at the commit, not anything in the request
    def src as Source init source();
    $src.manifestText = '[package]
name = "@acme/other"
version = "0.1.0"
';
    def out as PublishReply init byTrustedPublisher(bound(), claims(), AUD, ISS,
        $src, NOW);
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
    # a build in a repository the caller controls must not publish code from one
    # they do not: the token says where the build ran, the forge says what this
    # URL is, and they have to agree
    def src as Source init source();
    $src.repoId = "777777";
    def out as PublishReply init byTrustedPublisher(bound(), claims(), AUD, ISS,
        $src, NOW);
    testing.assertEqual($out.status, 403);
    testing.assertContains(json.asString($out.body, "/error"), "but the source is");
}

func testRepublishingFromCiIsRefused() {
    def db as flatdb.DB init byTrustedPublisher(bound(), claims(), AUD, ISS,
        source(), NOW).db;
    def out as PublishReply init byTrustedPublisher($db, claims(), AUD, ISS,
        source(), NOW);
    testing.assertEqual($out.status, 409);
}

func testAnUnregisteredScopeIsRefusedForCiToo() {
    def db as flatdb.DB init store.putBinding(emptyDb(), trustpub.Binding{
        provider: trustpub.GITHUB, repositoryId: REPO_ID, repository: "x",
        workflow: "", refPattern: "", deck: "@acme/routeros",
        pending: true, createdAt: NOW
    });
    def out as PublishReply init byTrustedPublisher($db, claims(), AUD, ISS,
        source(), NOW);
    testing.assertEqual($out.status, 403);
    testing.assertContains(json.asString($out.body, "/error"), "not registered");
}

# --- names that can be read as object ids -------------------------------------
#
# A git name and a git object id share one syntactic space, and a forge's
# `?ref=` parameter resolves a name before an object. So a ref shaped like an id
# can stand in front of the commit of that id while the record still reads as
# pinned. Both halves are refused: the tag we would store, and the commit we
# just read through.

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
    # git's hex parsing takes either case, so folding is not optional
    def src as Source init source();
    $src.tag = "9F2C1D4E5A6B";
    testing.assertEqual(byToken(owned(), alice(), $src, NOW).status, 400);
}

func testAnOrdinaryTagIsUntouched() {
    # the guard must refuse a shape, not tags in general
    testing.assertEqual(byToken(owned(), alice(), source(), NOW).status, 201);
}

func testAShadowedCommitIsRefused() {
    # the manifest in hand was read through `?ref=<commit>`, so a ref of that
    # name answered instead of the object and these bytes are the wrong ones
    def src as Source init source();
    $src.commitShadowed = true;
    def out as PublishReply init byToken(owned(), alice(), $src, NOW);
    testing.assertEqual($out.status, 400);
    testing.assertFalse($out.changed);
    testing.assertContains(json.asString($out.body, "/error"), "shadows the commit");
    testing.assertFalse(store.hasVersion($out.db, "@acme/routeros", "0.1.0"));
}

func testAShadowedCommitIsRefusedFromCiToo() {
    # the shadow is a property of the repository, not of the credential, so it
    # must not be reachable by publishing from a workflow instead
    def src as Source init source();
    $src.commitShadowed = true;
    def out as PublishReply init byTrustedPublisher(bound(), claims(), AUD, ISS,
        $src, NOW);
    testing.assertEqual($out.status, 400);
    testing.assertFalse(store.hasVersion($out.db, "@acme/routeros", "0.1.0"));
}

func testTheNameShapeIsCheckedBeforeTheForgeOutput() {
    # a 400 about the request beats a 400 about what the forge returned: the
    # publisher can only act on the first one
    def src as Source init source();
    $src.tag = COMMIT;
    $src.commit = "not-a-sha";
    testing.assertContains(json.asString(byToken(owned(), alice(), $src, NOW).body,
        "/error"), "object id");
}

# --- a reserved scope has no delegate ------------------------------------------
#
# A scope registered with no subject is held by an operator so that nobody can
# claim it and nobody can write under it. Each of the three credentials answers
# to a different authority - a scope binding, a trusted-publisher binding, a
# token record - so each is checked here separately, and each must refuse.

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
    # this path never consults the namespace: the binding is its whole authority.
    # So a binding that should not exist would be honoured unless the publish
    # itself asks whether the scope has an owner.
    def db as flatdb.DB init store.putBinding(reserved(), trustpub.Binding{
        provider: trustpub.GITHUB,
        repositoryId: REPO_ID,
        repository: "acme/deck-routeros",
        workflow: "acme/deck-routeros/.github/workflows/publish.yml",
        refPattern: "refs/tags/*",
        deck: "@acme/routeros",
        pending: true,
        createdAt: NOW
    });
    def out as PublishReply init byTrustedPublisher($db, claims(), AUD, ISS,
        source(), NOW);
    testing.assertEqual($out.status, 403);
    testing.assertFalse($out.changed);
    testing.assertContains(json.asString($out.body, "/error"), "no owner");
    testing.assertFalse(store.hasVersion($out.db, "@acme/routeros", "0.1.0"));
}

func testAReservedScopeRefusesACiToken() {
    def t as citoken.Token init citoken.Token{
        fingerprint: "abc123", name: "ci", scope: "acme", deck: "",
        provider: "github", subject: "1234567", createdAt: NOW,
        expiresAt: "", lastUsedAt: ""
    };
    def out as PublishReply init byCiToken(reserved(), $t, source(), NOW);
    testing.assertEqual($out.status, 403);
    testing.assertFalse($out.changed);
    testing.assertContains(json.asString($out.body, "/error"), "no owner");
}

func testAnOwnedScopeStillPublishes() {
    # the guard above must refuse *unowned*, not *reserved-looking*: the ordinary
    # path is what proves it did not simply close the door on everybody
    testing.assertEqual(byToken(owned(), alice(), source(), NOW).status, 201);
    testing.assertEqual(byTrustedPublisher(bound(), claims(), AUD, ISS,
        source(), NOW).status, 201);
}

# --- yanking over HTTP --------------------------------------------------------

func published() {
    return byToken(owned(), alice(), source(), NOW).db;
}

func testTheOwnerYanks() {
    def out as PublishReply init setYanked(published(), alice(),
        "@acme/routeros", "0.1.0", true);
    testing.assertEqual($out.status, 200);
    testing.assertTrue($out.changed);
    testing.assertTrue(store.isYanked($out.db, "@acme/routeros", "0.1.0"));
    testing.assertTrue(json.asBool($out.body, "/yanked"));
}

func testYankingIsReversible() {
    def db as flatdb.DB init setYanked(published(), alice(),
        "@acme/routeros", "0.1.0", true).db;
    def out as PublishReply init setYanked($db, alice(), "@acme/routeros", "0.1.0", false);
    testing.assertEqual($out.status, 200);
    testing.assertFalse(store.isYanked($out.db, "@acme/routeros", "0.1.0"));
}

func testAYankIsIdempotent() {
    # a retry after a lost response must not read as a failure
    def db as flatdb.DB init setYanked(published(), alice(),
        "@acme/routeros", "0.1.0", true).db;
    def again as PublishReply init setYanked($db, alice(), "@acme/routeros", "0.1.0", true);
    testing.assertEqual($again.status, 200);
    testing.assertFalse($again.changed);
    testing.assertEqual($again.event.level, "");
}

func testAStrangerCannotYank() {
    def out as PublishReply init setYanked(published(), stranger(),
        "@acme/routeros", "0.1.0", true);
    testing.assertEqual($out.status, 403);
    testing.assertFalse(store.isYanked($out.db, "@acme/routeros", "0.1.0"));
}

func testAuthorisationComesBeforeExistence() {
    # a caller with no rights to a scope must not learn which versions it holds
    # by watching 404 against 403
    def out as PublishReply init setYanked(published(), stranger(),
        "@acme/routeros", "9.9.9", true);
    testing.assertEqual($out.status, 403);
}

func testYankingAnUnknownVersionIs404ForTheOwner() {
    def out as PublishReply init setYanked(published(), alice(),
        "@acme/routeros", "9.9.9", true);
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
    def out as PublishReply init setYanked(published(), alice(),
        "@acme/routeros", "0.1.0", true);
    testing.assertContains($out.event.message, "yanked");
    testing.assertEqual($out.event.fields["version"], "0.1.0");
}
