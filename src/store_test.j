# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for store.j. Run with:
#
#     JENNIFER_SYSMODDIR=../jennifer-lang/modules jennifer test server/store_test.j
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
        license: ""
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
def const SAMPLE_CHECKSUM as string init
    "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

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
        license: ""
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
        version: "1.0.0", kind: KIND_TARGZ, url: "u",
        ref: "", commit: "", checksum: SAMPLE_CHECKSUM,
        requires: {}, engines: {"jennifer": "^0.21.0"}, capabilities: [],
        description: "", publishedAt: "0",
        yanked: false,
        license: ""
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
        scope: $scope, provider: "github", subject: $subject,
        login: $login, registeredAt: "1700000000",
        kind: SCOPE_USER,
        coOwners: []
    };
}

# --- refresh tokens ---------------------------------------------------------

# aRefresh builds a Refresh record for tests.
func aRefresh(accountId as int, expiresAt as int) {
    return Refresh{ accountId: $accountId, login: "alice", expiresAt: $expiresAt,
        orgs: [], orgsCheckedAt: 0 };
}

func testRefreshRoundTrips() {
    def db as flatdb.DB init emptyStore();
    $db = putRefresh($db, "aaaa", aRefresh(42, 1800000000));
    testing.assertTrue(hasRefresh($db, "aaaa"));
    def rec as Refresh init getRefresh($db, "aaaa");
    testing.assertEqual($rec.accountId, 42);
    testing.assertEqual($rec.login, "alice");
    testing.assertEqual($rec.expiresAt, 1800000000);
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
    $db = putRefresh($db, "aaaa", aRefresh(42, 1800000000));
    $db = putRefresh($db, "bbbb", aRefresh(42, 1800000000));
    $db = deleteRefresh($db, "aaaa");
    testing.assertFalse(hasRefresh($db, "aaaa"));
    testing.assertTrue(hasRefresh($db, "bbbb"));
}

func testRevokeAccountDropsEveryTokenOfThatAccount() {
    # the operator path for invalidating an identity's outstanding tokens
    def db as flatdb.DB init emptyStore();
    $db = putRefresh($db, "aaaa", aRefresh(42, 1800000000));
    $db = putRefresh($db, "bbbb", aRefresh(42, 1800000000));
    $db = putRefresh($db, "cccc", aRefresh(99, 1800000000));
    $db = revokeAccount($db, 42);
    testing.assertFalse(hasRefresh($db, "aaaa"));
    testing.assertFalse(hasRefresh($db, "bbbb"));
    testing.assertTrue(hasRefresh($db, "cccc"));
}

func testCountRefreshCountsOnlyThatAccount() {
    # asked before a revoke so the log records what was actually dropped
    def db as flatdb.DB init emptyStore();
    testing.assertEqual(countRefresh($db, 42), 0);
    $db = putRefresh($db, "aaaa", aRefresh(42, 1800000000));
    $db = putRefresh($db, "bbbb", aRefresh(42, 1800000000));
    $db = putRefresh($db, "cccc", aRefresh(99, 1800000000));
    testing.assertEqual(countRefresh($db, 42), 2);
    testing.assertEqual(countRefresh($db, 99), 1);
    # a count of zero usually means the operator has the wrong account id
    testing.assertEqual(countRefresh($db, 7), 0);
}

func testPurgeDropsOnlyExpiredTokens() {
    def db as flatdb.DB init emptyStore();
    $db = putRefresh($db, "old", aRefresh(42, 1000));
    $db = putRefresh($db, "live", aRefresh(42, 1800000000));
    $db = purgeExpiredRefresh($db, 2000);
    testing.assertFalse(hasRefresh($db, "old"));
    testing.assertTrue(hasRefresh($db, "live"));
}

func testPurgeTreatsTheExpiryInstantAsExpired() {
    def db as flatdb.DB init emptyStore();
    $db = putRefresh($db, "edge", aRefresh(42, 2000));
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
    # the collision that would otherwise appear only on a case-insensitive
    # filesystem, at install time, on somebody else's machine
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
    # the whole point: an existing lockfile pins it and must keep installing
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
    # the field is additive: absent reads as false, which is what those records
    # always meant
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "", sampleVersion("1.0.0", "u"));
    def rec as json.Value init getVersionJson($db, "ansi", "1.0.0");
    $rec = json.remove($rec, "/yanked");
    $db = flatdb.set($db, "/decks/ansi/versions/1.0.0", $rec);
    testing.assertFalse(isYanked($db, "ansi", "1.0.0"));
    testing.assertTrue(resolve($db, "ansi", "*").found);
}
