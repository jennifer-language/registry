# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for the GitLab identity provider. Run with:
#
#     jennifer test src/identity/gitlab_test.j

use testing;
use json;

func hosted() {
    return identity.Config{
        name: "gitlab", baseUrl: "", clientId: "app", clientSecret: "", scopes: ""
    };
}

func selfHosted() {
    return identity.Config{
        name: "gitlab", baseUrl: "https://gl.corp.test/",
        clientId: "app", clientSecret: "", scopes: ""
    };
}

func testHostedFallsBackToGitlabCom() {
    testing.assertEqual(endpointFor(hosted(), "user"), "https://gitlab.com/api/v4/user");
}

func testSelfHostedDiffersOnlyInTheBase() {
    # the reason there is one module rather than two
    testing.assertEqual(endpointFor(selfHosted(), "user"),
        "https://gl.corp.test/api/v4/user");
    testing.assertEqual(endpointFor(selfHosted(), "token"),
        "https://gl.corp.test/oauth/token");
}

func testSubjectReadsGitlabsUsernameField() {
    # GitLab calls it `username`, where the GitHub-shaped forges say `login`
    def s as identity.Subject init subjectFrom(hosted(),
        json.decode('{"id":7,"username":"mplx"}'));
    testing.assertEqual($s.id, "7");
    testing.assertEqual($s.login, "mplx");
}

func testScopeDefaultUsesGitlabsSpelling() {
    # read_user, with an underscore, not read:user
    testing.assertEqual(scopesFor(hosted()), "read_user");
}
