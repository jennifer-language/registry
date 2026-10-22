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
