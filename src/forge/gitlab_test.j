# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for the GitLab forge. Run with:
#
#     jennifer test src/forge/gitlab_test.j
#
# GitLab is the forge that differs most from the GitHub shape, so the parts that
# differ - encoded project ids and numeric access levels - are where the tests
# concentrate.

use testing;
use json;

func cfg() {
    return forge.Config{ name: "gitlab", baseUrl: "", apiToken: "", host: "" };
}

func doc(text as string) {
    return json.decode($text);
}

func testHandlesTheHostedInstance() {
    testing.assertTrue(handlesUrl(cfg(), "https://gitlab.com/group/project.git"));
    testing.assertFalse(handlesUrl(cfg(), "https://github.com/acme/deck.git"));
}

func testProjectIdEncodesNestedGroups() {
    # GitLab addresses a project by its URL-encoded path, not by segments
    testing.assertEqual(projectId("https://gitlab.com/group/sub/project.git"),
        "group%2Fsub%2Fproject");
}

func testProjectIdHandlesTheFlatCase() {
    testing.assertEqual(projectId("https://gitlab.com/acme/deck.git"), "acme%2Fdeck");
}

func testDeveloperMayPush() {
    def p as forge.Permission init permissionFrom(
        doc('{"permissions":{"project_access":{"access_level":30}}}'));
    testing.assertTrue($p.known);
    testing.assertTrue($p.push);
}

func testReporterMayNot() {
    # 20 is reporter, below the developer threshold
    def p as forge.Permission init permissionFrom(
        doc('{"permissions":{"project_access":{"access_level":20}}}'));
    testing.assertTrue($p.known);
    testing.assertFalse($p.push);
    testing.assertContains($p.reason, "below developer");
}

func testInheritedGroupAccessCounts() {
    # a member may hold no direct project membership and still be able to push
    def p as forge.Permission init permissionFrom(
        doc('{"permissions":{"project_access":null,"group_access":{"access_level":40}}}'));
    testing.assertTrue($p.push);
}

func testTheHigherOfTheTwoDecides() {
    def p as forge.Permission init permissionFrom(doc(
        '{"permissions":{"project_access":{"access_level":10},' +
        '"group_access":{"access_level":30}}}'));
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
    def r as forge.Repo init repoFrom(doc(
        '{"id":42,"path":"project","namespace":{"id":9,"full_path":"group/sub"}}'));
    testing.assertEqual($r.id, "42");
    testing.assertEqual($r.ownerId, "9");
    testing.assertEqual($r.owner, "group/sub");
    testing.assertEqual($r.name, "project");
}

func testTagCommitPrefersTheCommitId() {
    testing.assertEqual(tagCommitFrom(doc('{"commit":{"id":"abc"},"target":"xyz"}')), "abc");
    testing.assertEqual(tagCommitFrom(doc('{"target":"xyz"}')), "xyz");
}
