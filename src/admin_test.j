# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for admin.j. Run with:
#
#     jennifer test src/admin_test.j
#
# Tests go through `parse` and the real grammar, so the parser is exercised
# too. Most start from `registered()`, since a deck's scope must be registered.

use testing;
use json;
import "./policy/firstcome.j" as firstcome;
import "./identity.j" as identity;

def const NOW as string init "1700000000";

# A full-length commit SHA and a well-formed artifact digest, the two pins.
def const COMMIT as string init "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293";
def const CHECKSUM as string init "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"; # lint-disable: L203

func emptyStore() {
    return store.open("/no/such/jvc/admin/missing.json");
}

# dispatch parses argv and routes it to its command, as bin/deckadmin does.
# `args.dispatch` needs program-level state a module cannot hold, so this
# matches on the command instead.
func dispatch(db as flatdb.DB, argv as list of string) {
    def r as args.Result init parse($argv);
    match ($r.command) {
        when "add", "update" { return cmdAdd($db, $r, NOW); }
        when "remove" { return cmdRemove($db, $r, NOW); }
        when "list" { return cmdList($db, $r, NOW); }
        when "register-namespace" { return cmdRegisterNamespace($db, $r, NOW); }
        when "add-owner" { return cmdAddOwner($db, $r, NOW); }
        when "remove-owner" { return cmdRemoveOwner($db, $r, NOW); }
        when "namespaces" { return cmdNamespaces($db, $r, NOW); }
        when "reserve-defaults" { return cmdReserveDefaults($db, $r, NOW); }
        when "mint-token" { return cmdMintToken($db, $r, NOW); }
        when "tokens" { return cmdTokens($db, $r, NOW); }
        when "revoke-token" { return cmdRevokeToken($db, $r, NOW); }
        when "yank" { return cmdSetYanked($db, $r, NOW, true); }
        when "unyank" { return cmdSetYanked($db, $r, NOW, false); }
        when "trust" { return cmdTrust($db, $r, NOW); }
        when "untrust" { return cmdUntrust($db, $r, NOW); }
        when "publishers" { return cmdPublishers($db, $r, NOW); }
        when "revoke" { return cmdRevoke($db, $r, NOW); }
    }
    return failResult($db, "no such command");
}

# registered returns a store with the "acme" scope registered, the precondition
# every publish has.
func registered() {
    return dispatch(emptyStore(), ["deckadmin", "register-namespace", "acme"]).db;
}

# gitAdd builds the argument vector that publishes a git version.
func gitAdd(name as string, version as string, url as string) {
    return ["deckadmin", "add", $name, $version, $url, "--ref", "v" + $version, "--commit", COMMIT];
}

# --- the parser -------------------------------------------------------------

func testParseReadsPositionalsAndFlags() {
    def r as args.Result init parse(gitAdd("@acme/ansi", "1.2.0", "https://x/a"));
    testing.assertEqual($r.command, "add");
    testing.assertEqual(args.asString($r, "deck"), "@acme/ansi");
    testing.assertEqual(args.asString($r, "version"), "1.2.0");
    testing.assertEqual(args.asString($r, "url"), "https://x/a");
    testing.assertEqual(args.asString($r, "commit"), COMMIT);
    # an omitted optional positional falls back to its default
    testing.assertEqual(args.asString($r, "description"), "");
}

func testParseHelpIsDoneNotAnError() {
    def r as args.Result init parse(["deckadmin", "--help"]);
    testing.assertTrue($r.done);
    testing.assertContains($r.helpText, "deckadmin");
}

# The zero-argument shims assertThrows dispatches by name.
func throwsOnMissingPositional() {
    parse(["deckadmin", "add", "@acme/ansi"]);
}

func throwsOnUnknownFlag() {
    parse(["deckadmin", "list", "--bogus"]);
}

func testParseRejectsMissingPositional() {
    testing.assertThrows("throwsOnMissingPositional", "args");
}

func testParseRejectsUnknownFlag() {
    testing.assertThrows("throwsOnUnknownFlag", "args");
}

# --- publishing a git version -----------------------------------------------

func testAddStoresGitVersion() {
    def r as AdminResult init dispatch(registered(), gitAdd("@acme/ansi", "1.2.0", "https://x/a"));
    testing.assertTrue($r.ok);
    testing.assertTrue($r.changed);
    testing.assertTrue(store.hasVersion($r.db, "@acme/ansi", "1.2.0"));
    def rec as json.Value init store.getVersionJson($r.db, "@acme/ansi", "1.2.0");
    testing.assertEqual(json.asString($rec, "/url"), "https://x/a");
    testing.assertEqual(json.asString($rec, "/kind"), store.KIND_GIT);
    testing.assertEqual(json.asString($rec, "/ref"), "v1.2.0");
    testing.assertEqual(json.asString($rec, "/commit"), COMMIT);
    testing.assertEqual(json.asString($rec, "/publishedAt"), NOW);
}

func testGitAddNeedsBothRefAndCommit() {
    def db as flatdb.DB init registered();
    def onlyRef as list of string init [
        "deckadmin",
        "add",
        "@acme/ansi",
        "1.0.0",
        "https://x/u",
        "--ref",
        "v1.0.0"
    ];
    def a as AdminResult init dispatch($db, $onlyRef);
    testing.assertFalse($a.ok);
    testing.assertContains($a.message, "both --ref and --commit");
    def onlyCommit as list of string init [
        "deckadmin",
        "add",
        "@acme/ansi",
        "1.0.0",
        "https://x/u",
        "--commit",
        COMMIT
    ];
    def b as AdminResult init dispatch($db, $onlyCommit);
    testing.assertFalse($b.ok);
    testing.assertContains($b.message, "both --ref and --commit");
}

func testGitAddRejectsAbbreviatedCommit() {
    def args as list of string init [
        "deckadmin",
        "add",
        "@acme/ansi",
        "1.0.0",
        "https://x/u",
        "--ref",
        "v1.0.0",
        "--commit",
        "9f2c1d4"
    ];
    def r as AdminResult init dispatch(registered(), $args);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "40-character");
}

func testGitAddRejectsUppercaseCommit() {
    def args as list of string init [
        "deckadmin",
        "add",
        "@acme/ansi",
        "1.0.0",
        "https://x/u",
        "--ref",
        "v1.0.0",
        "--commit",
        "9F2C1D4E5A6B7C8D9E0F1A2B3C4D5E6F70819293"
    ];
    def r as AdminResult init dispatch(registered(), $args);
    testing.assertFalse($r.ok);
}

func testGitAddRejectsAChecksum() {
    def args as list of string init [
        "deckadmin",
        "add",
        "@acme/ansi",
        "1.0.0",
        "https://x/u",
        "--ref",
        "v1.0.0",
        "--commit",
        COMMIT,
        "--checksum",
        CHECKSUM
    ];
    def r as AdminResult init dispatch(registered(), $args);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "the commit is the pin");
}

func testAddRefusesARefShapedLikeAnObjectId() {
    # an operator record is served like a published one, so the ref rule applies
    def r as AdminResult init dispatch(
        registered(),
        [
            "deckadmin",
            "add",
            "@acme/ansi",
            "1.0.0",
            "https://x/a",
            "--ref",
            COMMIT,
            "--commit",
            COMMIT
        ]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "object id");
    testing.assertFalse(store.hasVersion($r.db, "@acme/ansi", "1.0.0"));
}

func testAddStillTakesAnOrdinaryTag() {
    # the guard refuses a shape, not tags in general
    def r as AdminResult init dispatch(registered(), gitAdd("@acme/ansi", "1.0.0", "https://x/a"));
    testing.assertTrue($r.ok);
}

# --- publishing a tar.gz version --------------------------------------------

func testTarGzAddRecordsChecksum() {
    def args as list of string init [
        "deckadmin",
        "add",
        "@acme/ros",
        "0.1.0",
        "https://x/ros.tgz",
        "--checksum",
        CHECKSUM
    ];
    def r as AdminResult init dispatch(registered(), $args);
    testing.assertTrue($r.ok);
    def rec as json.Value init store.getVersionJson($r.db, "@acme/ros", "0.1.0");
    testing.assertEqual(json.asString($rec, "/kind"), store.KIND_TARGZ);
    testing.assertEqual(json.asString($rec, "/checksum"), CHECKSUM);
    testing.assertEqual(json.asString($rec, "/commit"), "");
}

func testTarGzAddNeedsAChecksum() {
    def r as AdminResult init dispatch(
        registered(),
        ["deckadmin", "add", "@acme/ros", "0.1.0", "https://x/u"]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "needs --checksum");
}

func testTarGzAddRejectsMalformedChecksum() {
    def args as list of string init [
        "deckadmin",
        "add",
        "@acme/ros",
        "0.1.0",
        "https://x/u",
        "--checksum",
        "sha256:abc"
    ];
    def r as AdminResult init dispatch(registered(), $args);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "64 lowercase hex");
}

# --- names, scopes, and versions --------------------------------------------

func testBareNameIsRejected() {
    def r as AdminResult init dispatch(emptyStore(), gitAdd("ansi", "1.0.0", "https://x/u"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not a registry deck name");
}

func testAddRejectsAHyphenInTheDeckHalf() {
    # the deck half takes no hyphen, unlike the scope half
    def r as AdminResult init dispatch(
        registered(),
        gitAdd("@acme/bad-name", "1.0.0", "https://x/u"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "valid deck name");
}

func testAddRejectsAWindowsDeviceName() {
    def r as AdminResult init dispatch(registered(), gitAdd("@acme/con", "1.0.0", "https://x/u"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "valid deck name");
}

func testAddFoldsTheDeckName() {
    def r as AdminResult init dispatch(
        registered(),
        gitAdd("@ACME/Routeros", "1.0.0", "https://x/u"));
    testing.assertTrue($r.ok);
    testing.assertTrue(store.hasVersion($r.db, "@acme/routeros", "1.0.0"));
    testing.assertEqual(store.listDecks($r.db)[0], "@acme/routeros");
}

func testScopedAddRequiresNamespace() {
    def r as AdminResult init dispatch(emptyStore(), gitAdd("@acme/ros", "0.1.0", "https://x/u"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not registered");
}

func testAddRejectsBadVersion() {
    def r as AdminResult init dispatch(registered(), gitAdd("@acme/ansi", "vX", "https://x/u"));
    testing.assertFalse($r.ok);
    testing.assertFalse($r.changed);
}

func testAddRejectsAVersionTooLargeToOrder() {
    # an operator-written record is held to the same rule as a published one
    def r as AdminResult init dispatch(
        registered(),
        gitAdd("@acme/ansi", "99999999999999999999.0.0", "https://x/u"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "18 digits");
}

func requiresAdd(spec as string) {
    return [
        "deckadmin",
        "add",
        "@acme/ros",
        "1.0.0",
        "https://x/u",
        "--ref",
        "v1.0.0",
        "--commit",
        COMMIT,
        "--requires",
        $spec
    ];
}

func testAddRejectsABadDependency() {
    def badName as AdminResult init dispatch(registered(), requiresAdd("net ^1.0.0"));
    testing.assertFalse($badName.ok);
    testing.assertContains($badName.message, "not a deck name");
    def badConstraint as AdminResult init dispatch(registered(), requiresAdd("@acme/net ~>1.2"));
    testing.assertFalse($badConstraint.ok);
    testing.assertContains($badConstraint.message, "not a valid version constraint");
}

func testAddFoldsDependencyNames() {
    def r as AdminResult init dispatch(registered(), requiresAdd("@ACME/Net ^1.0.0"));
    testing.assertTrue($r.ok);
    testing.assertEqual(store.versionRequires($r.db, "@acme/ros", "1.0.0")["@acme/net"], "^1.0.0");
}

func testUpdateUpserts() {
    def db as flatdb.DB init registered();
    $db = dispatch($db, gitAdd("@acme/ansi", "1.0.0", "https://x/u1")).db;
    def argv as list of string init gitAdd("@acme/ansi", "1.0.0", "https://x/u2");
    $argv[1] = "update";
    def r as AdminResult init dispatch($db, $argv);
    testing.assertTrue($r.changed);
    def rec as json.Value init store.getVersionJson($r.db, "@acme/ansi", "1.0.0");
    testing.assertEqual(json.asString($rec, "/url"), "https://x/u2");
}

# --- removal and listing ----------------------------------------------------

func testRemoveVersion() {
    def db as flatdb.DB init registered();
    $db = dispatch($db, gitAdd("@acme/ansi", "1.0.0", "https://x/u1")).db;
    $db = dispatch($db, gitAdd("@acme/ansi", "1.1.0", "https://x/u2")).db;
    def r as AdminResult init dispatch($db, ["deckadmin", "remove", "@acme/ansi", "1.0.0"]);
    testing.assertTrue($r.changed);
    testing.assertFalse(store.hasVersion($r.db, "@acme/ansi", "1.0.0"));
    testing.assertTrue(store.hasVersion($r.db, "@acme/ansi", "1.1.0"));
}

func testRemoveWholeDeck() {
    def db as flatdb.DB init registered();
    $db = dispatch($db, gitAdd("@acme/ansi", "1.0.0", "https://x/u1")).db;
    def r as AdminResult init dispatch($db, ["deckadmin", "remove", "@acme/ansi"]);
    testing.assertTrue($r.changed);
    testing.assertFalse(store.hasDeck($r.db, "@acme/ansi"));
}

func testRemoveMissingFails() {
    def r as AdminResult init dispatch(registered(), ["deckadmin", "remove", "@acme/ghost"]);
    testing.assertFalse($r.ok);
    testing.assertFalse($r.changed);
}

func testListDecks() {
    def db as flatdb.DB init registered();
    $db = dispatch($db, gitAdd("@acme/ansi", "1.0.0", "https://x/u1")).db;
    $db = dispatch($db, gitAdd("@acme/csv", "0.4.0", "https://x/u2")).db;
    def r as AdminResult init dispatch($db, ["deckadmin", "list"]);
    testing.assertTrue($r.ok);
    testing.assertFalse($r.changed);
    testing.assertContains($r.message, "@acme/ansi");
    testing.assertContains($r.message, "@acme/csv");
}

func testListOneDeckVersions() {
    def db as flatdb.DB init registered();
    $db = dispatch($db, gitAdd("@acme/ansi", "1.0.0", "https://x/u1")).db;
    $db = dispatch($db, gitAdd("@acme/ansi", "1.2.0", "https://x/u2")).db;
    def r as AdminResult init dispatch($db, ["deckadmin", "list", "@acme/ansi"]);
    testing.assertContains($r.message, "1.0.0");
    testing.assertContains($r.message, "1.2.0");
}

func testListEmpty() {
    def r as AdminResult init dispatch(emptyStore(), ["deckadmin", "list"]);
    testing.assertTrue($r.ok);
    testing.assertContains($r.message, "empty");
}

# --- namespaces -------------------------------------------------------------

func testRegisterNamespaceAcceptsAtPrefixAndIsIdempotent() {
    def db as flatdb.DB init emptyStore();
    $db = dispatch($db, ["deckadmin", "register-namespace", "@acme"]).db;
    testing.assertTrue(store.hasNamespace($db, "acme"));
    # second time: ok but not a change
    def again as AdminResult init dispatch($db, ["deckadmin", "register-namespace", "acme"]);
    testing.assertTrue($again.ok);
    testing.assertFalse($again.changed);
}

func testRegisterNamespaceAcceptsAHyphenatedScope() {
    # a real account name; the reason the two grammars differ
    def argv as list of string init ["deckadmin", "register-namespace", "jennifer-language"];
    def r as AdminResult init dispatch(emptyStore(), $argv);
    testing.assertTrue($r.ok);
    testing.assertTrue(store.hasNamespace($r.db, "jennifer-language"));
}

func testRegisterNamespaceRejectsBadScope() {
    # a leading hyphen parses as a flag, so only positionals are tried here;
    # the grammar is covered in deckname_test.j
    def bad as list of string init ["acme-", "a--b", "my_org", "con"];
    for (def scope in $bad) {
        def r as AdminResult init dispatch(
            emptyStore(),
            ["deckadmin", "register-namespace", $scope]);
        testing.assertFalse($r.ok);
        testing.assertContains($r.message, "valid scope name");
    }
}

func testRegisterNamespaceFoldsTheScope() {
    def r as AdminResult init dispatch(emptyStore(), ["deckadmin", "register-namespace", "@Acme"]);
    testing.assertTrue($r.ok);
    testing.assertTrue(store.hasNamespace($r.db, "acme"));
    testing.assertEqual(store.listNamespaces($r.db)[0], "acme");
}

func testNamespacesList() {
    def r as AdminResult init dispatch(registered(), ["deckadmin", "namespaces"]);
    testing.assertContains($r.message, "@acme");
}

# --- flags ------------------------------------------------------------------

func testAddCapturesEngines() {
    def args as list of string init [
        "deckadmin",
        "add",
        "@acme/ansi",
        "1.0.0",
        "https://x/u",
        "styling",
        "--ref",
        "v1.0.0",
        "--commit",
        COMMIT,
        "--engines",
        "jennifer ^0.24.0, jennifer-tiny ^0.5.0"
    ];
    def r as AdminResult init dispatch(registered(), $args);
    testing.assertTrue($r.ok);
    def e as map of string to string init store.versionEngines($r.db, "@acme/ansi", "1.0.0");
    testing.assertEqual($e["jennifer"], "^0.24.0");
    testing.assertEqual($e["jennifer-tiny"], "^0.5.0");
    # the positional description survives however many flags precede or follow it
    def rec as json.Value init store.getVersionJson($r.db, "@acme/ansi", "1.0.0");
    testing.assertEqual(json.asString($rec, "/description"), "styling");
}

func testAddCapturesRequiresAndCapabilities() {
    def args as list of string init [
        "deckadmin",
        "add",
        "@acme/ros",
        "1.0.0",
        "https://x/u",
        "--ref",
        "v1.0.0",
        "--commit",
        COMMIT,
        "--requires",
        "@acme/net ^1.0.0",
        "--capabilities",
        "net, exec"
    ];
    def r as AdminResult init dispatch(registered(), $args);
    testing.assertTrue($r.ok);
    def req as map of string to string init store.versionRequires($r.db, "@acme/ros", "1.0.0");
    testing.assertEqual($req["@acme/net"], "^1.0.0");
    def caps as list of string init store.versionCapabilities($r.db, "@acme/ros", "1.0.0");
    testing.assertEqual(len($caps), 2);
    testing.assertEqual($caps[0], "net");
}

# --- revoking an identity's tokens ------------------------------------------

func testRevokeDropsThatAccountsRefreshTokens() {
    def db as flatdb.DB init emptyStore();
    $db = store.putRefresh(
        $db,
        "aaaa",
        store.Refresh{
            accountId: 42,
            login: "alice",
            expiresAt: 1800000000,
            orgs: {},
            orgsCheckedAt: 0
        });
    $db = store.putRefresh(
        $db,
        "bbbb",
        store.Refresh{
            accountId: 99,
            login: "bob",
            expiresAt: 1800000000,
            orgs: {},
            orgsCheckedAt: 0
        });
    def r as AdminResult init dispatch($db, ["deckadmin", "revoke", "42"]);
    testing.assertTrue($r.ok);
    testing.assertTrue($r.changed);
    testing.assertFalse(store.hasRefresh($r.db, "aaaa"));
    testing.assertTrue(store.hasRefresh($r.db, "bbbb"));
}

func testRevokeRejectsANonNumericAccountId() {
    # ownership binds to the numeric id, so a login is not an answer here
    def r as AdminResult init dispatch(emptyStore(), ["deckadmin", "revoke", "alice"]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not a numeric account id");
}

# --- logging configuration ----------------------------------------------------

func noArgs() {
    return parse(["deckadmin", "list"]);
}

func testLogOptionsFallBackToTheEnvironment() {
    def o as LogOptions init logOptions(noArgs(), "data/registry.log", "warn", "json");
    testing.assertEqual($o.path, "data/registry.log");
    testing.assertEqual($o.level, "warn");
    testing.assertEqual($o.format, "json");
}

func testAFlagBeatsTheEnvironment() {
    # a flag overrides a container-wide setting for one command
    def r as args.Result init parse([
        "deckadmin",
        "--log",
        "/tmp/one.log",
        "--log-level",
        "debug",
        "list"
    ]);
    def o as LogOptions init logOptions($r, "data/registry.log", "warn", "json");
    testing.assertEqual($o.path, "/tmp/one.log");
    testing.assertEqual($o.level, "debug");
    # untouched by the flags, so still the environment's
    testing.assertEqual($o.format, "json");
}

func testTheFileFormatDefaultsToLogfmt() {
    def o as LogOptions init logOptions(noArgs(), "", "", "");
    testing.assertEqual($o.format, "logfmt");
    testing.assertEqual($o.path, "");
}

func testConsoleAndQuietAreOffByDefault() {
    # deckadmin already prints a result line; mirroring events would double it
    def o as LogOptions init logOptions(noArgs(), "", "", "");
    testing.assertFalse($o.console);
    testing.assertFalse($o.quiet);
}

func testVerboseAndQuietAreReadFromTheRootParser() {
    def r as args.Result init parse(["deckadmin", "-v", "-q", "list"]);
    def o as LogOptions init logOptions($r, "", "", "");
    testing.assertTrue($o.console);
    testing.assertTrue($o.quiet);
}

func testAPublishRecordsAnEventForTheLog() {
    def out as AdminResult init dispatch(
        registered(),
        gitAdd("@acme/ansi", "1.2.0", "https://x/a"));
    testing.assertTrue($out.ok);
    testing.assertEqual($out.event.fields["deck"], "@acme/ansi");
    testing.assertEqual($out.event.fields["version"], "1.2.0");
    testing.assertEqual($out.event.fields["pin"], COMMIT);
}

func testRepublishingTheSameVersionIsRecordedAsAReplacement() {
    def argv as list of string init gitAdd("@acme/ansi", "1.2.0", "https://x/a");
    def db as flatdb.DB init dispatch(registered(), $argv).db;
    def out as AdminResult init dispatch($db, gitAdd("@acme/ansi", "1.2.0", "https://x/b"));
    testing.assertContains($out.event.message, "replaced");
}

func testAListRecordsNothing() {
    def out as AdminResult init dispatch(registered(), ["deckadmin", "list"]);
    testing.assertEqual($out.event.level, "");
}

func testAFailedCommandIsRecorded() {
    def out as AdminResult init dispatch(emptyStore(), gitAdd("@ghost/x", "1.0.0", "https://x/a"));
    testing.assertFalse($out.ok);
    testing.assertContains($out.event.message, "failed");
    testing.assertContains($out.event.fields["reason"], "not registered");
}

# --- trusted publishers -------------------------------------------------------

func trusted() {
    return dispatch(
        owned(),
        [
            "deckadmin",
            "trust",
            "@acme/ansi",
            "123456789",
            "--repository",
            "acme/deck-ansi",
            "--workflow",
            "acme/deck-ansi/.github/workflows/publish.yml"
        ]);
}

func testTrustRegistersABinding() {
    def r as AdminResult init trusted();
    testing.assertTrue($r.ok);
    testing.assertTrue(store.hasBinding($r.db, "@acme/ansi"));
    def b as trustpub.Binding init store.getBinding($r.db, "@acme/ansi");
    testing.assertEqual($b.repositoryId, "123456789");
    testing.assertEqual($b.provider, trustpub.GITHUB);
    # the default narrows to tags rather than admitting every branch build
    testing.assertEqual($b.refPattern, "refs/tags/*");
}

func testTrustNeedsTheRepositoryId() {
    # the path is renameable and re-registerable, so it cannot be the key
    def r as AdminResult init dispatch(
        owned(),
        ["deckadmin", "trust", "@acme/ansi", "", "--repository", "acme/deck-ansi"]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "repository id");
}

func testTrustNeedsARegisteredScope() {
    # a binding is a standing write grant, gated like a publish
    def r as AdminResult init dispatch(emptyStore(), ["deckadmin", "trust", "@ghost/x", "1"]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not registered");
}

func testTrustNeedsAnOwnedScope() {
    # a trusted publisher acts for an owner; on a reserved scope it would bypass
    # the reservation
    def r as AdminResult init dispatch(
        registered(),
        ["deckadmin", "trust", "@acme/ansi", "123456789"]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "reserved");
    testing.assertFalse(store.hasBinding($r.db, "@acme/ansi"));
}

func testTrustRejectsAnUnknownProvider() {
    def r as AdminResult init dispatch(
        owned(),
        ["deckadmin", "trust", "@acme/ansi", "1", "--provider", "jenkins"]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "unknown CI provider");
}

func testABindingOnADecklessScopeIsPending() {
    # 8.9's first-publish case: the deck does not exist yet
    def b as trustpub.Binding init store.getBinding(trusted().db, "@acme/ansi");
    testing.assertTrue($b.pending);

    def db as flatdb.DB init dispatch(owned(), gitAdd("@acme/ansi", "1.0.0", "https://x/a")).db;
    def after as AdminResult init dispatch($db, ["deckadmin", "trust", "@acme/ansi", "1"]);
    testing.assertFalse(store.getBinding($after.db, "@acme/ansi").pending);
}

func testTrustIsRecordedLoudly() {
    def r as AdminResult init trusted();
    testing.assertEqual($r.event.level, audit.WARN);
    testing.assertEqual($r.event.fields["repositoryId"], "123456789");
}

# --- CI tokens ----------------------------------------------------------------

func testMintingUnderAnOwnedScopeWorks() {
    def r as AdminResult init dispatch(owned(), ["deckadmin", "mint-token", "acme"]);
    testing.assertTrue($r.ok);
    # the secret is shown once and never stored, so the message is the only copy
    testing.assertContains($r.message, citoken.PREFIX);
}

func testMintingNeedsAnOwnedScope() {
    # a reserved scope has nobody to delegate for; refused at the mint so no
    # unusable token exists
    def r as AdminResult init dispatch(registered(), ["deckadmin", "mint-token", "acme"]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "reserved");
}

func testMintingNeedsARegisteredScope() {
    def r as AdminResult init dispatch(emptyStore(), ["deckadmin", "mint-token", "ghost"]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not registered");
}

func testUntrustRemovesIt() {
    def r as AdminResult init dispatch(trusted().db, ["deckadmin", "untrust", "@acme/ansi"]);
    testing.assertTrue($r.ok);
    testing.assertFalse(store.hasBinding($r.db, "@acme/ansi"));
    testing.assertContains($r.event.message, "untrusted");
}

func testUntrustingNothingFails() {
    def r as AdminResult init dispatch(registered(), ["deckadmin", "untrust", "@acme/ansi"]);
    testing.assertFalse($r.ok);
}

func testPublishersLists() {
    def empty as AdminResult init dispatch(registered(), ["deckadmin", "publishers"]);
    testing.assertContains($empty.message, "no trusted publishers");
    def r as AdminResult init dispatch(trusted().db, ["deckadmin", "publishers"]);
    testing.assertContains($r.message, "@acme/ansi");
    testing.assertContains($r.message, "acme/deck-ansi");
    testing.assertContains($r.message, "pending");
}

# --- reserving the defaults ---------------------------------------------------

func testReserveDefaultsHoldsThemAll() {
    def r as AdminResult init dispatch(emptyStore(), ["deckadmin", "reserve-defaults"]);
    testing.assertTrue($r.ok);
    testing.assertTrue($r.changed);
    for (def name in ["official", "admin", "api", "jennifer"]) {
        testing.assertTrue(store.hasNamespace($r.db, $name));
        # held, but bound to nobody: reserved is not owned
        testing.assertEqual(store.getNamespace($r.db, $name).subject, "");
    }
}

func testAReservedScopeCannotBeClaimed() {
    def db as flatdb.DB init dispatch(emptyStore(), ["deckadmin", "reserve-defaults"]).db;
    def who as identity.Subject init identity.Subject{
        provider: "github",
        id: "1",
        login: "admin",
        orgs: {},
        orgsCheckedAt: ""
    };
    def out as scope.ClaimResult init scope.claim($db, firstcome.policy(), $who, "admin", [], NOW);
    testing.assertFalse($out.allowed);
    # reported as reserved, not as claimed by another account
    testing.assertContains($out.reason, "reserved by this registry");
}

func testReserveDefaultsIsIdempotent() {
    def once as flatdb.DB init dispatch(emptyStore(), ["deckadmin", "reserve-defaults"]).db;
    def twice as AdminResult init dispatch($once, ["deckadmin", "reserve-defaults"]);
    testing.assertTrue($twice.ok);
    testing.assertFalse($twice.changed);
    testing.assertContains($twice.message, "already reserved");
}

func testReserveDefaultsNeverSeizesAnOwnedScope() {
    # taking a name back is an operator grant, not this command
    def db as flatdb.DB init dispatch(
        emptyStore(),
        ["deckadmin", "register-namespace", "api", "--owner", "42", "--login", "eve"]).db;
    def r as AdminResult init dispatch($db, ["deckadmin", "reserve-defaults"]);
    testing.assertEqual(store.getNamespace($r.db, "api").subject, "42");
    testing.assertContains($r.message, "OWNED BY SOMEBODY");
    testing.assertContains($r.message, "api");
}

func testDryRunChangesNothing() {
    def r as AdminResult init dispatch(
        emptyStore(),
        ["deckadmin", "reserve-defaults", "--dry-run"]);
    testing.assertFalse($r.changed);
    testing.assertContains($r.message, "dry run");
    testing.assertFalse(store.hasNamespace($r.db, "admin"));
}

func testNamespacesDistinguishesOwnedFromReserved() {
    # each line says whether the scope has an owner
    def db as flatdb.DB init dispatch(emptyStore(), ["deckadmin", "reserve-defaults"]).db;
    $db = dispatch(
        $db,
        ["deckadmin", "register-namespace", "jennifer", "--owner", "12345", "--login", "mplx"]).db;
    def r as AdminResult init dispatch($db, ["deckadmin", "namespaces"]);
    testing.assertContains($r.message, "1 owned");
    testing.assertContains($r.message, "@jennifer  mplx [github 12345]");
    testing.assertContains($r.message, "@admin  (reserved, no owner)");
}

func testNamespacesFilters() {
    def db as flatdb.DB init dispatch(emptyStore(), ["deckadmin", "reserve-defaults"]).db;
    $db = dispatch(
        $db,
        ["deckadmin", "register-namespace", "jennifer", "--owner", "12345", "--login", "mplx"]).db;
    def owned as AdminResult init dispatch($db, ["deckadmin", "namespaces", "--owned"]);
    testing.assertContains($owned.message, "@jennifer");
    testing.assertFalse(strings.contains($owned.message, "@admin"));
    def held as AdminResult init dispatch($db, ["deckadmin", "namespaces", "--reserved"]);
    testing.assertContains($held.message, "@admin");
    testing.assertFalse(strings.contains($held.message, "@jennifer  mplx"));
}

func testGrantingAReservedScopeMakesItPublishable() {
    # a reserved scope is held until an operator grants it
    def db as flatdb.DB init dispatch(emptyStore(), ["deckadmin", "reserve-defaults"]).db;
    testing.assertEqual(store.getNamespace($db, "jennifer").subject, "");
    $db = dispatch(
        $db,
        ["deckadmin", "register-namespace", "jennifer", "--owner", "12345", "--login", "mplx"]).db;
    testing.assertTrue(store.ownsNamespace($db, "jennifer", "github", "12345"));
    def r as AdminResult init dispatch($db, gitAdd("@jennifer/routeros", "0.1.0", "https://x/a"));
    testing.assertTrue($r.ok);
}

# --- co-owners ----------------------------------------------------------------

func owned() {
    return dispatch(
        emptyStore(),
        ["deckadmin", "register-namespace", "acme", "--owner", "1000", "--login", "alice"]).db;
}

func testACoOwnerMayWriteUnderTheScope() {
    def db as flatdb.DB init dispatch(owned(), ["deckadmin", "add-owner", "acme", "2000"]).db;
    def bob as identity.Subject init identity.Subject{
        provider: "github",
        id: "2000",
        login: "bob",
        orgs: {},
        orgsCheckedAt: ""
    };
    testing.assertTrue(scope.authorise($db, $bob, "acme").allowed);
    # and the owner still can
    def alice as identity.Subject init identity.Subject{
        provider: "github",
        id: "1000",
        login: "alice",
        orgs: {},
        orgsCheckedAt: ""
    };
    testing.assertTrue(scope.authorise($db, $alice, "acme").allowed);
}

func testACoOwnerIsNotTheOwner() {
    # adding one is not a transfer
    def db as flatdb.DB init dispatch(owned(), ["deckadmin", "add-owner", "acme", "2000"]).db;
    testing.assertEqual(store.getNamespace($db, "acme").subject, "1000");
    testing.assertEqual(len(store.ownersOf($db, "acme")), 2);
}

func testAStrangerStillCannot() {
    def db as flatdb.DB init dispatch(owned(), ["deckadmin", "add-owner", "acme", "2000"]).db;
    def eve as identity.Subject init identity.Subject{
        provider: "github",
        id: "3000",
        login: "eve",
        orgs: {},
        orgsCheckedAt: ""
    };
    testing.assertFalse(scope.authorise($db, $eve, "acme").allowed);
}

func testACoOwnerOfAnotherProviderIsNotAMatch() {
    # a scope binds to one provider; the same numeric id elsewhere is a
    # different principal
    def db as flatdb.DB init dispatch(owned(), ["deckadmin", "add-owner", "acme", "2000"]).db;
    def elsewhere as identity.Subject init identity.Subject{
        provider: "gitea",
        id: "2000",
        login: "bob",
        orgs: {},
        orgsCheckedAt: ""
    };
    testing.assertFalse(scope.authorise($db, $elsewhere, "acme").allowed);
}

func testAddingACoOwnerIsIdempotent() {
    def db as flatdb.DB init dispatch(owned(), ["deckadmin", "add-owner", "acme", "2000"]).db;
    def again as AdminResult init dispatch($db, ["deckadmin", "add-owner", "acme", "2000"]);
    testing.assertFalse($again.changed);
    testing.assertContains($again.message, "already a co-owner");
}

func testAReservedScopeCannotTakeACoOwner() {
    # no owner to co-own with; a co-owner could write under a held scope
    def argv as list of string init ["deckadmin", "register-namespace", "jennifer"];
    def db as flatdb.DB init dispatch(emptyStore(), $argv).db;
    def r as AdminResult init dispatch($db, ["deckadmin", "add-owner", "jennifer", "2000"]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "reserved");
}

func testTheOwnerCannotBeRemovedAsACoOwner() {
    # losing the last owner would leave decks nobody can yank
    def db as flatdb.DB init dispatch(owned(), ["deckadmin", "add-owner", "acme", "2000"]).db;
    def r as AdminResult init dispatch($db, ["deckadmin", "remove-owner", "acme", "1000"]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "is the owner");
    testing.assertContains($r.message, "register-namespace");
}

func testRemovingACoOwnerRevokesTheirWrite() {
    def db as flatdb.DB init dispatch(owned(), ["deckadmin", "add-owner", "acme", "2000"]).db;
    $db = dispatch($db, ["deckadmin", "remove-owner", "acme", "2000"]).db;
    def bob as identity.Subject init identity.Subject{
        provider: "github",
        id: "2000",
        login: "bob",
        orgs: {},
        orgsCheckedAt: ""
    };
    testing.assertFalse(scope.authorise($db, $bob, "acme").allowed);
    testing.assertEqual(len(store.ownersOf($db, "acme")), 1);
}

func testRemovingSomebodyWhoIsNotACoOwnerFails() {
    def r as AdminResult init dispatch(owned(), ["deckadmin", "remove-owner", "acme", "9999"]);
    testing.assertFalse($r.ok);
}

func testCoOwnersAreShownInTheListing() {
    def db as flatdb.DB init dispatch(owned(), ["deckadmin", "add-owner", "acme", "2000"]).db;
    def r as AdminResult init dispatch($db, ["deckadmin", "namespaces"]);
    testing.assertContains($r.message, "co-owner(s): 2000");
}

func testARecordWithoutCoOwnersReadsAsOne() {
    # the field is additive: a record without the list still works
    testing.assertEqual(len(store.getNamespace(owned(), "acme").coOwners), 0);
    testing.assertEqual(len(store.ownersOf(owned(), "acme")), 1);
}

func testAReservedScopeHasNoOwnersAtAll() {
    def argv as list of string init ["deckadmin", "register-namespace", "jennifer"];
    def db as flatdb.DB init dispatch(emptyStore(), $argv).db;
    testing.assertEqual(len(store.ownersOf($db, "jennifer")), 0);
}

# --- keywords ----------------------------------------------------------------

func testKeywordsListsTheRefusedTermsDecoded() {
    # the only way to read the base64 list in plaintext
    def out as AdminResult init cmdKeywords(emptyStore(), parse(["deckadmin", "keywords"]), NOW);
    testing.assertTrue($out.ok);
    testing.assertFalse($out.changed);
    testing.assertContains($out.message, keywords.abuse()[0]);
    testing.assertContains($out.message, keywords.adult()[0]);
}

func testKeywordsEncodesATermForTheList() {
    def out as AdminResult init cmdKeywords(
        emptyStore(),
        parse(["deckadmin", "keywords", "gambling"]),
        NOW);
    testing.assertTrue($out.ok);
    testing.assertContains($out.message, keywords.encode("gambling"));
}

func testKeywordsFlagsATermThatCouldNeverMatch() {
    # lookups run on well-formed keywords, so a term with a space never matches
    def out as AdminResult init cmdKeywords(
        emptyStore(),
        parse(["deckadmin", "keywords", "two words"]),
        NOW);
    testing.assertContains($out.message, "never match");
}

func testKeywordsSaysWhenATermIsAlreadyRefused() {
    def out as AdminResult init cmdKeywords(
        emptyStore(),
        parse(["deckadmin", "keywords", keywords.adult()[0]]),
        NOW);
    testing.assertContains($out.message, "already refused");
}

func testKeywordsNeverWrites() {
    # it reads a compiled-in list and must work with no registry
    def out as AdminResult init cmdKeywords(emptyStore(), parse(["deckadmin", "keywords"]), NOW);
    testing.assertFalse($out.changed);
}

func testAddRefusesAnUnfetchableUrl() {
    def bad as list of string init ["", "javascript:alert(1)", "relative/path"];
    $bad[] = 'https://x/a"b';
    $bad[] = "https://x/a b";
    for (def url in $bad) {
        def r as AdminResult init dispatch(registered(), gitAdd("@acme/ansi", "1.0.0", $url));
        testing.assertFalse($r.ok);
        testing.assertFalse(store.hasVersion($r.db, "@acme/ansi", "1.0.0"));
    }
    testing.assertTrue(dispatch(registered(), gitAdd("@acme/ansi", "1.0.0", "file:///srv/a")).ok);
}

func testAddRefusesAnInvalidEngineConstraint() {
    def argv as list of string init gitAdd("@acme/ansi", "1.0.0", "https://x/a");
    $argv[] = "--engines";
    $argv[] = "jennifer ^abc";
    def r as AdminResult init dispatch(registered(), $argv);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "engine jennifer");
}

func testAddRefusesASecondBuildOfOneVersion() {
    # 1.0.0+b is the same release as 1.0.0+a
    def first as list of string init gitAdd("@acme/ansi", "1.0.0+a", "https://x/a");
    def db as flatdb.DB init dispatch(registered(), $first).db;
    def r as AdminResult init dispatch($db, gitAdd("@acme/ansi", "1.0.0+b", "https://x/b"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "1.0.0+a");
    testing.assertFalse(store.hasVersion($r.db, "@acme/ansi", "1.0.0+b"));
    # the exact string still replaces, as an operator override
    testing.assertTrue(dispatch($db, gitAdd("@acme/ansi", "1.0.0+a", "https://x/c")).ok);
}

# delegated returns owned() with a trusted publisher and a CI token under @acme.
func delegated() {
    def db as flatdb.DB init trusted().db;
    return dispatch($db, ["deckadmin", "mint-token", "acme"]).db;
}

func testReassigningAScopeDropsTheOldOwnersDelegations() {
    # the old owner's pipelines must not keep publishing under the new owner
    def db as flatdb.DB init delegated();
    testing.assertEqual(len(store.listCiTokens($db)), 1);
    def r as AdminResult init dispatch(
        $db,
        ["deckadmin", "register-namespace", "acme", "--owner", "2000", "--login", "bob"]);
    testing.assertTrue($r.ok);
    testing.assertFalse(store.hasBinding($r.db, "@acme/ansi"));
    testing.assertEqual(len(store.listCiTokens($r.db)), 0);
    testing.assertContains($r.message, "dropped");
}

func testRegrantingToTheSameOwnerKeepsThem() {
    def r as AdminResult init dispatch(
        delegated(),
        ["deckadmin", "register-namespace", "acme", "--owner", "1000", "--login", "alice"]);
    testing.assertTrue(store.hasBinding($r.db, "@acme/ansi"));
    testing.assertEqual(len(store.listCiTokens($r.db)), 1);
}

func testRemovingADeckRemovesItsTrustedPublisher() {
    def db as flatdb.DB init trusted().db;
    $db = dispatch($db, gitAdd("@acme/ansi", "1.0.0", "https://x/a")).db;
    def r as AdminResult init dispatch($db, ["deckadmin", "remove", "@acme/ansi"]);
    testing.assertTrue($r.ok);
    testing.assertFalse(store.hasBinding($r.db, "@acme/ansi"));
}
