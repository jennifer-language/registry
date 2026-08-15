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
        name: "forgejo", baseUrl: "https://git.corp.test",
        clientId: "registry", clientSecret: "", scopes: ""
    };
}

func testEndpointsHangOffTheConfiguredBase() {
    testing.assertEqual(endpointFor(cfg(), "device"),
        "https://git.corp.test/login/oauth/device/code");
    testing.assertEqual(endpointFor(cfg(), "user"), "https://git.corp.test/api/v1/user");
}

func throwsWithoutABase() {
    def blank as identity.Config init identity.Config{
        name: "gitea", baseUrl: "", clientId: "x", clientSecret: "", scopes: ""
    };
    endpointFor($blank, "user");
}

func testAnUnsetBaseIsAnErrorNotAGuess() {
    # there is no hosted Gitea to fall back to, and guessing would point the
    # registry at a stranger's server
    testing.assertThrows("throwsWithoutABase", "identity");
}

func testSubjectCarriesTheProviderNameFromConfig() {
    # one module serves both Gitea and Forgejo, so the deployment names it
    def s as identity.Subject init subjectFrom(cfg(),
        json.decode('{"id":42,"login":"mplx"}'));
    testing.assertEqual($s.provider, "forgejo");
    testing.assertEqual($s.id, "42");
    testing.assertEqual($s.login, "mplx");
}

func testPollUsesTheSharedVocabulary() {
    testing.assertEqual(pollFrom(json.decode('{"error":"slow_down"}')).state,
        identity.STATE_SLOWDOWN);
}
