# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for audit.j. Run with:
#
#     jennifer test src/audit_test.j
#
# The builders are pure, so these tests assert the record: field names, levels,
# and that no builder accepts a secret.

use testing;
use maps;
use fs;

func testLevelsFallBackToInfo() {
    testing.assertEqual(levelOf(""), INFO);
    testing.assertEqual(levelOf("chatty"), INFO);
    # a typo must not silently disable logging
    testing.assertEqual(levelOf("DEBUG"), DEBUG);
    testing.assertEqual(levelOf("  warn  "), WARN);
}

func testFormatsFallBackToText() {
    testing.assertEqual(formatOf(""), "text");
    testing.assertEqual(formatOf("yaml"), "text");
    testing.assertEqual(formatOf("JSON"), "json");
    testing.assertEqual(formatOf("logfmt"), "logfmt");
}

# --- the record ---------------------------------------------------------------

func testAPublishRecordsThePin() {
    # the pin is the integrity boundary
    def ev as Event init deckPublished(
        "@acme/tool",
        "1.2.0",
        "git",
        "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293",
        false);
    testing.assertEqual($ev.level, INFO);
    testing.assertEqual($ev.fields["deck"], "@acme/tool");
    testing.assertEqual($ev.fields["version"], "1.2.0");
    testing.assertEqual($ev.fields["kind"], "git");
    testing.assertEqual($ev.fields["pin"], "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293");
}

func testReplacingAVersionIsLouderThanPublishingOne() {
    # replacing a version changes what an existing lockfile resolves to
    def ev as Event init deckPublished("@acme/tool", "1.2.0", "tar.gz", "sha256:ab", true);
    testing.assertEqual($ev.level, WARN);
    testing.assertContains($ev.message, "replaced");
}

func testRemovalDistinguishesAVersionFromADeck() {
    def one as Event init deckRemoved("@acme/tool", "1.2.0");
    testing.assertEqual($one.fields["version"], "1.2.0");
    def all as Event init deckRemoved("@acme/tool", "");
    testing.assertEqual($all.message, "deck removed");
    testing.assertFalse(maps.has($all.fields, "version"));
}

func testAReservationIsNotAGrant() {
    def held as Event init scopeRegistered("jennifer", "", "", "", false);
    testing.assertEqual($held.message, "scope reserved");
    # nobody owns it, so there is no subject to record
    testing.assertFalse(maps.has($held.fields, "subject"));

    def granted as Event init scopeRegistered("acme", "github", "1234567", "alice", false);
    testing.assertEqual($granted.message, "scope granted");
    testing.assertEqual($granted.fields["subject"], "1234567");
    testing.assertEqual($granted.fields["login"], "alice");
}

func testAReassignmentIsFindable() {
    # the only way a scope changes hands
    def ev as Event init scopeRegistered("acme", "github", "9999999", "bob", true);
    testing.assertEqual($ev.level, WARN);
    testing.assertContains($ev.message, "reassigned");
}

func testTheSubjectIsRecordedNotJustTheLogin() {
    # ownership binds to the id, which survives a rename
    def ev as Event init scopeRegistered("acme", "github", "1234567", "alice", false);
    testing.assertEqual($ev.fields["subject"], "1234567");
}

func testAPollingClientDoesNotFillTheLogWithWarnings() {
    # 202 (user not finished yet) is expected once per poll interval
    def waiting as Event init loginRefused("token", 202, "authorization_pending");
    testing.assertEqual($waiting.level, DEBUG);
    def refused as Event init loginRefused("token", 400, "expired_token");
    testing.assertEqual($refused.level, WARN);
}

func testTheBootRecordSaysWhetherAuthIsServed() {
    def off as Event init serverStarted(":8080", "data/decks.json", "github", false);
    testing.assertEqual($off.fields["auth"], "off");
    testing.assertFalse(maps.has($off.fields, "identity"));
    def on as Event init serverStarted(":8080", "data/decks.json", "gitea", true);
    testing.assertEqual($on.fields["auth"], "on");
    testing.assertEqual($on.fields["identity"], "gitea");
}

# --- what must never appear ---------------------------------------------------

func testNoBuilderCanBeHandedASecret() {
    # A design assertion: builders near a credential take only the account and
    # labels. An added parameter would not fail this test; review catches it.
    def issued as Event init tokenIssued("issued", "1234567", "alice", "acme,viverto");
    testing.assertEqual(len($issued.fields), 3);
    testing.assertEqual($issued.fields["subject"], "1234567");
    testing.assertEqual($issued.fields["login"], "alice");
    # The organisation list is public information.
    testing.assertEqual($issued.fields["orgs"], "acme,viverto");

    def started as Event init loginStarted("github");
    testing.assertEqual(len($started.fields), 1);
}

func testARefusalRecordsTheReasonNotTheCredential() {
    def ev as Event init loginRefused("refresh", 401, "no such refresh token");
    testing.assertEqual($ev.fields["reason"], "no such refresh token");
    testing.assertFalse(maps.has($ev.fields, "token"));
}

# --- sinks --------------------------------------------------------------------

func testTheNullEventIsDropped() {
    testing.assertFalse(write(silent(), none()));
}

func testASilentSinkWritesNothing() {
    testing.assertFalse(write(silent(), tokensRevoked("1234567", 3)));
    testing.assertEqual(describe(silent()), "nowhere");
}

func testAnUnwritablePathIsReportedNotThrown() {
    # a registry that cannot write its log still serves decks
    def sink as Sink init open("info", "text", "/no/such/dir/registry.log", false);
    testing.assertFalse($sink.hasFile);
    testing.assertFalse($sink.fileError == "");
    testing.assertEqual(describe($sink), "nowhere");
}

func testAWritableFileIsOpenedAndAppended() {
    def dir as string init fs.makeTempDir("", "jvc-audit");
    def path as string init $dir + "/registry.log";
    def sink as Sink init open("info", "logfmt", $path, false);
    testing.assertTrue($sink.hasFile);
    testing.assertEqual($sink.fileError, "");
    testing.assertEqual(describe($sink), $path);

    testing.assertTrue(write($sink, deckPublished("@acme/tool", "1.2.0", "git", "abc", false)));
    def written as string init fs.readString($path);
    testing.assertContains($written, "deck version published");
    testing.assertContains($written, "@acme/tool");

    # a debug record is below the configured level and must not appear
    write($sink, requestSeen("GET", "/health", "127.0.0.1"));
    testing.assertFalse(strings.contains(fs.readString($path), "/health"));

    fs.removeAll($dir);
}

func testDebugLevelLetsRequestsThrough() {
    def dir as string init fs.makeTempDir("", "jvc-audit");
    def path as string init $dir + "/registry.log";
    def sink as Sink init open("debug", "logfmt", $path, false);
    write($sink, requestSeen("GET", "/deck", "127.0.0.1"));
    testing.assertContains(fs.readString($path), "/deck");
    fs.removeAll($dir);
}

# --- attribution --------------------------------------------------------------

func testAFailureIsNamedByTheEntryPoint() {
    # the command knows what went wrong, the entry point knows what was typed
    def ev as Event init attribute(commandFailed("", "no such deck"), "remove");
    testing.assertEqual($ev.fields["command"], "remove");
}

func testAttributionDoesNotOverwriteAName() {
    def ev as Event init attribute(commandFailed("add", "bad pin"), "remove");
    testing.assertEqual($ev.fields["command"], "add");
}

func testAttributingAnEventWithNoCommandFieldIsANoOp() {
    def ev as Event init attribute(deckRemoved("@acme/tool", "1.0.0"), "remove");
    testing.assertFalse(maps.has($ev.fields, "command"));
    testing.assertEqual(attribute(none(), "add").level, "");
}

# --- which address gets recorded ----------------------------------------------

func testThePeerIsUsedWhenNoHeaderIsConfigured() {
    # the default: unforgeable, and correct with no proxy in front
    testing.assertEqual(clientOf("", "10.0.1.12:44496"), "10.0.1.12:44496");
    testing.assertEqual(clientOf("   ", "10.0.1.12:44496"), "10.0.1.12:44496");
}

func testAConfiguredHeaderWins() {
    testing.assertEqual(clientOf("203.0.113.7", "10.0.1.12:44496"), "203.0.113.7");
}

func testTheLastEntryOfAChainIsRecorded() {
    # an appending proxy leaves the client's claim in front; only the last
    # entry is the proxy's
    testing.assertEqual(clientOf("6.6.6.6, 203.0.113.7", "10.0.1.12:44496"), "203.0.113.7");
    testing.assertEqual(clientOf(" 172.68.1.1 ,203.0.113.7 , ", "10.0.1.12:0"), "203.0.113.7");
}

func testAnEmptyChainFallsBackToThePeer() {
    # a proxy that set the header but put nothing in it must not blank the record
    testing.assertEqual(clientOf(",", "10.0.1.12:44496"), "10.0.1.12:44496");
    testing.assertEqual(clientOf(" , , ", "10.0.1.12:44496"), "10.0.1.12:44496");
}

func testControlCharactersNeverReachTheLog() {
    # a request path is attacker input; a raw ESC in it is a terminal command
    testing.assertEqual(printable("/a\u001b[31mred"), "/a\\x1b[31mred");
    testing.assertEqual(printable("line\nforged"), "line\\x0aforged");
    testing.assertEqual(printable("abc‮gpj.exe"), "abc\\xe2\\x80\\xaegpj.exe");
    testing.assertEqual(printable("plain /path ok"), "plain /path ok");
    def ev as Event init cleaned(requestSeen("GET", "/x\u001b]0;pwned\u0007", "1.2.3.4"));
    testing.assertFalse(strings.contains($ev.fields["path"], "\u001b"));
}

func testC1ControlsAndLineSeparatorsAreEscapedToo() {
    # C1 controls (U+0080..U+009F) are terminal commands on some emulators, and
    # U+2028 / U+2029 break a line without being a newline
    testing.assertEqual(printable("a\u0085b"), "a\\xc2\\x85b");
    testing.assertEqual(printable("a\u009bb"), "a\\xc2\\x9bb");
    testing.assertEqual(printable("a b"), "a\\xe2\\x80\\xa8b");
    testing.assertEqual(printable("a b"), "a\\xe2\\x80\\xa9b");
    testing.assertEqual(printable("a bé"), "a bé");
}
