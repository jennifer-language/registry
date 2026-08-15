# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for the generic OIDC identity provider. Run with:
#
#     jennifer test src/identity/oidc_test.j
#
# This is the provider that covers Authelia and anything else standards
# compliant, so the tests concentrate on reading a discovery document, which is
# what makes one module serve providers of differing capability.

use testing;
use json;

func cfg() {
    return identity.Config{
        name: "authelia", baseUrl: "https://auth.corp.test",
        clientId: "registry", clientSecret: "", scopes: ""
    };
}

func doc(text as string) {
    return json.decode($text);
}

func withDevice() {
    return doc('{"issuer":"https://auth.corp.test",' +
        '"token_endpoint":"https://auth.corp.test/api/oidc/token",' +
        '"userinfo_endpoint":"https://auth.corp.test/api/oidc/userinfo",' +
        '"device_authorization_endpoint":"https://auth.corp.test/api/oidc/device"}');
}

func withoutDevice() {
    return doc('{"issuer":"https://auth.corp.test",' +
        '"authorization_endpoint":"https://auth.corp.test/api/oidc/authorize",' +
        '"token_endpoint":"https://auth.corp.test/api/oidc/token"}');
}

func testDiscoveryUrlIsTheStandardPath() {
    testing.assertEqual(discoveryUrl(cfg()),
        "https://auth.corp.test/.well-known/openid-configuration");
}

func testEndpointsComeFromTheDocument() {
    testing.assertEqual(endpointFrom(withDevice(), "token_endpoint"),
        "https://auth.corp.test/api/oidc/token");
    testing.assertEqual(endpointFrom(withDevice(), "not_advertised"), "");
}

func testFlowIsTakenFromTheProviderNotAssumed() {
    # the whole reason one module can serve providers of differing capability
    testing.assertEqual(flowFrom(withDevice()), "device");
    testing.assertEqual(flowFrom(withoutDevice()), "authcode");
}

func testSubjectBindsToTheSubClaim() {
    def s as identity.Subject init subjectFrom(cfg(),
        doc('{"sub":"a1b2c3","preferred_username":"mplx"}'));
    testing.assertEqual($s.provider, "authelia");
    # a sub is an opaque string, not a number
    testing.assertEqual($s.id, "a1b2c3");
    testing.assertEqual($s.login, "mplx");
}

func testAMissingUsernameIsAllowed() {
    # OIDC requires `sub`, not a username; a provider may supply none
    def s as identity.Subject init subjectFrom(cfg(), doc('{"sub":"a1b2c3"}'));
    testing.assertEqual($s.login, "");
}

func throwsWithoutSub() {
    subjectFrom(cfg(), json.decode('{"preferred_username":"mplx"}'));
}

func testAPayloadWithoutSubIsRejected() {
    testing.assertThrows("throwsWithoutSub", "identity");
}

func testPollUsesTheSharedVocabulary() {
    testing.assertEqual(pollFrom(doc('{"error":"expired_token"}')).state,
        identity.STATE_EXPIRED);
    testing.assertEqual(pollFrom(doc('{"access_token":"t"}')).accessToken, "t");
}
