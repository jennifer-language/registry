# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for the GitHub identity provider. Run with:
#
#     jennifer test src/identity/github_test.j

use testing;
use json;

func cfg() {
    return identity.Config{
        name: "github", baseUrl: "", clientId: "Iv1.abc", clientSecret: "", scopes: ""
    };
}

func doc(text as string) {
    return json.decode($text);
}

func testSubjectBindsToTheNumericId() {
    def s as identity.Subject init subjectFrom(doc('{"id":1234567,"login":"mplx"}'));
    testing.assertEqual($s.provider, "github");
    testing.assertEqual($s.id, "1234567");
    testing.assertEqual($s.login, "mplx");
}

func throwsWithoutAnId() {
    subjectFrom(json.decode('{"login":"mplx"}'));
}

func testAnAccountWithNoIdIsRejected() {
    # the id is what ownership binds to, so a payload without one is unusable
    testing.assertThrows("throwsWithoutAnId", "identity");
}

func testDeviceCarriesTheCodesAndDefaults() {
    def d as identity.Device init deviceFrom(doc(
        '{"device_code":"dc","user_code":"WXYZ-1234",' +
        '"verification_uri":"https://github.com/login/device"}'));
    testing.assertEqual($d.userCode, "WXYZ-1234");
    # RFC 8628 defaults when the provider omits them
    testing.assertEqual($d.expiresIn, 900);
    testing.assertEqual($d.interval, 5);
}

func throwsOnRefusedDevice() {
    deviceFrom(json.decode('{"error":"unauthorized_client"}'));
}

func testARefusedAuthorizationThrows() {
    testing.assertThrows("throwsOnRefusedDevice", "identity");
}

func testPollMapsThroughTheSharedVocabulary() {
    testing.assertEqual(pollFrom(doc('{"error":"authorization_pending"}')).state,
        identity.STATE_PENDING);
    testing.assertEqual(pollFrom(doc('{"error":"slow_down"}')).state,
        identity.STATE_SLOWDOWN);
    def ok as identity.Poll init pollFrom(doc('{"access_token":"gho_x"}'));
    testing.assertEqual($ok.state, identity.STATE_OK);
    testing.assertEqual($ok.accessToken, "gho_x");
}

func testAFailedPollCarriesNoToken() {
    testing.assertEqual(pollFrom(doc('{"error":"access_denied"}')).accessToken, "");
}

func testHostedEndpoints() {
    testing.assertEqual(endpointFor(cfg(), "device"),
        "https://github.com/login/device/code");
    testing.assertEqual(endpointFor(cfg(), "user"), "https://api.github.com/user");
}

func testEnterpriseOverridesTheBase() {
    def ent as identity.Config init identity.Config{
        name: "github", baseUrl: "https://gh.corp.test",
        clientId: "x", clientSecret: "", scopes: ""
    };
    testing.assertEqual(endpointFor($ent, "device"),
        "https://gh.corp.test/login/device/code");
}

func testScopesDefaultButAreOverridable() {
    testing.assertContains(scopesFor(cfg()), "read:user");
    def custom as identity.Config init identity.Config{
        name: "github", baseUrl: "", clientId: "x", clientSecret: "", scopes: "read:user"
    };
    testing.assertEqual(scopesFor($custom), "read:user");
}

# --- organisation memberships (8.7) -------------------------------------------

func membershipDoc(state as string, role as string, orgId as int) {
    def one as json.Value init json.map();
    $one = json.set($one, "/state", $state);
    $one = json.set($one, "/role", $role);
    def org as json.Value init json.map();
    $org = json.set($org, "/id", $orgId);
    $one = json.set($one, "/organization", $org);
    return json.append(json.list(), "", $one);
}

func testAnActiveMemberCounts() {
    def out as list of string init membershipsFrom(membershipDoc("active", "member", 42));
    testing.assertEqual(len($out), 1);
    testing.assertEqual($out[0], "42");
}

func testAnAdminCounts() {
    testing.assertEqual(len(membershipsFrom(membershipDoc("active", "admin", 42))), 1);
}

func testAPendingInvitationIsNotMembership() {
    # non-negotiable per 8.7: an invitation nobody accepted would otherwise let
    # anyone who can get themselves invited publish under an organisation's name
    testing.assertEqual(len(membershipsFrom(membershipDoc("pending", "admin", 42))), 0);
}

func testABillingManagerIsNotAuthority() {
    # non-negotiable per 8.7: a finance role with no relationship to code
    testing.assertEqual(len(membershipsFrom(membershipDoc("active", "billing_manager", 42))), 0);
}

func testTheOrgIdIsReadAsText() {
    # it is compared against a stored subject id, which is text; comparing 42 to
    # "42" would silently never match
    testing.assertEqual(membershipsFrom(membershipDoc("active", "member", 42))[0], "42");
}

func testAMalformedPayloadYieldsNothing() {
    # fail closed: an unreadable answer must not authorise anything
    testing.assertEqual(len(membershipsFrom(json.map())), 0);
    testing.assertEqual(len(membershipsFrom(json.list())), 0);
    def noOrg as json.Value init json.append(json.list(), "",
        json.set(json.map(), "/state", "active"));
    testing.assertEqual(len(membershipsFrom($noOrg)), 0);
}

func testTheMembershipsEndpointAsksForActiveOnly() {
    def url as string init endpointFor(cfg(), "memberships");
    testing.assertContains($url, "/user/memberships/orgs");
    testing.assertContains($url, "state=active");
}
