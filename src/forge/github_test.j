# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for the GitHub forge. Run with:
#
#     jennifer test src/forge/github_test.j
#
# The network calls are not covered: they need GitHub and a token. What is
# covered is every decision made about a response, which is why the parsing is
# separated from the request in the first place.

use testing;
use json;

func cfg() {
    return forge.Config{ name: "github", baseUrl: "", apiToken: "", host: "" };
}

func doc(text as string) {
    return json.decode($text);
}

func testHandlesTheHostedInstance() {
    testing.assertTrue(handlesUrl(cfg(), "https://github.com/acme/deck.git"));
    testing.assertFalse(handlesUrl(cfg(), "https://gitlab.com/acme/deck.git"));
}

func testAnEnterpriseInstanceClaimsItsOwnHost() {
    def ent as forge.Config init forge.Config{
        name: "github", baseUrl: "https://gh.corp.test/api/v3",
        apiToken: "", host: "gh.corp.test"
    };
    testing.assertTrue(handlesUrl($ent, "https://gh.corp.test/acme/deck.git"));
    testing.assertFalse(handlesUrl($ent, "https://github.com/acme/deck.git"));
}

func testPushGrantsAccess() {
    def p as forge.Permission init permissionFrom(doc('{"permissions":{"push":true}}'));
    testing.assertTrue($p.known);
    testing.assertTrue($p.push);
}

func testNoPushIsARefusalNotAnUnknown() {
    def p as forge.Permission init permissionFrom(doc('{"permissions":{"push":false}}'));
    testing.assertTrue($p.known);
    testing.assertFalse($p.push);
}

func testAMissingPermissionsBlockIsUnknown() {
    # the caller may simply be unauthenticated; that is not a refusal, and 7.1
    # requires it to be treated as unverified rather than as granted
    def p as forge.Permission init permissionFrom(doc('{"name":"deck"}'));
    testing.assertFalse($p.known);
    testing.assertFalse($p.push);
}

func testRepoCarriesTheIdsThatSurviveARename() {
    def r as forge.Repo init repoFrom(
        doc('{"id":1296269,"name":"deck","owner":{"id":6154722,"login":"acme"}}'));
    testing.assertEqual($r.id, "1296269");
    testing.assertEqual($r.ownerId, "6154722");
    testing.assertEqual($r.owner, "acme");
    testing.assertEqual($r.name, "deck");
}

func testRepoToleratesAPartialPayload() {
    def r as forge.Repo init repoFrom(doc('{"name":"deck"}'));
    testing.assertEqual($r.id, "");
    testing.assertEqual($r.ownerId, "");
    testing.assertEqual($r.name, "deck");
}

func testRefTargetIsRead() {
    testing.assertEqual(refTargetFrom(doc('{"object":{"sha":"abc123"}}')), "abc123");
    testing.assertEqual(refTargetFrom(doc('{}')), "");
}
