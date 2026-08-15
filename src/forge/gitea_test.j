# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for the Gitea / Forgejo forge. Run with:
#
#     jennifer test src/forge/gitea_test.j

use testing;
use json;

func cfg() {
    return forge.Config{
        name: "gitea", baseUrl: "https://git.corp.test",
        apiToken: "", host: "git.corp.test"
    };
}

func doc(text as string) {
    return json.decode($text);
}

func testHandlesOnlyItsConfiguredHost() {
    testing.assertTrue(handlesUrl(cfg(), "https://git.corp.test/acme/deck.git"));
    testing.assertFalse(handlesUrl(cfg(), "https://github.com/acme/deck.git"));
}

func testAnInstanceWithNoHostClaimsNothing() {
    # guessing would let a self-hosted forge answer for a stranger's server
    def blank as forge.Config init forge.Config{
        name: "gitea", baseUrl: "https://git.corp.test", apiToken: "", host: ""
    };
    testing.assertFalse(handlesUrl($blank, "https://git.corp.test/acme/deck.git"));
}

func testPermissionMirrorsGithubsShape() {
    testing.assertTrue(permissionFrom(doc('{"permissions":{"push":true}}')).push);
    def no as forge.Permission init permissionFrom(doc('{"permissions":{"push":false}}'));
    testing.assertTrue($no.known);
    testing.assertFalse($no.push);
    testing.assertFalse(permissionFrom(doc('{}')).known);
}

func testTagIsAlreadyDereferenced() {
    # Gitea returns the commit nested in the tag, so an annotated tag needs no
    # second call the way GitHub's does
    testing.assertEqual(tagCommitFrom(doc('{"commit":{"sha":"deadbeef"}}')), "deadbeef");
}

func testTagFallsBackToId() {
    testing.assertEqual(tagCommitFrom(doc('{"id":"cafe"}')), "cafe");
    testing.assertEqual(tagCommitFrom(doc('{}')), "");
}

func testRepoCarriesTheIds() {
    def r as forge.Repo init repoFrom(
        doc('{"id":7,"name":"deck","owner":{"id":3,"login":"acme"}}'));
    testing.assertEqual($r.id, "7");
    testing.assertEqual($r.ownerId, "3");
}
