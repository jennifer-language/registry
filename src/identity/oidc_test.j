# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for the generic OIDC identity provider. Run with:
#
#     jennifer test src/identity/oidc_test.j
#
# The tests concentrate on reading the discovery document, which is how one
# module serves providers of differing capability.

use testing;
use json;

func cfg() {
    return identity.Config{
        name: "authelia",
        baseUrl: "https://auth.corp.test",
        clientId: "registry",
        clientSecret: "",
        scopes: "",
        metadata: ""
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
    testing.assertEqual(
        discoveryUrl(cfg()),
        "https://auth.corp.test/.well-known/openid-configuration");
}

func testEndpointsComeFromTheDocument() {
    testing.assertEqual(
        endpointFrom(withDevice(), "token_endpoint"),
        "https://auth.corp.test/api/oidc/token");
    testing.assertEqual(endpointFrom(withDevice(), "not_advertised"), "");
}

func testFlowIsTakenFromTheProviderNotAssumed() {
    testing.assertEqual(flowFrom(withDevice()), "device");
    testing.assertEqual(flowFrom(withoutDevice()), "authcode");
}

func testSubjectBindsToTheSubClaim() {
    def s as identity.Subject init subjectFrom(
        cfg(),
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
    testing.assertEqual(pollFrom(doc('{"error":"expired_token"}')).state, identity.STATE_EXPIRED);
    testing.assertEqual(pollFrom(doc('{"access_token":"t"}')).accessToken, "t");
}

func testTheProviderCanBeBuilt() {
    # every name in the vtable must exist, or the server fails to boot
    def p as identity.Provider init provider();
    testing.assertEqual(len($p.memberships(cfg(), "any-token")), 0);
}

func testTheClientSecretIsSentOnlyWhenConfigured() {
    # RFC 6749 2.3.1: Keycloak's default client is confidential
    testing.assertEqual(clientFields(cfg()), "client_id=registry");
    def confidential as identity.Config init cfg();
    $confidential.clientSecret = "s3cret";
    testing.assertEqual(clientFields($confidential), "client_id=registry&client_secret=s3cret");
}

func testANumericSubIsStoredAsItsText() {
    def s as identity.Subject init subjectFrom(cfg(), doc('{"sub":42,"preferred_username":"x"}'));
    testing.assertEqual($s.id, "42");
}

func testTheDiscoveryDocumentFromBootIsUsedWithoutAFetch() {
    # the server fetches once and carries the text; every later call reads it
    def c as identity.Config init cfg();
    $c.metadata = '{"token_endpoint":"https://auth.corp.test/t",' +
        '"device_authorization_endpoint":"https://auth.corp.test/d"}';
    testing.assertEqual(endpointFrom(metadata($c), "token_endpoint"), "https://auth.corp.test/t");
    testing.assertEqual(flowOf($c), "device");
    testing.assertEqual(authorize($c), "");
}
