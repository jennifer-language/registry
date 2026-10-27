# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for store.j. Run with:
#
#     jennifer test src/store_test.j
#
# store.j `use`s json and imports flatdb, so the overlay reaches DeckVersion /
# Resolution by bare name and flatdb.DB via the flatdb namespace.

use testing;
use fs;
use os;

# emptyStore returns an open, schema-normalized store over a missing file.
func emptyStore() {
    return open("/no/such/jvc/registry/missing.json");
}

# A full-length commit SHA, the pin a git version carries.
def const SAMPLE_COMMIT as string init "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293";

# sampleVersion builds a git-kind DeckVersion for tests.
func sampleVersion(version as string, url as string) {
    return DeckVersion{
        version: $version,
        kind: KIND_GIT,
        url: $url,
        ref: "v" + $version,
        commit: SAMPLE_COMMIT,
        checksum: "",
        requires: {},
        engines: {},
        capabilities: [],
        description: "v " + $version,
        publishedAt: "1700000000",
        yanked: false,
        license: "",
        keywords: []
    };
}

func testEmptyStoreHasNoDecks() {
    def db as flatdb.DB init emptyStore();
    testing.assertEqual(len(listDecks($db)), 0);
    testing.assertFalse(hasDeck($db, "ansi"));
}

func testPutVersionCreatesDeck() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "terminal styling", sampleVersion("1.2.0", "https://x/a"));
    testing.assertTrue(hasDeck($db, "ansi"));
    testing.assertEqual(deckDescription($db, "ansi"), "terminal styling");
    testing.assertTrue(hasVersion($db, "ansi", "1.2.0"));
    testing.assertEqual(len(listVersions($db, "ansi")), 1);
}

func testPutVersionIsImmutable() {
    def db as flatdb.DB init emptyStore();
    def grown as flatdb.DB init putVersion($db, "ansi", "", sampleVersion("1.0.0", "u"));
    testing.assertFalse(hasDeck($db, "ansi"));
    testing.assertTrue(hasDeck($grown, "ansi"));
}

func testMultipleVersions() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "styling", sampleVersion("1.0.0", "u1"));
    $db = putVersion($db, "ansi", "", sampleVersion("1.2.0", "u2"));
    $db = putVersion($db, "ansi", "", sampleVersion("2.0.0", "u3"));
    testing.assertEqual(len(listVersions($db, "ansi")), 3);
    # An empty description on a later put leaves the first one intact.
    testing.assertEqual(deckDescription($db, "ansi"), "styling");
}

func testUpdateExistingDeckDescription() {
    # A later put with a non-empty description updates the existing deck record
    # (regression: this path writes a scalar back through flatdb.set).
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "first", sampleVersion("1.0.0", "u1"));
    $db = putVersion($db, "ansi", "second", sampleVersion("1.1.0", "u2"));
    testing.assertEqual(deckDescription($db, "ansi"), "second");
    testing.assertEqual(len(listVersions($db, "ansi")), 2);
}

func testGetVersionJsonFields() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "csv", "rfc 4180", sampleVersion("0.4.0", "https://x/csv"));
    def rec as json.Value init getVersionJson($db, "csv", "0.4.0");
    testing.assertEqual(json.asString($rec, "/url"), "https://x/csv");
    testing.assertEqual(json.asString($rec, "/kind"), KIND_GIT);
    testing.assertEqual(json.asString($rec, "/ref"), "v0.4.0");
    testing.assertEqual(json.asString($rec, "/commit"), SAMPLE_COMMIT);
    # a git version stores an empty checksum rather than omitting the field
    testing.assertEqual(json.asString($rec, "/checksum"), "");
}

func testResolveCaret() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "styling", sampleVersion("1.0.0", "u1"));
    $db = putVersion($db, "ansi", "", sampleVersion("1.4.3", "u2"));
    $db = putVersion($db, "ansi", "", sampleVersion("2.0.0", "u3"));
    def r as Resolution init resolve($db, "ansi", "^1.2.0");
    testing.assertTrue($r.found);
    testing.assertEqual($r.version, "1.4.3");
    testing.assertEqual($r.url, "u2");
}

func testResolveMissingDeck() {
    def db as flatdb.DB init emptyStore();
    def r as Resolution init resolve($db, "ghost", "*");
    testing.assertFalse($r.found);
    testing.assertEqual($r.version, "");
}

func testResolveNoSatisfyingVersion() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "", sampleVersion("1.0.0", "u1"));
    def r as Resolution init resolve($db, "ansi", "^2.0.0");
    testing.assertFalse($r.found);
}

func testRemoveVersion() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "", sampleVersion("1.0.0", "u1"));
    $db = putVersion($db, "ansi", "", sampleVersion("1.1.0", "u2"));
    $db = removeVersion($db, "ansi", "1.0.0");
    testing.assertFalse(hasVersion($db, "ansi", "1.0.0"));
    testing.assertTrue(hasVersion($db, "ansi", "1.1.0"));
    testing.assertTrue(hasDeck($db, "ansi"));
}

func testRemoveDeck() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "", sampleVersion("1.0.0", "u1"));
    $db = removeDeck($db, "ansi");
    testing.assertFalse(hasDeck($db, "ansi"));
}

func testSaveThenReopen() {
    def path as string init os.tempDir() + "/jvc_store_test.json";
    def db as flatdb.DB init open($path);
    $db = putVersion($db, "ansi", "styling", sampleVersion("1.2.0", "https://x/ansi"));
    save($db);
    def reloaded as flatdb.DB init open($path);
    testing.assertTrue(hasVersion($reloaded, "ansi", "1.2.0"));
    def r as Resolution init resolve($reloaded, "ansi", "*");
    testing.assertEqual($r.url, "https://x/ansi");
    fs.remove($path);
}

# --- kind + namespace registry ----------------------------------------------

# A well-formed artifact digest, the pin a tar.gz version carries.
def const SAMPLE_CHECKSUM as string init "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"; # lint-disable: L203

# tarVersion builds a tar.gz-kind DeckVersion for tests.
func tarVersion(version as string, url as string) {
    return DeckVersion{
        version: $version,
        kind: KIND_TARGZ,
        url: $url,
        ref: "",
        commit: "",
        checksum: SAMPLE_CHECKSUM,
        requires: {},
        engines: {},
        capabilities: [],
        description: "v " + $version,
        publishedAt: "1700000000",
        yanked: false,
        license: "",
        keywords: []
    };
}

func testResolveReportsKind() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "styling", sampleVersion("1.0.0", "u"));
    $db = putVersion($db, "@jennifer/routeros", "ros", tarVersion("0.1.0", "https://x/ros.tgz"));
    def g as Resolution init resolve($db, "ansi", "*");
    testing.assertEqual($g.kind, KIND_GIT);
    testing.assertEqual($g.commit, SAMPLE_COMMIT);
    testing.assertEqual($g.checksum, "");
    def r as Resolution init resolve($db, "@jennifer/routeros", "*");
    testing.assertEqual($r.kind, KIND_TARGZ);
    testing.assertEqual($r.url, "https://x/ros.tgz");
    testing.assertEqual($r.checksum, SAMPLE_CHECKSUM);
    testing.assertEqual($r.commit, "");
}

func testNamespaceRegisterHasList() {
    def db as flatdb.DB init emptyStore();
    testing.assertFalse(hasNamespace($db, "jennifer"));
    $db = registerNamespace($db, aNamespace("jennifer", "1", "alice"));
    testing.assertTrue(hasNamespace($db, "jennifer"));
    testing.assertEqual(len(listNamespaces($db)), 1);
    testing.assertEqual(listNamespaces($db)[0], "jennifer");
}

func testNamespaceRemove() {
    def db as flatdb.DB init emptyStore();
    $db = registerNamespace($db, aNamespace("jennifer", "1", "alice"));
    $db = removeNamespace($db, "jennifer");
    testing.assertFalse(hasNamespace($db, "jennifer"));
}

func testVersionEngines() {
    def db as flatdb.DB init emptyStore();
    def ver as DeckVersion init DeckVersion{
        version: "1.0.0",
        kind: KIND_TARGZ,
        url: "u",
        ref: "",
        commit: "",
        checksum: SAMPLE_CHECKSUM,
        requires: {},
        engines: {"jennifer": "^0.21.0"},
        capabilities: [],
        description: "",
        publishedAt: "0",
        yanked: false,
        license: "",
        keywords: []
    };
    $db = putVersion($db, "@a/b", "", $ver);
    def e as map of string to string init versionEngines($db, "@a/b", "1.0.0");
    testing.assertEqual(len($e), 1);
    testing.assertEqual($e["jennifer"], "^0.21.0");
    # a version with no engines reads as an empty (unrestricted) map
    $db = putVersion($db, "bare", "", sampleVersion("1.0.0", "u"));
    testing.assertEqual(len(versionEngines($db, "bare", "1.0.0")), 0);
}

# aNamespace builds a Namespace record for tests.
func aNamespace(scope as string, subject as string, login as string) {
    return Namespace{
        scope: $scope,
        provider: "github",
        subject: $subject,
        login: $login,
        registeredAt: "1700000000",
        kind: SCOPE_USER,
        coOwners: []
    };
}

# --- refresh tokens ---------------------------------------------------------

# aRefresh builds a Refresh record for tests.
func aRefresh(subject as string, expiresAt as int) {
    return Refresh{
        subject: $subject,
        login: "alice",
        expiresAt: $expiresAt,
        orgs: {},
        orgsCheckedAt: 0
    };
}

func testRefreshRoundTrips() {
    def db as flatdb.DB init emptyStore();
    $db = putRefresh($db, "aaaa", aRefresh("42", 1800000000));
    testing.assertTrue(hasRefresh($db, "aaaa"));
    def rec as Refresh init getRefresh($db, "aaaa");
    testing.assertEqual($rec.subject, "42");
    testing.assertEqual($rec.login, "alice");
    testing.assertEqual($rec.expiresAt, 1800000000);
}

func testTheOrganisationsOnARefreshRoundTrip() {
    # A refresh reissues memberships without asking the provider, so a lost map
    # would strip every organisation scope at the first token expiry.
    def db as flatdb.DB init emptyStore();
    $db = putRefresh(
        $db,
        "bbbb",
        Refresh{
            subject: "42",
            login: "alice",
            expiresAt: 1800000000,
            orgs: {"acme": "7", "viverto": "42"},
            orgsCheckedAt: 1700000000
        });
    def rec as Refresh init getRefresh($db, "bbbb");
    testing.assertEqual(len($rec.orgs), 2);
    testing.assertEqual($rec.orgs["acme"], "7");
    testing.assertEqual($rec.orgs["viverto"], "42");
    testing.assertEqual($rec.orgsCheckedAt, 1700000000);
}

func testUnknownRefreshIsAbsent() {
    testing.assertFalse(hasRefresh(emptyStore(), "nope"));
}

func testDeleteRefreshIsANoOpWhenUnknown() {
    # a logout or a rotation should never have to check first
    def db as flatdb.DB init deleteRefresh(emptyStore(), "nope");
    testing.assertFalse(hasRefresh($db, "nope"));
}

func testDeleteRefreshRemovesOnlyThatToken() {
    def db as flatdb.DB init emptyStore();
    $db = putRefresh($db, "aaaa", aRefresh("42", 1800000000));
    $db = putRefresh($db, "bbbb", aRefresh("42", 1800000000));
    $db = deleteRefresh($db, "aaaa");
    testing.assertFalse(hasRefresh($db, "aaaa"));
    testing.assertTrue(hasRefresh($db, "bbbb"));
}

func testRevokeAccountDropsEveryTokenOfThatAccount() {
    # the operator path for invalidating an identity's outstanding tokens
    def db as flatdb.DB init emptyStore();
    $db = putRefresh($db, "aaaa", aRefresh("42", 1800000000));
    $db = putRefresh($db, "bbbb", aRefresh("42", 1800000000));
    $db = putRefresh($db, "cccc", aRefresh("99", 1800000000));
    $db = revokeAccount($db, "42");
    testing.assertFalse(hasRefresh($db, "aaaa"));
    testing.assertFalse(hasRefresh($db, "bbbb"));
    testing.assertTrue(hasRefresh($db, "cccc"));
}

func testAForgeTokenIsKeptPerAccount() {
    def db as flatdb.DB init emptyStore();
    testing.assertEqual(getForgeToken($db, "42"), "");
    $db = putForgeToken($db, "42", "sealed-1", 1700000000);
    testing.assertEqual(getForgeToken($db, "42"), "sealed-1");
    testing.assertEqual(getForgeToken($db, "99"), "");
    # a later login replaces it: no history of old credentials is kept
    $db = putForgeToken($db, "42", "sealed-2", 1700000100);
    testing.assertEqual(getForgeToken($db, "42"), "sealed-2");
}

func testRevokingAnAccountDropsItsForgeToken() {
    # a revoked account must not leave a credential the registry could act with
    def db as flatdb.DB init emptyStore();
    $db = putForgeToken($db, "42", "sealed", 1700000000);
    $db = putForgeToken($db, "99", "other", 1700000000);
    $db = revokeAccount($db, "42");
    testing.assertEqual(getForgeToken($db, "42"), "");
    testing.assertEqual(getForgeToken($db, "99"), "other");
}

func testCountRefreshCountsOnlyThatAccount() {
    # asked before a revoke so the log records what was dropped
    def db as flatdb.DB init emptyStore();
    testing.assertEqual(countRefresh($db, "42"), 0);
    $db = putRefresh($db, "aaaa", aRefresh("42", 1800000000));
    $db = putRefresh($db, "bbbb", aRefresh("42", 1800000000));
    $db = putRefresh($db, "cccc", aRefresh("99", 1800000000));
    testing.assertEqual(countRefresh($db, "42"), 2);
    testing.assertEqual(countRefresh($db, "99"), 1);
    testing.assertEqual(countRefresh($db, "7"), 0);
}

func testPurgeDropsOnlyExpiredTokens() {
    def db as flatdb.DB init emptyStore();
    $db = putRefresh($db, "old", aRefresh("42", 1000));
    $db = putRefresh($db, "live", aRefresh("42", 1800000000));
    $db = purgeExpiredRefresh($db, 2000);
    testing.assertFalse(hasRefresh($db, "old"));
    testing.assertTrue(hasRefresh($db, "live"));
}

# legacyRefresh is a refresh record as written from 2026-08-16 to 08-18, with
# `orgs` a list of organisation ids.
func legacyRefresh(expiresAt as string) {
    return json.decode('{"subject": "42", "login": "alice", "orgs": ["7", "9"], ' +
        '"orgsCheckedAt": 1755300000, "expiresAt": ' + $expiresAt + '}');
}

func testARefreshRecordWithOrgsAsAListReadsWithNone() {
    def db as flatdb.DB init flatdb.set(emptyStore(), "/refreshTokens", json.map());
    $db = flatdb.set($db, "/refreshTokens/aug", legacyRefresh("1800000000"));
    def rec as Refresh init getRefresh($db, "aug");
    testing.assertEqual($rec.subject, "42");
    testing.assertEqual(len($rec.orgs), 0);
    testing.assertEqual($rec.expiresAt, 1800000000);
}

func testPurgeGetsPastARecordInAnOlderShape() {
    # regression: one such record threw in the purge, so every login and
    # refresh answered 500 (live, 2026-10-28)
    def db as flatdb.DB init flatdb.set(emptyStore(), "/refreshTokens", json.map());
    $db = flatdb.set($db, "/refreshTokens/aug", legacyRefresh("1756000000"));
    $db = putRefresh($db, "live", aRefresh("42", 1800000000));
    $db = purgeExpiredRefresh($db, 1793200000);
    testing.assertFalse(hasRefresh($db, "aug"));
    testing.assertTrue(hasRefresh($db, "live"));
}

func testPurgeTreatsTheExpiryInstantAsExpired() {
    def db as flatdb.DB init emptyStore();
    $db = putRefresh($db, "edge", aRefresh("42", 2000));
    $db = purgeExpiredRefresh($db, 2000);
    testing.assertFalse(hasRefresh($db, "edge"));
}

# --- name folding -----------------------------------------------------------

func testALookupFindsEitherCasing() {
    # specification 2.1: a name is recorded folded, and either spelling finds it
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "@Acme/Tool", "mixed case", sampleVersion("1.0.0", "u"));
    testing.assertTrue(hasDeck($db, "@acme/tool"));
    testing.assertTrue(hasDeck($db, "@ACME/TOOL"));
    testing.assertTrue(hasVersion($db, "@Acme/Tool", "1.0.0"));
}

func testOnlyTheFoldedNameIsRecorded() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "@Acme/Tool", "mixed case", sampleVersion("1.0.0", "u"));
    def names as list of string init listDecks($db);
    testing.assertEqual(len($names), 1);
    testing.assertEqual($names[0], "@acme/tool");
    # and the name inside the record agrees with its key
    testing.assertEqual(json.asString(getDeckJson($db, "@acme/tool"), "/name"), "@acme/tool");
}

func testTwoCasingsAreOneDeckNotTwo() {
    # otherwise the collision surfaces at install time on a case-insensitive
    # filesystem
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "@acme/tool", "", sampleVersion("1.0.0", "u1"));
    $db = putVersion($db, "@ACME/TOOL", "", sampleVersion("2.0.0", "u2"));
    testing.assertEqual(len(listDecks($db)), 1);
    testing.assertEqual(len(listVersions($db, "@acme/tool")), 2);
}

func testNamespacesFoldToo() {
    def db as flatdb.DB init emptyStore();
    $db = registerNamespace($db, aNamespace("Acme", "1", "alice"));
    testing.assertTrue(hasNamespace($db, "acme"));
    testing.assertTrue(hasNamespace($db, "ACME"));
    testing.assertEqual(listNamespaces($db)[0], "acme");
}

# --- yanking ------------------------------------------------------------------

func yankedStore() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "styling", sampleVersion("1.0.0", "u1"));
    $db = putVersion($db, "ansi", "", sampleVersion("1.4.3", "u2"));
    $db = putVersion($db, "ansi", "", sampleVersion("2.0.0", "u3"));
    return setYanked($db, "ansi", "1.4.3", true);
}

func testAYankedVersionIsNotChosenByAResolution() {
    def r as Resolution init resolve(yankedStore(), "ansi", "^1.0.0");
    testing.assertTrue($r.found);
    # 1.4.3 is the highest match but it is withdrawn, so 1.0.0 wins
    testing.assertEqual($r.version, "1.0.0");
}

func testAYankedVersionStaysFetchable() {
    # an existing lockfile pins it and must keep installing
    def db as flatdb.DB init yankedStore();
    testing.assertTrue(hasVersion($db, "ansi", "1.4.3"));
    testing.assertEqual(getVersionRecord($db, "ansi", "1.4.3").url, "u2");
    testing.assertTrue(isYanked($db, "ansi", "1.4.3"));
}

func testAYankedVersionIsStillListed() {
    # a deck page shows every version; only resolution filters
    def db as flatdb.DB init yankedStore();
    testing.assertEqual(len(listVersions($db, "ansi")), 3);
    testing.assertEqual(len(listLiveVersions($db, "ansi")), 2);
}

func testYankingEveryVersionLeavesNothingToResolve() {
    def db as flatdb.DB init yankedStore();
    $db = setYanked($db, "ansi", "1.0.0", true);
    $db = setYanked($db, "ansi", "2.0.0", true);
    testing.assertFalse(resolve($db, "ansi", "*").found);
    # but the deck and its records are all still there
    testing.assertTrue(hasDeck($db, "ansi"));
    testing.assertEqual(len(listVersions($db, "ansi")), 3);
}

func testUnyankRestores() {
    def db as flatdb.DB init setYanked(yankedStore(), "ansi", "1.4.3", false);
    testing.assertFalse(isYanked($db, "ansi", "1.4.3"));
    testing.assertEqual(resolve($db, "ansi", "^1.0.0").version, "1.4.3");
}

func testARecordWrittenBeforeYankingExistedIsLive() {
    # absent reads as false
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "", sampleVersion("1.0.0", "u"));
    def rec as json.Value init getVersionJson($db, "ansi", "1.0.0");
    $rec = json.remove($rec, "/yanked");
    $db = flatdb.set($db, "/decks/ansi/versions/1.0.0", $rec);
    testing.assertFalse(isYanked($db, "ansi", "1.0.0"));
    testing.assertTrue(resolve($db, "ansi", "*").found);
}

# --- the write lock ------------------------------------------------------------

func lockPath() {
    return os.tempDir() + "/jvc_lock_test.json";
}

# freshLock clears any lock a previously failed run left behind, which would
# otherwise wedge later runs for the stale window.
func freshLock() {
    try {
        fs.remove(lockPath() + ".lock");
    } catch (err) { # lint-disable: L103
        # nothing to clear
    }
    return null;
}

func testALockIsExclusive() {
    freshLock();
    # flatdb.save does not lock; this prevents a lost edit between two writers
    def held as Lock init lock(lockPath());
    testing.assertThrows("takesASecondLock", "store");
    unlock($held);
}

func takesASecondLock() {
    def second as Lock init lock(lockPath());
    unlock($second);
    return null;
}

func testALockIsRetakeableAfterRelease() {
    freshLock();
    def first as Lock init lock(lockPath());
    unlock($first);
    def second as Lock init lock(lockPath());
    unlock($second);
    testing.assertEqual(lockHolder(lockPath()), "");
}

func testReleasingSomebodyElsesLockIsANoOp() {
    freshLock();
    # a writer whose lock was broken as stale must not then free the lock its
    # replacement is holding
    def held as Lock init lock(lockPath());
    def impostor as Lock init Lock{path: $held.path, holder: "someone-else 1"};
    unlock($impostor);
    testing.assertEqual(lockHolder(lockPath()), $held.holder);
    unlock($held);
    testing.assertEqual(lockHolder(lockPath()), "");
}

func testUnlockingTwiceIsHarmless() {
    freshLock();
    def held as Lock init lock(lockPath());
    unlock($held);
    unlock($held);
    testing.assertEqual(lockHolder(lockPath()), "");
}

func testAnAbandonedLockIsBroken() {
    freshLock();
    # a killed writer's lock is broken past the stale window
    fs.writeString(lockPath() + ".lock", "crashed-writer 1");
    def held as Lock init lock(lockPath());
    testing.assertEqual(lockHolder(lockPath()), $held.holder);
    unlock($held);
}

func testALockThatCannotBeCreatedSaysSo() {
    # a missing or read-only directory must not read as contention
    def message as string init "";
    try {
        lock("/no/such/registry/dir/registry.json");
    } catch (err) {
        $message = $err.message;
    }
    testing.assertContains($message, "cannot create");
}

# --- object-id-shaped names ---------------------------------------------------
#
# A ref of this shape shadows the object of the same id wherever a name
# resolves first (Plugin4Shell).

func testAFullCommitShaIsObjectIdLike() {
    testing.assertTrue(isObjectIdLike(SAMPLE_COMMIT));
}

func testAnAbbreviatedShaIsObjectIdLike() {
    # git resolves from seven hex digits up, so the whole range is ambiguous
    testing.assertTrue(isObjectIdLike("9f2c1d4"));
    testing.assertTrue(isObjectIdLike("9f2c1d4e5a6b"));
}

func testUppercaseHexIsObjectIdLikeToo() {
    # git's hex parsing takes either case
    testing.assertTrue(isObjectIdLike("9F2C1D4E5A6B7C8D9E0F1A2B3C4D5E6F70819293"));
    testing.assertTrue(isObjectIdLike("9F2c1D4"));
}

func testASha256ObjectIdIsObjectIdLike() {
    # a SHA-256 repository has 64-character ids
    def id as string init SAMPLE_COMMIT + SAMPLE_COMMIT;
    testing.assertTrue(isObjectIdLike(strings.substring($id, 0, 64)));
}

func testShortHexIsNotObjectIdLike() {
    # below git's abbreviation floor a name cannot be read as an id
    testing.assertFalse(isObjectIdLike("cafe"));
    testing.assertFalse(isObjectIdLike("abc123"));
    testing.assertFalse(isObjectIdLike(""));
}

func testARealTagIsNotObjectIdLike() {
    testing.assertFalse(isObjectIdLike("v1.2.0"));
    testing.assertFalse(isObjectIdLike("1.2.0"));
    testing.assertFalse(isObjectIdLike("release-3"));
    testing.assertFalse(isObjectIdLike("deadbeefs"));
}

func testTooLongToBeAnObjectIdIsNotObjectIdLike() {
    testing.assertFalse(isObjectIdLike(SAMPLE_COMMIT + SAMPLE_COMMIT));
}

func testAVersionTooLargeToCompareSortsLastWithoutThrowing() {
    # one such record must not make its deck unlistable
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "", sampleVersion("1.0.0", "u"));
    $db = putVersion($db, "ansi", "", sampleVersion("99999999999999999999.0.0", "u"));
    $db = putVersion($db, "ansi", "", sampleVersion("2.0.0", "u"));
    def order as list of string init listVersionsDescending($db, "ansi");
    testing.assertEqual($order[0], "2.0.0");
    testing.assertEqual($order[2], "99999999999999999999.0.0");
}

func testPlainVersionsSortNumerically() {
    # the fast path compares numbers, so 1.10.0 is above 1.9.0
    def db as flatdb.DB init emptyStore();
    for (def v in ["1.9.0", "1.10.0", "0.2.0", "10.0.0"]) {
        $db = putVersion($db, "ansi", "", sampleVersion($v, "u"));
    }
    def order as list of string init listVersionsDescending($db, "ansi");
    testing.assertEqual(strings.join($order, " "), "10.0.0 1.10.0 1.9.0 0.2.0");
}

func testAPrereleaseSortsBelowItsRelease() {
    # one non-plain version sends the whole list down the SemVer path
    def db as flatdb.DB init emptyStore();
    for (def v in ["1.0.0-rc.1", "1.0.0", "0.9.0", "1.0.0-beta"]) {
        $db = putVersion($db, "ansi", "", sampleVersion($v, "u"));
    }
    def order as list of string init listVersionsDescending($db, "ansi");
    testing.assertEqual(strings.join($order, " "), "1.0.0 1.0.0-rc.1 1.0.0-beta 0.9.0");
}

func testAScopeNameCannotReachInsideAnotherScopesRecord() {
    def db as flatdb.DB init registerNamespace(
        emptyStore(),
        Namespace{
            scope: "acme",
            provider: "github",
            subject: "1",
            login: "a",
            registeredAt: "0",
            kind: SCOPE_USER,
            coOwners: []
        });
    testing.assertTrue(hasNamespace($db, "acme"));
    testing.assertFalse(hasNamespace($db, "acme/subject"));
    testing.assertFalse(hasNamespace($db, "acme/provider"));
}

func testProvenanceStoresIdsAsNumbersAndSkipsWhatIsNotOne() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "@acme/x", "", sampleVersion("1.0.0", "https://x/y"));
    def p as Provenance init Provenance{repoId: "123", repoOwnerId: "abc", repoOwner: "acme"};
    $db = putProvenance($db, "@acme/x", "1.0.0", $p);
    testing.assertEqual(json.asInt(getVersionJson($db, "@acme/x", "1.0.0"), "/repoId"), 123);
    def back as Provenance init provenanceOf($db, "@acme/x", "1.0.0");
    testing.assertEqual($back.repoId, "123");
    testing.assertEqual($back.repoOwnerId, "");
    testing.assertEqual($back.repoOwner, "acme");
}

func testAForgeLinkIsKeptPerSubjectAndDroppedOnRevoke() {
    def db as flatdb.DB init emptyStore();
    testing.assertEqual(getForgeLink($db, "a/b~c").forgeId, "");
    def link as ForgeLink init ForgeLink{forgeId: "583231", forgeLogin: "octocat", linkedAt: 5};
    $db = putForgeLink($db, "a/b~c", $link);
    testing.assertEqual(getForgeLink($db, "a/b~c").forgeLogin, "octocat");
    $db = revokeAccount($db, "a/b~c");
    testing.assertEqual(getForgeLink($db, "a/b~c").forgeId, "");
}

func scopeBinding(key as string, repoId as string) {
    return trustpub.Binding{
        provider: "github-actions",
        repositoryId: $repoId,
        repository: "acme/x",
        workflow: "",
        refPattern: "refs/tags/*",
        deck: $key,
        pending: false,
        createdAt: "1"
    };
}

func testADeckBindingWinsOverItsScopes() {
    # 8.9: a binding on a deck, or on its scope
    def db as flatdb.DB init putBinding(emptyStore(), scopeBinding("@acme", "1"));
    testing.assertEqual(bindingFor($db, "@acme/tool").repositoryId, "1");
    $db = putBinding($db, scopeBinding("@acme/tool", "2"));
    testing.assertEqual(bindingFor($db, "@acme/tool").repositoryId, "2");
    testing.assertEqual(bindingFor($db, "@acme/other").repositoryId, "1");
    testing.assertEqual(bindingFor($db, "@beta/tool").repositoryId, "");
}

func testReassigningAScopeDropsItsScopeBinding() {
    def db as flatdb.DB init putBinding(emptyStore(), scopeBinding("@acme", "1"));
    $db = putBinding($db, scopeBinding("@acme/tool", "2"));
    $db = putBinding($db, scopeBinding("@beta", "3"));
    $db = dropDelegations($db, "acme");
    testing.assertFalse(hasBinding($db, "@acme"));
    testing.assertFalse(hasBinding($db, "@acme/tool"));
    testing.assertTrue(hasBinding($db, "@beta"));
}

# --- audit fixes (2026-10-26) ------------------------------------------------

func testFiftyShuffledPlainVersionsSortHighestFirst() {
    def db as flatdb.DB init emptyStore();
    def want as list of string init [];
    for (def i in 0..50) {
        # 37 is coprime to 50, so this visits every number once, out of order
        def n as int init ($i * 37) % 50;
        $db = putVersion($db, "ansi", "", sampleVersion("1." + convert.toString($n) + ".0", "u"));
    }
    for (def i in 0..50) {
        $want[] = "1." + convert.toString(49 - $i) + ".0";
    }
    testing.assertEqual(
        strings.join(listVersionsDescending($db, "ansi"), " "),
        strings.join($want, " "));
}

func testShuffledSemVerVersionsSortByPrecedenceWithUnusableLast() {
    def db as flatdb.DB init emptyStore();
    def given as list of string init [
        "1.0.0-rc.1",
        "2.0.0",
        "99999999999999999999.0.0",
        "1.0.0",
        "1.0.0-beta",
        "0.9.0",
        "2.0.0-alpha",
        "1.10.0",
        "1.9.0",
        "bogus.0.0"
    ];
    for (def v in $given) {
        $db = putVersion($db, "ansi", "", sampleVersion($v, "u"));
    }
    testing.assertEqual(
        strings.join(listVersionsDescending($db, "ansi"), " "),
        "2.0.0 2.0.0-alpha 1.10.0 1.9.0 1.0.0 1.0.0-rc.1 1.0.0-beta 0.9.0 " +
            "99999999999999999999.0.0 bogus.0.0");
}

func testRemovingADeckDropsItsLookupCounts() {
    def db as flatdb.DB init putVersion(
        emptyStore(),
        "@acme/tool",
        "",
        sampleVersion("1.0.0", "u"));
    $db = putStats($db, "@acme/tool", json.set(json.map(), "/total", 7));
    testing.assertTrue(json.has(getStats($db, "@acme/tool"), "/total"));
    $db = removeDeck($db, "@acme/tool");
    testing.assertFalse(json.has(getStats($db, "@acme/tool"), "/total"));
}

func testReplacingAVersionKeepsProvenanceAndWithdrawal() {
    def db as flatdb.DB init putVersion(
        emptyStore(),
        "@acme/tool",
        "",
        sampleVersion("1.0.0", "u1"));
    $db = putProvenance(
        $db,
        "@acme/tool",
        "1.0.0",
        Provenance{repoId: "123", repoOwnerId: "77", repoOwner: "acme"});
    $db = setYanked($db, "@acme/tool", "1.0.0", true);
    def withMeta as DeckVersion init sampleVersion("1.0.0", "u1");
    $withMeta.license = "MIT";
    $withMeta.keywords = ["net"];
    $db = putVersion($db, "@acme/tool", "", $withMeta);
    # an operator `update`: a new pin, nothing else said
    $db = putVersion($db, "@acme/tool", "", sampleVersion("1.0.0", "u2"));
    def rec as DeckVersion init getVersionRecord($db, "@acme/tool", "1.0.0");
    testing.assertEqual($rec.url, "u2");
    testing.assertTrue($rec.yanked);
    testing.assertEqual($rec.license, "MIT");
    testing.assertEqual(strings.join($rec.keywords, ","), "net");
    testing.assertEqual(provenanceOf($db, "@acme/tool", "1.0.0").repoId, "123");
    testing.assertEqual(provenanceOf($db, "@acme/tool", "1.0.0").repoOwner, "acme");
    # a new version carries nothing over
    def fresh as DeckVersion init getVersionRecord(
        putVersion($db, "@acme/tool", "", sampleVersion("1.1.0", "u3")),
        "@acme/tool",
        "1.1.0");
    testing.assertFalse($fresh.yanked);
    testing.assertEqual($fresh.license, "");
}

func testARefreshRecordWithOddKeysAndMissingFieldsReads() {
    def db as flatdb.DB init putRefresh(
        emptyStore(),
        "a/b~c",
        Refresh{subject: "u1", login: "alice", expiresAt: 5, orgs: {"x/y": "9"}, orgsCheckedAt: 0});
    testing.assertTrue(hasRefresh($db, "a/b~c"));
    testing.assertFalse(hasRefresh($db, "a"));
    def rec as Refresh init getRefresh($db, "a/b~c");
    testing.assertEqual($rec.orgs["x/y"], "9");
    testing.assertEqual($rec.expiresAt, 5);
    # a hand-edited record: fields absent or of the wrong type read as zero
    def odd as flatdb.DB init flatdb.set(
        $db,
        "/refreshTokens/old",
        json.set(json.set(json.map(), "/subject", "u2"), "/expiresAt", "soon"));
    def got as Refresh init getRefresh($odd, "old");
    testing.assertEqual($got.subject, "u2");
    testing.assertEqual($got.login, "");
    testing.assertEqual($got.expiresAt, 0);
    testing.assertEqual(countRefresh($odd, "u2"), 1);
}

func testAForgeLinkWithoutATimeReads() {
    def db as flatdb.DB init flatdb.set(emptyStore(), "/forgeLinks", json.map());
    $db = flatdb.set($db, "/forgeLinks/u1", json.set(json.map(), "/forgeId", "42"));
    testing.assertEqual(getForgeLink($db, "u1").forgeId, "42");
    testing.assertEqual(getForgeLink($db, "u1").linkedAt, 0);
}
