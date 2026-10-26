# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for the GitLab forge. Run with:
#
#     jennifer test src/forge/gitlab_test.j
#
# The tests focus on encoded project ids and numeric access levels.

use testing;
use json;

func cfg() {
    return forge.Config{name: "gitlab", baseUrl: "", apiToken: "", host: ""};
}

func doc(text as string) {
    return json.decode($text);
}

func testHandlesTheHostedInstance() {
    testing.assertTrue(handlesUrl(cfg(), "https://gitlab.com/group/project.git"));
    testing.assertFalse(handlesUrl(cfg(), "https://github.com/acme/deck.git"));
}

func testProjectIdEncodesNestedGroups() {
    # GitLab addresses a project by its URL-encoded path
    testing.assertEqual(
        projectId("https://gitlab.com/group/sub/project.git"),
        "group%2Fsub%2Fproject");
}

func testProjectIdHandlesTheFlatCase() {
    testing.assertEqual(projectId("https://gitlab.com/acme/deck.git"), "acme%2Fdeck");
}

func testDeveloperMayPush() {
    def body as string init '{"permissions":{"project_access":{"access_level":30}}}';
    def p as forge.Permission init permissionFrom(doc($body));
    testing.assertTrue($p.known);
    testing.assertTrue($p.push);
}

func testReporterMayNot() {
    # 20 is reporter, below the developer threshold
    def body as string init '{"permissions":{"project_access":{"access_level":20}}}';
    def p as forge.Permission init permissionFrom(doc($body));
    testing.assertTrue($p.known);
    testing.assertFalse($p.push);
    testing.assertContains($p.reason, "below developer");
}

func testInheritedGroupAccessCounts() {
    # group membership alone may grant push
    def body as string init '{"permissions":{"project_access":null,' +
        '"group_access":{"access_level":40}}}';
    def p as forge.Permission init permissionFrom(doc($body));
    testing.assertTrue($p.push);
}

func testTheHigherOfTheTwoDecides() {
    def body as string init '{"permissions":{"project_access":{"access_level":10},' +
        '"group_access":{"access_level":30}}}';
    def p as forge.Permission init permissionFrom(doc($body));
    testing.assertTrue($p.push);
}

func testNoMembershipIsARefusal() {
    def p as forge.Permission init permissionFrom(doc('{"permissions":{}}'));
    testing.assertTrue($p.known);
    testing.assertFalse($p.push);
}

func testAMissingPermissionsBlockIsUnknown() {
    def p as forge.Permission init permissionFrom(doc('{"id":7}'));
    testing.assertFalse($p.known);
}

func testRepoUsesTheNamespaceAsOwner() {
    def body as string init '{"id":42,"path":"project",' +
        '"namespace":{"id":9,"full_path":"group/sub"}}';
    def r as forge.Repo init repoFrom(doc($body));
    testing.assertEqual($r.id, "42");
    testing.assertEqual($r.ownerId, "9");
    testing.assertEqual($r.owner, "group/sub");
    testing.assertEqual($r.name, "project");
}

func testTagCommitPrefersTheCommitId() {
    testing.assertEqual(tagCommitFrom(doc('{"commit":{"id":"abc"},"target":"xyz"}')), "abc");
    testing.assertEqual(tagCommitFrom(doc('{"target":"xyz"}')), "xyz");
}

# --- the service-account route (12.5) -----------------------------------------

func testAUserIsFoundByExactUsername() {
    def users as json.Value init doc('[{"id": 7, "username": "alice2"},' +
        '{"id": 9, "username": "Alice"}]');
    testing.assertEqual(userIdFrom($users, "alice"), "9");
    testing.assertEqual(userIdFrom($users, "ali"), "");
    testing.assertEqual(userIdFrom(doc('{"message": "403 Forbidden"}'), "alice"), "");
}

func testDeveloperAccessMayPush() {
    def body as string init '{"id": 9, "access_level": 30, "state": "active"}';
    def p as forge.Permission init memberPermissionFrom(doc($body));
    testing.assertTrue($p.push);
}

func testReporterAccessMayNot() {
    def body as string init '{"id": 9, "access_level": 20, "state": "active"}';
    def p as forge.Permission init memberPermissionFrom(doc($body));
    testing.assertTrue($p.known);
    testing.assertFalse($p.push);
}

func testABlockedMembershipGrantsNothing() {
    def body as string init '{"id": 9, "access_level": 50, "state": "blocked"}';
    def p as forge.Permission init memberPermissionFrom(doc($body));
    testing.assertFalse($p.push);
}

func testAMembershipWithoutALevelIsUnknown() {
    testing.assertFalse(memberPermissionFrom(doc('{"id": 9}')).known);
}

func testAFileIsAskedAboutAsOneSegment() {
    # one escaped path segment, and the commit as the ref so a moved branch cannot
    # change the answer
    testing.assertEqual(
        filePath("https://gitlab.com/acme/tool", "c0ffee", "src/tool.j"),
        "/projects/acme%2Ftool/repository/files/src%2Ftool.j?ref=c0ffee");
}

func testPermissionNeverAsksWithTheRegistrysOwnToken() {
    # an empty caller token must not fall back to the service token, which would
    # report the registry's push access as the caller's; answered before any request
    def c as forge.Config init cfg();
    $c.apiToken = "service-token";
    def p as forge.Permission init permission($c, "https://github.com/acme/deck", "");
    testing.assertFalse($p.known);
    testing.assertFalse($p.push);
    testing.assertContains($p.reason, "caller credential");
}
