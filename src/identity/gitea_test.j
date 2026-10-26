# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for the Gitea / Forgejo identity provider. Run with:
#
#     jennifer test src/identity/gitea_test.j

use testing;
use json;

func cfg() {
    return identity.Config{
        name: "forgejo",
        baseUrl: "https://git.corp.test",
        clientId: "registry",
        clientSecret: "",
        scopes: "",
        metadata: ""
    };
}

func testEndpointsHangOffTheConfiguredBase() {
    testing.assertEqual(
        endpointFor(cfg(), "device"),
        "https://git.corp.test/login/oauth/device/code");
    testing.assertEqual(endpointFor(cfg(), "user"), "https://git.corp.test/api/v1/user");
}

func throwsWithoutABase() {
    def blank as identity.Config init identity.Config{
        name: "gitea",
        baseUrl: "",
        clientId: "x",
        clientSecret: "",
        scopes: "",
        metadata: ""
    };
    endpointFor($blank, "user");
}

func testAnUnsetBaseIsAnErrorNotAGuess() {
    # a guessed base would point the registry at a stranger's server
    testing.assertThrows("throwsWithoutABase", "identity");
}

func testSubjectCarriesTheProviderNameFromConfig() {
    # one module serves both Gitea and Forgejo, so the deployment names it
    def s as identity.Subject init subjectFrom(cfg(), json.decode('{"id":42,"login":"mplx"}'));
    testing.assertEqual($s.provider, "forgejo");
    testing.assertEqual($s.id, "42");
    testing.assertEqual($s.login, "mplx");
}

func testPollUsesTheSharedVocabulary() {
    testing.assertEqual(
        pollFrom(json.decode('{"error":"slow_down"}')).state,
        identity.STATE_SLOWDOWN);
}

func testTheProviderCanBeBuilt() {
    # every name in the vtable must exist, or the server fails to boot
    def p as identity.Provider init provider();
    testing.assertEqual(len($p.memberships(cfg(), "any-token")), 0);
}

func testTheClientSecretIsSentOnlyWhenConfigured() {
    # RFC 6749 2.3.1: a confidential client authenticates at the token endpoint
    def public as identity.Config init cfg();
    testing.assertEqual(clientFields($public), "client_id=" + $public.clientId);
    def confidential as identity.Config init $public;
    $confidential.clientSecret = "s3cret&x";
    testing.assertEqual(
        clientFields($confidential),
        "client_id=" + $public.clientId + "&client_secret=s3cret%26x");
}

func testFixedEndpointsNeedNoDiscovery() {
    testing.assertEqual(provider().discover(cfg()), "");
}
