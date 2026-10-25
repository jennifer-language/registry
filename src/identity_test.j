# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for identity.j, the shared interface. Run with:
#
#     jennifer test src/identity_test.j

use testing;

func testSuccessIsOk() {
    testing.assertEqual(pollState(""), STATE_OK);
}

func testWaitingStatesAreDistinguished() {
    # slow_down also means widen the interval, answered with 429 instead of 202
    testing.assertEqual(pollState("authorization_pending"), STATE_PENDING);
    testing.assertEqual(pollState("slow_down"), STATE_SLOWDOWN);
}

func testTerminalStatesAreDistinguished() {
    testing.assertEqual(pollState("access_denied"), STATE_DENIED);
    testing.assertEqual(pollState("expired_token"), STATE_EXPIRED);
}

func testAnUnrecognisedErrorIsTerminal() {
    # treating it as pending would spin a client until its device code expired
    testing.assertEqual(pollState("incorrect_client_credentials"), STATE_DENIED);
    testing.assertEqual(pollState("something_added_later"), STATE_DENIED);
}

func testEndpointUsesTheFallbackWhenUnset() {
    testing.assertEqual(endpoint("", "https://github.com", "/login"), "https://github.com/login");
}

func testEndpointPrefersTheConfiguredBase() {
    testing.assertEqual(
        endpoint("https://git.example.test", "https://github.com", "/login"),
        "https://git.example.test/login");
}

func testEndpointToleratesATrailingSlash() {
    testing.assertEqual(
        endpoint("https://git.example.test/", "https://x", "/login"),
        "https://git.example.test/login");
}

func testOnlyA401MarksATokenAsRejected() {
    # 8.5: a refresh treats REJECTED as a revoked grant, anything else as an outage
    testing.assertEqual(rejectionKind(401), REJECTED);
    testing.assertEqual(rejectionKind(403), "identity");
    testing.assertEqual(rejectionKind(500), "identity");
}

func testASubjectIsOpaqueButBounded() {
    # 8.1: numeric ids and OIDC UUIDs alike; nothing empty, spaced or over 255
    for (def ok in ["1234567", "07", "4f1c2a9e-7b1d-4c55-9a7e-2f0d8c3b6a11", "auth0|abc"]) {
        testing.assertTrue(isSubject($ok));
    }
    def long as string init strings.repeat("a", 256);
    for (def bad in ["", "a b", "x\ty", "é", $long]) {
        testing.assertFalse(isSubject($bad));
    }
}
