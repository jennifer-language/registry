# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for authview.j. Run with:
#
#     jennifer test src/authview_test.j
#
# Everything except the provider calls is tested here without a socket.

use testing;
use json;
use convert;
import "./identity/github.j" as githubIdentity;

def const ACCOUNT as string init "1234567";
def const TOKEN_TTL as int init 3600;
def const REFRESH_TTL as int init 1209600;
def const ORG_MAX_AGE as int init 604800;

func emptyDb() {
    return store.open("/no/such/jvc/auth/missing.json");
}

# nowish is the real clock, because a minted token carries a real `exp` that
# jwt.verify enforces.
func nowish() {
    return token.now();
}

# providerCfg is where the identity provider lives, for a configured registry.
func providerCfg(clientId as string) {
    return identity.Config{
        name: "github",
        baseUrl: "",
        clientId: $clientId,
        clientSecret: "",
        scopes: "",
        metadata: ""
    };
}

func config() {
    return Config{
        provider: githubIdentity.provider(),
        providerConfig: providerCfg("Iv1.0123456789abcdef"),
        signingKey: convert.bytesFromString("a signing secret nobody else has", "utf-8"),
        tokenTtl: TOKEN_TTL,
        refreshTtl: REFRESH_TTL,
        orgMaxAge: ORG_MAX_AGE
    };
}

# offConfig is a registry with no OAuth application configured.
func offConfig() {
    def none as bytes;
    return Config{
        provider: githubIdentity.provider(),
        providerConfig: providerCfg(""),
        signingKey: $none,
        tokenTtl: 0,
        refreshTtl: 0,
        orgMaxAge: 0
    };
}

# --- the configuration gate -------------------------------------------------

func testEnabledNeedsBothHalves() {
    testing.assertTrue(enabled(config()));
    testing.assertFalse(enabled(offConfig()));
    # a client id alone is not enough
    def half as Config init config();
    def none as bytes;
    $half.signingKey = $none;
    testing.assertFalse(enabled($half));
}

func testEveryEndpoint404sWhenAuthIsOff() {
    def db as flatdb.DB init emptyDb();
    testing.assertEqual(device(offConfig(), $db).status, 404);
    testing.assertEqual(token(offConfig(), $db, '{}', nowish()).status, 404);
    testing.assertEqual(refresh(offConfig(), $db, '{}', nowish(), GRANT_VALID).status, 404);
}

# --- reading the request body -----------------------------------------------

func testBodyFieldReadsAField() {
    testing.assertEqual(bodyField('{"deviceCode": "abc"}', "deviceCode"), "abc");
}

func testBodyFieldTreatsMissingAndMalformedAlike() {
    testing.assertEqual(bodyField('{"other": "abc"}', "deviceCode"), "");
    testing.assertEqual(bodyField("not json at all", "deviceCode"), "");
    testing.assertEqual(bodyField("", "deviceCode"), "");
}

func testAnEarlyAnswerNeedsNoStore() {
    # the network half runs without the write lock and must not touch the registry
    def got as Login init login(config(), '{}');
    testing.assertFalse($got.ok);
    testing.assertEqual($got.reply.status, 400);
    testing.assertFalse($got.reply.changed);
}

func testIssueLoginPassesAnEarlyAnswerThroughUnsaved() {
    def db as flatdb.DB init emptyDb();
    def out as AuthReply init issueLogin(config(), $db, login(offConfig(), '{}'), nowish());
    testing.assertEqual($out.status, 404);
    testing.assertFalse($out.changed);
}

func testIssueLoginIssuesForAnIdentifiedAccount() {
    # the store half alone, with what the network half would have found
    def orgs as map of string to string init {"acme": "99"};
    def found as Login init Login{
        ok: true,
        reply: pending(emptyDb()),
        subject: ACCOUNT,
        login: "octocat",
        orgs: $orgs,
        accessToken: "gho_from_the_provider"
    };
    def out as AuthReply init issueLogin(config(), emptyDb(), $found, nowish());
    testing.assertEqual($out.status, 200);
    testing.assertTrue($out.changed);
    testing.assertEqual(json.asString($out.body, "/subject"), ACCOUNT);
    testing.assertEqual(store.countRefresh($out.db, ACCOUNT), 1);
}

func identified(accessToken as string) {
    def none as map of string to string init {};
    return Login{
        ok: true,
        reply: pending(emptyDb()),
        subject: ACCOUNT,
        login: "octocat",
        orgs: $none,
        accessToken: $accessToken
    };
}

func testTheForgeTokenIsKeptSealed() {
    # kept for 7.1 route A, never in the clear
    def out as AuthReply init issueLogin(config(), emptyDb(), identified("gho_secret"), nowish());
    def sealed as string init store.getForgeToken($out.db, ACCOUNT);
    testing.assertNotEqual($sealed, "");
    testing.assertFalse(strings.contains($sealed, "gho_secret"));
    testing.assertEqual(forgecred.unseal(config().signingKey, $sealed), "gho_secret");
}

func testTheForgeTokenIsNeverInTheReply() {
    def out as AuthReply init issueLogin(config(), emptyDb(), identified("gho_secret"), nowish());
    testing.assertFalse(strings.contains(json.encode($out.body), "gho_secret"));
}

func testTheProviderTokenIsKeptForEveryLogin() {
    # 8.5: a refresh re-checks the grant with it, whatever the source authority
    def out as AuthReply init issueLogin(config(), emptyDb(), identified("gho_secret"), nowish());
    testing.assertFalse(store.getForgeToken($out.db, ACCOUNT) == "");
}

# --- re-checking the grant on refresh (8.5) -----------------------------------

# A provider whose `subject` answers from the token: "ok" names ACCOUNT, "other"
# another account, "revoked" is a 401, anything else an outage.
func fakeFlow(cfg as identity.Config) {
    return "device";
}

func fakeSubject(cfg as identity.Config, accessToken as string) {
    def none as map of string to string init {};
    if ($accessToken == "revoked") {
        throw Error{kind: identity.REJECTED, message: "rejected the token: 401"};
    }
    if ($accessToken == "ok" or $accessToken == "other") {
        def id as string init ACCOUNT;
        if ($accessToken == "other") {
            $id = "999";
        }
        return identity.Subject{
            provider: "fake",
            id: $id,
            login: "alice",
            orgs: $none,
            orgsCheckedAt: ""
        };
    }
    throw Error{kind: "timeout", message: "no answer"};
}

func fakeConfig() {
    def c as Config init config();
    def p as identity.Provider init $c.provider;
    $p.flow = fakeFlow;
    $p.subject = fakeSubject;
    $c.provider = $p;
    return $c;
}

# grantFor logs in with `providerToken` kept, and asks `checkGrant`.
func grantFor(providerToken as string) {
    def got as AuthReply init issueLogin(
        fakeConfig(),
        emptyDb(),
        identified($providerToken),
        nowish());
    def body as string init refreshBody(json.asString($got.body, "/refreshToken"));
    return checkGrant(fakeConfig(), $got.db, $body);
}

func fakeExchange(
    cfg as identity.Config,
    code as string,
    verifier as string,
    redirectUri as string) {
    if ($code == "good" and $verifier == "v") {
        return "ok";
    }
    throw Error{kind: "identity", message: "invalid_grant"};
}

func codeConfig() {
    def c as Config init fakeConfig();
    def p as identity.Provider init $c.provider;
    $p.exchangeCode = fakeExchange;
    $c.provider = $p;
    return $c;
}

func codeBody(code as string, redirect as string) {
    return '{"code": "' + $code + '", "codeVerifier": "v", "redirectUri": "' + $redirect + '"}';
}

func testAnAuthorizationCodeLogsIn() {
    # 12.2 authcode: the client ran PKCE against the provider and hands over the code
    def got as Login init login(codeConfig(), codeBody("good", "http://127.0.0.1:53682/cb"));
    testing.assertTrue($got.ok);
    testing.assertEqual($got.subject, ACCOUNT);
    def v6 as Login init login(codeConfig(), codeBody("good", "http://[::1]:8000/"));
    testing.assertTrue($v6.ok);
}

func testARefusedCodeIs400() {
    def got as Login init login(codeConfig(), codeBody("bad", "http://127.0.0.1:53682/cb"));
    testing.assertFalse($got.ok);
    testing.assertEqual($got.reply.status, 400);
}

func testOnlyALoopbackRedirectIsAccepted() {
    # RFC 8252: codes are exchanged only for a client on the user's machine
    for (def bad in [
        "https://evil.example/cb",
        "http://localhost:53682/cb",
        "http://127.0.0.1/cb",
        "http://127.0.0.1:x/cb",
        "http://127.0.0.1.evil.example:80/"
    ]) {
        def got as Login init login(codeConfig(), codeBody("good", $bad));
        testing.assertEqual($got.reply.status, 400);
    }
}

func testADeviceOnlyProviderRefusesACode() {
    # github's exchange answers "" (it offers no authcode flow)
    def got as Login init login(config(), codeBody("good", "http://127.0.0.1:53682/cb"));
    testing.assertEqual($got.reply.status, 400);
    testing.assertContains(json.asString($got.reply.body, "/error"), "authcode");
}

func testCheckGrantAsksTheProvider() {
    testing.assertEqual(grantFor("ok"), GRANT_VALID);
    testing.assertEqual(grantFor("revoked"), GRANT_REVOKED);
    testing.assertEqual(grantFor("other"), GRANT_REVOKED);
    testing.assertEqual(grantFor("unreachable"), GRANT_UNKNOWN);
    testing.assertEqual(checkGrant(fakeConfig(), emptyDb(), refreshBody("nope")), "");
}

func testCheckGrantWithoutAKeptTokenIsMissing() {
    def got as AuthReply init loggedIn(emptyDb());
    def body as string init refreshBody(json.asString($got.body, "/refreshToken"));
    testing.assertEqual(checkGrant(fakeConfig(), $got.db, $body), GRANT_MISSING);
}

func testARevokedGrantEndsTheLogin() {
    def got as AuthReply init issueLogin(config(), emptyDb(), identified("gho_secret"), nowish());
    def given as string init json.asString($got.body, "/refreshToken");
    def out as AuthReply init refresh(
        config(),
        $got.db,
        refreshBody($given),
        nowish(),
        GRANT_REVOKED);
    testing.assertEqual($out.status, 401);
    testing.assertContains(json.asString($out.body, "/error"), "log in again");
    testing.assertFalse(store.hasRefresh($out.db, token.fingerprint($given)));
    testing.assertEqual(store.getForgeToken($out.db, ACCOUNT), "");
}

func testAMissingGrantEndsTheLogin() {
    def got as AuthReply init loggedIn(emptyDb());
    def given as string init json.asString($got.body, "/refreshToken");
    def out as AuthReply init refresh(
        config(),
        $got.db,
        refreshBody($given),
        nowish(),
        GRANT_MISSING);
    testing.assertEqual($out.status, 401);
    testing.assertFalse(store.hasRefresh($out.db, token.fingerprint($given)));
}

func testAnUnaskableProviderIs502AndKeepsTheRefreshToken() {
    def got as AuthReply init loggedIn(emptyDb());
    def given as string init json.asString($got.body, "/refreshToken");
    def out as AuthReply init refresh(
        config(),
        $got.db,
        refreshBody($given),
        nowish(),
        GRANT_UNKNOWN);
    testing.assertEqual($out.status, 502);
    testing.assertTrue(store.hasRefresh($out.db, token.fingerprint($given)));
}

func testMissingFieldsAre400() {
    def db as flatdb.DB init emptyDb();
    testing.assertEqual(token(config(), $db, '{}', nowish()).status, 400);
    testing.assertEqual(refresh(config(), $db, '{}', nowish(), GRANT_VALID).status, 400);
}

# --- poll states ------------------------------------------------------------

func testPollStatesMapToStatusCodes() {
    def db as flatdb.DB init emptyDb();
    testing.assertEqual(stateReply($db, "pending", "").status, 202);
    testing.assertEqual(stateReply($db, "slowDown", "").status, 429);
    testing.assertEqual(stateReply($db, "denied", "").status, 403);
    testing.assertEqual(stateReply($db, "expired", "").status, 410);
    # final, so a client stops polling: jvc retries a 5xx
    def spent as AuthReply init stateReply($db, "spent", "GitHub answered HTTP 500");
    testing.assertEqual($spent.status, 400);
    testing.assertContains(json.asString($spent.body, "/error"), "start the login again");
}

func testPendingCarriesAStatusBody() {
    def out as AuthReply init stateReply(emptyDb(), "pending", "");
    testing.assertEqual(json.asString($out.body, "/status"), "pending");
    testing.assertFalse($out.changed);
}

func testAnUnknownStateIsTerminalNotPending() {
    # treating it as pending would spin a client until its code expired
    testing.assertEqual(stateReply(emptyDb(), "something-new", "x").status, 502);
}

# --- issuing ----------------------------------------------------------------

func testIssueReturnsAUsableTokenPair() {
    def out as AuthReply init issue(config(), emptyDb(), ACCOUNT, "alice", {}, 0, nowish());
    testing.assertEqual($out.status, 200);
    testing.assertTrue($out.changed);
    testing.assertEqual(json.asString($out.body, "/subject"), ACCOUNT);
    testing.assertEqual(json.asString($out.body, "/login"), "alice");
    testing.assertEqual(json.asInt($out.body, "/expiresIn"), TOKEN_TTL);
    # the bearer token verifies, and carries the identity
    def who as token.Identity init token.verify(
        config().signingKey,
        "github",
        json.asString($out.body, "/token"));
    testing.assertEqual($who.subject, ACCOUNT);
    testing.assertEqual($who.login, "alice");
}

func testTheLoginAnswersWithTheOrganisationsItSaw() {
    # makes an organisation the provider did not disclose visible at login
    def out as AuthReply init issue(
        config(),
        emptyDb(),
        ACCOUNT,
        "alice",
        {"viverto": "42", "acme": "7"},
        0,
        nowish());
    testing.assertEqual(json.length($out.body, "/orgs"), 2);
    # sorted, for a stable order
    testing.assertEqual(json.asString($out.body, "/orgs/0"), "acme");
    testing.assertEqual(json.asString($out.body, "/orgs/1"), "viverto");
}

func testTheOrganisationListNamesLoginsNotIds() {
    # a claim is typed as a login, so ids are not returned
    def out as json.Value init orgNames({"viverto": "42"});
    testing.assertEqual(json.asString($out, "/0"), "viverto");
}

func testAnAccountInNoOrganisationsGetsAnEmptyList() {
    # present and empty, so a client can tell it from a registry that omits it
    def out as AuthReply init issue(config(), emptyDb(), ACCOUNT, "alice", {}, 0, nowish());
    testing.assertTrue(json.has($out.body, "/orgs"));
    testing.assertEqual(json.length($out.body, "/orgs"), 0);
}

func testIssueRecordsTheRefreshTokenByFingerprintOnly() {
    def out as AuthReply init issue(config(), emptyDb(), ACCOUNT, "alice", {}, 0, nowish());
    def given as string init json.asString($out.body, "/refreshToken");
    testing.assertTrue(store.hasRefresh($out.db, token.fingerprint($given)));
    # the credential itself must not be what is written down
    testing.assertFalse(store.hasRefresh($out.db, $given));
}

func testIssuePurgesExpiredRefreshTokens() {
    def db as flatdb.DB init emptyDb();
    $db = store.putRefresh(
        $db,
        "deadbeef",
        store.Refresh{subject: "999", login: "old", expiresAt: 1, orgs: {}, orgsCheckedAt: 0});
    testing.assertTrue(store.hasRefresh($db, "deadbeef"));
    def out as AuthReply init issue(config(), $db, ACCOUNT, "alice", {}, 0, nowish());
    testing.assertFalse(store.hasRefresh($out.db, "deadbeef"));
}

# --- refreshing -------------------------------------------------------------

# loggedIn issues a pair and returns the refresh token from it.
func loggedIn(db as flatdb.DB) {
    return issue(config(), $db, ACCOUNT, "alice", {}, nowish(), nowish());
}

func refreshBody(token as string) {
    return '{"refreshToken": "' + $token + '"}';
}

func testRefreshReturnsANewPair() {
    def first as AuthReply init loggedIn(emptyDb());
    def given as string init json.asString($first.body, "/refreshToken");
    def out as AuthReply init refresh(
        config(),
        $first.db,
        refreshBody($given),
        nowish(),
        GRANT_VALID);
    testing.assertEqual($out.status, 200);
    testing.assertEqual(json.asString($out.body, "/subject"), ACCOUNT);
    # the identity survives without another provider call
    testing.assertEqual(json.asString($out.body, "/login"), "alice");
}

func testRefreshRotatesTheToken() {
    def first as AuthReply init loggedIn(emptyDb());
    def given as string init json.asString($first.body, "/refreshToken");
    def out as AuthReply init refresh(
        config(),
        $first.db,
        refreshBody($given),
        nowish(),
        GRANT_VALID);
    def replacement as string init json.asString($out.body, "/refreshToken");
    testing.assertFalse($given == $replacement);
    # the spent token is gone, the replacement is on record
    testing.assertFalse(store.hasRefresh($out.db, token.fingerprint($given)));
    testing.assertTrue(store.hasRefresh($out.db, token.fingerprint($replacement)));
}

func testASpentRefreshTokenCannotBeReplayed() {
    # rotation: a captured token works once
    def first as AuthReply init loggedIn(emptyDb());
    def given as string init json.asString($first.body, "/refreshToken");
    def used as AuthReply init refresh(
        config(),
        $first.db,
        refreshBody($given),
        nowish(),
        GRANT_VALID);
    def again as AuthReply init refresh(
        config(),
        $used.db,
        refreshBody($given),
        nowish(),
        GRANT_VALID);
    testing.assertEqual($again.status, 401);
}

func testAnUnknownRefreshTokenIs401() {
    def out as AuthReply init refresh(
        config(),
        emptyDb(),
        refreshBody("0000000000000000000000000000000000000000000000000000000000000000"),
        nowish(),
        GRANT_VALID);
    testing.assertEqual($out.status, 401);
}

func testAnExpiredRefreshTokenIs401AndIsDropped() {
    def db as flatdb.DB init emptyDb();
    def token as string init token.newRefresh();
    def expired as store.Refresh init store.Refresh{
        subject: ACCOUNT,
        login: "alice",
        expiresAt: 1,
        orgs: {},
        orgsCheckedAt: 0
    };
    $db = store.putRefresh($db, token.fingerprint($token), $expired);
    def out as AuthReply init refresh(config(), $db, refreshBody($token), nowish(), GRANT_VALID);
    testing.assertEqual($out.status, 401);
    testing.assertTrue($out.changed);
    testing.assertFalse(store.hasRefresh($out.db, token.fingerprint($token)));
}

# --- authenticating a write -------------------------------------------------

func testAuthenticateAcceptsAMintedToken() {
    def out as AuthReply init loggedIn(emptyDb());
    def header as string init "Bearer " + json.asString($out.body, "/token");
    def who as token.Identity init authenticate(config(), $header);
    testing.assertEqual($who.subject, ACCOUNT);
}

func throwsOnMissingBearer() {
    authenticate(config(), "");
}

func throwsOnWrongScheme() {
    authenticate(config(), "Basic abc");
}

func testAuthenticateRejectsAMissingHeader() {
    testing.assertThrows("throwsOnMissingBearer", "auth");
}

func testAuthenticateRejectsAWrongScheme() {
    testing.assertThrows("throwsOnWrongScheme", "auth");
}

func testALoginEndsAfterThirtyDaysHoweverOftenItIsRefreshed() {
    # login-time memberships must not ride an endless refresh chain
    def reply as AuthReply init loggedIn(emptyDb());
    def start as int init nowish();
    # refreshed every ten days, well inside each refresh token's own lifetime
    for (def days in [10, 20, 29]) {
        def given as string init json.asString($reply.body, "/refreshToken");
        $reply = refresh(
            config(),
            $reply.db,
            refreshBody($given),
            $start + $days * 86400,
            GRANT_VALID);
        testing.assertEqual($reply.status, 200);
    }
    def last as string init json.asString($reply.body, "/refreshToken");
    def over as AuthReply init refresh(
        config(),
        $reply.db,
        refreshBody($last),
        $start + 31 * 86400,
        GRANT_VALID);
    testing.assertEqual($over.status, 401);
    testing.assertContains(json.asString($over.body, "/error"), "log in again");
    testing.assertFalse(store.hasRefresh($over.db, token.fingerprint($last)));
}

func testAgedOrganisationMembershipsEndTheRefreshChain() {
    # 8.7: memberships older than the window must not reach a write
    def start as int init nowish();
    def member as AuthReply init issue(
        config(),
        emptyDb(),
        ACCOUNT,
        "alice",
        {"acme": "7"},
        $start,
        $start);
    def given as string init json.asString($member.body, "/refreshToken");
    def fresh as AuthReply init refresh(
        config(),
        $member.db,
        refreshBody($given),
        $start + 86400,
        GRANT_VALID);
    testing.assertEqual($fresh.status, 200);
    def next as string init json.asString($fresh.body, "/refreshToken");
    def over as AuthReply init refresh(
        config(),
        $fresh.db,
        refreshBody($next),
        $start + ORG_MAX_AGE + 1,
        GRANT_VALID);
    testing.assertEqual($over.status, 401);
    testing.assertContains(json.asString($over.body, "/error"), "organisation memberships");
    testing.assertFalse(store.hasRefresh($over.db, token.fingerprint($next)));
}

func testTheMembershipWindowLeavesLoginsWithoutOrganisationsAlone() {
    def start as int init nowish();
    def plain as AuthReply init issue(config(), emptyDb(), ACCOUNT, "alice", {}, $start, $start);
    def given as string init json.asString($plain.body, "/refreshToken");
    def out as AuthReply init refresh(
        config(),
        $plain.db,
        refreshBody($given),
        $start + ORG_MAX_AGE + 1,
        GRANT_VALID);
    testing.assertEqual($out.status, 200);
}

func testANumericSubjectAlsoAnswersAsAccountId() {
    # `accountId` stays for clients that read a number; it never merges spellings
    def out as AuthReply init issue(config(), emptyDb(), ACCOUNT, "alice", {}, 0, nowish());
    testing.assertEqual(json.asInt($out.body, "/accountId"), 1234567);
    testing.assertEqual(numericId("1234567"), 1234567);
    for (def bad in ["07", "+7", "-7", "0", "", "7a", "a1b2-uuid"]) {
        testing.assertEqual(numericId($bad), 0);
    }
}

func testAnOpaqueSubjectLogsIn() {
    # 8.1: an OIDC `sub` such as a UUID is stored as it is, without `accountId`
    def uuid as string init "4f1c2a9e-7b1d-4c55-9a7e-2f0d8c3b6a11";
    def out as AuthReply init issue(config(), emptyDb(), $uuid, "alice", {}, 0, nowish());
    testing.assertEqual(json.asString($out.body, "/subject"), $uuid);
    testing.assertFalse(json.has($out.body, "/accountId"));
    def who as token.Identity init token.verify(
        config().signingKey,
        "github",
        json.asString($out.body, "/token"));
    testing.assertEqual($who.subject, $uuid);
}

func testAnUnexpectedPollErrorIsAProviderFaultWithItsCode() {
    # a misconfigured client id must reach the operator, not read as a denial
    def out as AuthReply init stateReply(emptyDb(), "failed", "incorrect_client_credentials");
    testing.assertEqual($out.status, 502);
    testing.assertContains(json.asString($out.body, "/error"), "incorrect_client_credentials");
    testing.assertEqual(stateReply(emptyDb(), "invalid", "incorrect_device_code").status, 400);
}

func testTheRefusalMessagesCountWholeDays() {
    def start as int init nowish();
    # a refresh token that outlives the 30-day cap, so the cap is what refuses
    def c as Config init config();
    $c.refreshTtl = 40 * 86400;
    def first as AuthReply init issue(
        $c,
        emptyDb(),
        ACCOUNT,
        "alice",
        {"acme": "7"},
        $start,
        $start);
    def given as string init json.asString($first.body, "/refreshToken");
    def over as AuthReply init refresh(
        $c,
        $first.db,
        refreshBody($given),
        $start + 31 * 86400,
        GRANT_VALID);
    testing.assertContains(json.asString($over.body, "/error"), "30 days");
    def again as AuthReply init issue(
        config(),
        emptyDb(),
        ACCOUNT,
        "alice",
        {"acme": "7"},
        $start,
        $start);
    def next as string init json.asString($again.body, "/refreshToken");
    def aged as AuthReply init refresh(
        config(),
        $again.db,
        refreshBody($next),
        $start + ORG_MAX_AGE + 60,
        GRANT_VALID);
    testing.assertContains(json.asString($aged.body, "/error"), "168 hours");
}

func testTheBearerSchemeIsCaseInsensitive() {
    def out as AuthReply init issue(config(), emptyDb(), ACCOUNT, "alice", {}, 0, nowish());
    def bearer as string init json.asString($out.body, "/token");
    testing.assertEqual(authenticate(config(), "bearer " + $bearer).subject, ACCOUNT);
    testing.assertEqual(authenticate(config(), "BEARER " + $bearer).subject, ACCOUNT);
}

func throwsOnAForeignProvidersToken() {
    def foreign as string init token.mint(
        config().signingKey,
        "gitlab",
        ACCOUNT,
        "alice",
        {},
        0,
        TOKEN_TTL,
        nowish());
    authenticate(config(), "Bearer " + $foreign);
}

func testATokenFromAnotherProviderDoesNotAuthenticate() {
    # same key, same subject id, another identity provider: not this account
    testing.assertThrows("throwsOnAForeignProvidersToken", "value");
}
