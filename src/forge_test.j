# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for forge.j, the shared interface. Run with:
#
#     jennifer test src/forge_test.j

use testing;

func testHostOfHandlesTheOrdinaryCase() {
    testing.assertEqual(hostOf("https://github.com/acme/deck.git"), "github.com");
}

func testHostOfLowercases() {
    testing.assertEqual(hostOf("https://GitHub.COM/acme/deck.git"), "github.com");
}

func testHostOfStripsPortAndUserinfo() {
    testing.assertEqual(hostOf("https://git.example.test:8443/a/b.git"), "git.example.test");
    testing.assertEqual(hostOf("https://user@git.example.test/a/b.git"), "git.example.test");
}

func testHostOfRejectsWhatHasNoHost() {
    # a file:// URL or a bare path must fall through to "no forge handles this"
    testing.assertEqual(hostOf("/srv/decks/foo"), "");
    testing.assertEqual(hostOf("../relative/path"), "");
}

func testPathOfStripsGitSuffix() {
    testing.assertEqual(pathOf("https://github.com/acme/deck-routeros.git"), "acme/deck-routeros");
}

func testPathOfKeepsNestedGroups() {
    # GitLab nests groups arbitrarily deep, so the path is not just owner/repo
    testing.assertEqual(pathOf("https://gitlab.com/group/sub/project.git"), "group/sub/project");
}

func testPathOfToleratesATrailingSlash() {
    testing.assertEqual(pathOf("https://github.com/acme/deck/"), "acme/deck");
}

func testPathOfIsEmptyWithoutOne() {
    testing.assertEqual(pathOf("https://github.com"), "");
    testing.assertEqual(pathOf("not a url"), "");
}

func testUnknownIsNotARefusal() {
    # the distinction the whole permission model rests on: an unanswerable check
    # must never read as granted, and must be distinguishable from a denial
    def u as Permission init unknown("no credential");
    testing.assertFalse($u.known);
    testing.assertFalse($u.push);
    def r as Permission init refused("no access");
    testing.assertTrue($r.known);
    testing.assertFalse($r.push);
    def g as Permission init granted("has push");
    testing.assertTrue($g.known);
    testing.assertTrue($g.push);
}

# --- ref presence -------------------------------------------------------------

func testRefPresenceReadsTheTwoAnswersItTrusts() {
    testing.assertTrue(refPresence(200));
    testing.assertFalse(refPresence(404));
}

func throwOnAServerError() {
    refPresence(500);
}

func throwOnAnAuthFailure() {
    refPresence(403);
}

func testRefPresenceRefusesToGuess() {
    # the same rule as `unknown` above, in the place it matters most: this check
    # exists to find a ref shadowing a commit, so reading "the forge would not
    # answer" as "there is no such ref" would fail open on its own case
    testing.assertThrows("throwOnAServerError", "forge");
    testing.assertThrows("throwOnAnAuthFailure", "forge");
}

# --- repository URLs ----------------------------------------------------------

func testAPlainRepositoryUrlIsAccepted() {
    testing.assertEqual(repositoryProblem("https://github.com/acme/deck"), "");
    testing.assertEqual(repositoryProblem("https://github.com/acme/deck.git"), "");
    testing.assertEqual(repositoryProblem("https://gitlab.com/group/sub/my_deck-2/"), "");
}

func testARepositoryUrlMustNameARepository() {
    testing.assertContains(repositoryProblem(""), "missing");
    testing.assertContains(repositoryProblem("github.com/acme/deck"), "https");
    testing.assertContains(repositoryProblem("file:///srv/acme/deck"), "https");
    testing.assertContains(repositoryProblem("https://github.com/acme"), "owner");
}

func testWhatTheAdaptersIgnoreIsRefused() {
    # the adapters read only the path, so anything else in the URL would be
    # recorded and handed to clients without ever having been checked
    testing.assertContains(repositoryProblem("https://u:p@github.com/acme/deck"), "credentials");
    testing.assertContains(repositoryProblem("https://github.com/acme/deck?ref=x"), "query");
    testing.assertContains(repositoryProblem("https://github.com/acme/deck#main"), "fragment");
}

func testAPathCannotMeanSomethingElse() {
    testing.assertContains(repositoryProblem("https://github.com/acme/../evil/deck"), "segment");
    testing.assertContains(repositoryProblem("https://github.com/acme//deck"), "segment");
    testing.assertContains(
        repositoryProblem("https://github.com/acme%2F..%2Fevil/deck"),
        "segment");
    testing.assertContains(repositoryProblem("https://github.com/acme/de ck"), "segment");
}

# --- paths, listings, tags ----------------------------------------------------

func testSplitPathSplitsAtTheLastSlash() {
    testing.assertEqual(splitPath("src/deck.j"), ["src", "deck.j"]);
    testing.assertEqual(splitPath("a/b/c.j"), ["a/b", "c.j"]);
    testing.assertEqual(splitPath("deck.toml"), ["", "deck.toml"]);
}

func testFileNamesListsOnlyOrdinaryFiles() {
    # a directory or submodule named like the entry module is not the entry module
    def listing as json.Value init json.decode('[' +
        '{"name": "deck.j", "type": "file"}, {"name": "lib", "type": "dir"},' +
        '{"name": "other.j", "type": "submodule"}, {"name": "x.j", "type": "blob"}]');
    testing.assertEqual(fileNames($listing, "file"), ["deck.j"]);
    testing.assertEqual(fileNames($listing, "blob"), ["x.j"]);
}

func testAFilesMetadataIsNotADirectory() {
    # asked to list `src` when `src` is a file, a forge answers with one object
    def single as json.Value init json.decode('{"name": "src", "type": "file"}');
    testing.assertEqual(len(fileNames($single, "file")), 0);
}

func testOrdinaryTagsAreAccepted() {
    testing.assertEqual(tagProblem("v1.2.3"), "");
    testing.assertEqual(tagProblem("1.0.0-rc.1+build.5"), "");
    testing.assertEqual(tagProblem("release/v2"), "");
}

func testATagCannotChangeThePathItIsPlacedIn() {
    testing.assertContains(tagProblem(""), "missing");
    testing.assertContains(tagProblem("v1/../../../evil/x"), "valid");
    testing.assertContains(tagProblem("v1?x=1"), "character");
    testing.assertContains(tagProblem("v1#frag"), "character");
    testing.assertContains(tagProblem("v1%2Fx"), "character");
    testing.assertContains(tagProblem("v1 x"), "character");
    testing.assertContains(tagProblem("/v1"), "valid");
    testing.assertContains(tagProblem("v1.lock"), "valid");
}

# --- service-account permissions ----------------------------------------------

func testRolesThatMayPushAreGranted() {
    for (def role in ["owner", "admin", "maintain", "write", "Write"]) {
        def p as Permission init permissionFromRole($role);
        testing.assertTrue($p.known);
        testing.assertTrue($p.push);
    }
}

func testRolesThatMayNotPushAreRefused() {
    for (def role in ["read", "triage", "none"]) {
        def p as Permission init permissionFromRole($role);
        testing.assertTrue($p.known);
        testing.assertFalse($p.push);
    }
}

func testAnUnexpectedRoleIsUnknownNotGranted() {
    # a role a forge adds later must be refused until somebody decides about it
    def p as Permission init permissionFromRole("superuser");
    testing.assertFalse($p.known);
    testing.assertFalse($p.push);
    testing.assertFalse(permissionFromRole("").known);
}

func testOnlyPlainNamesArePathSegments() {
    testing.assertTrue(isPathSegment("alice"));
    testing.assertTrue(isPathSegment("alice.smith-2_x"));
    testing.assertFalse(isPathSegment("../admin"));
    testing.assertFalse(isPathSegment("a/b"));
    testing.assertFalse(isPathSegment("a%2Fb"));
    testing.assertFalse(isPathSegment(""));
}

func testACollaboratorPayloadIsReadByRole() {
    def body as string init '{"permission":"write","role_name":"write","user":{"login":"alice"}}';
    def w as Permission init collaboratorPermissionFrom(json.decode($body));
    testing.assertTrue($w.push);
    def r as Permission init collaboratorPermissionFrom(json.decode('{"permission": "read"}'));
    testing.assertTrue($r.known);
    testing.assertFalse($r.push);
    testing.assertFalse(collaboratorPermissionFrom(json.decode('{}')).known);
}

func serviceCfg(token as string) {
    return Config{name: "gitea", baseUrl: "https://git.example.com", apiToken: $token, host: ""};
}

func testTheServiceAccountMustHoldATokenAndAskAboutAName() {
    testing.assertContains(askProblem(serviceCfg(""), "alice"), "no forge token");
    testing.assertContains(askProblem(serviceCfg("svc"), "../admin"), "not a forge username");
    testing.assertEqual(askProblem(serviceCfg("svc"), "alice"), "");
}

func testTheRecordedUrlUsesTheForgesSchemeAndPort() {
    # the reads go to the configured API whatever the URL says, so the URL
    # clients will clone from must not point anywhere else
    testing.assertEqual(originProblem("https://github.com/o/r", ""), "");
    testing.assertContains(originProblem("http://github.com/o/r", ""), "https://");
    testing.assertContains(originProblem("https://github.com:8080/o/r", ""), "port");
    testing.assertEqual(originProblem("http://git.lan:3000/o/r", "http://git.lan:3000"), "");
    testing.assertContains(originProblem("http://git.lan/o/r", "http://git.lan:3000"), "port");
}
