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

def const ACCOUNT as int init 1234567;
def const TOKEN_TTL as int init 3600;
def const REFRESH_TTL as int init 1209600;

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
        scopes: ""
    };
}

func config() {
    return Config{
        provider: githubIdentity.provider(),
        providerConfig: providerCfg("Iv1.0123456789abcdef"),
        signingKey: convert.bytesFromString("a signing secret nobody else has", "utf-8"),
        tokenTtl: TOKEN_TTL,
        refreshTtl: REFRESH_TTL,
        keepForgeToken: true
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
        keepForgeToken: false
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
    testing.assertEqual(refresh(offConfig(), $db, '{}', nowish()).status, 404);
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
        accountId: ACCOUNT,
        login: "octocat",
        orgs: $orgs,
        accessToken: "gho_from_the_provider"
    };
    def out as AuthReply init issueLogin(config(), emptyDb(), $found, nowish());
    testing.assertEqual($out.status, 200);
    testing.assertTrue($out.changed);
    testing.assertEqual(json.asInt($out.body, "/accountId"), ACCOUNT);
    testing.assertEqual(store.countRefresh($out.db, ACCOUNT), 1);
}

func identified(accessToken as string) {
    def none as map of string to string init {};
    return Login{
        ok: true,
        reply: pending(emptyDb()),
        accountId: ACCOUNT,
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

func testWithoutRouteANoForgeTokenIsKept() {
    # where identity and forge differ the forge would not accept it
    def c as Config init config();
    $c.keepForgeToken = false;
    def out as AuthReply init issueLogin($c, emptyDb(), identified("gho_secret"), nowish());
    testing.assertEqual(store.getForgeToken($out.db, ACCOUNT), "");
}

func testMissingFieldsAre400() {
    def db as flatdb.DB init emptyDb();
    testing.assertEqual(token(config(), $db, '{}', nowish()).status, 400);
    testing.assertEqual(refresh(config(), $db, '{}', nowish()).status, 400);
}

# --- poll states ------------------------------------------------------------

func testPollStatesMapToStatusCodes() {
    def db as flatdb.DB init emptyDb();
    testing.assertEqual(stateReply($db, "pending").status, 202);
    testing.assertEqual(stateReply($db, "slowDown").status, 429);
    testing.assertEqual(stateReply($db, "denied").status, 403);
    testing.assertEqual(stateReply($db, "expired").status, 410);
}

func testPendingCarriesAStatusBody() {
    def out as AuthReply init stateReply(emptyDb(), "pending");
    testing.assertEqual(json.asString($out.body, "/status"), "pending");
    testing.assertFalse($out.changed);
}

func testAnUnknownStateIsTerminalNotPending() {
    # treating it as pending would spin a client until its code expired
    testing.assertEqual(stateReply(emptyDb(), "something-new").status, 403);
}

# --- issuing ----------------------------------------------------------------

func testIssueReturnsAUsableTokenPair() {
    def out as AuthReply init issue(config(), emptyDb(), ACCOUNT, "alice", {}, 0, nowish());
    testing.assertEqual($out.status, 200);
    testing.assertTrue($out.changed);
    testing.assertEqual(json.asInt($out.body, "/accountId"), ACCOUNT);
    testing.assertEqual(json.asString($out.body, "/login"), "alice");
    testing.assertEqual(json.asInt($out.body, "/expiresIn"), TOKEN_TTL);
    # the bearer token verifies, and carries the identity
    def who as token.Identity init token.verify(
        config().signingKey,
        json.asString($out.body, "/token"));
    testing.assertEqual($who.accountId, ACCOUNT);
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
        store.Refresh{accountId: 999, login: "old", expiresAt: 1, orgs: {}, orgsCheckedAt: 0});
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
    def out as AuthReply init refresh(config(), $first.db, refreshBody($given), nowish());
    testing.assertEqual($out.status, 200);
    testing.assertEqual(json.asInt($out.body, "/accountId"), ACCOUNT);
    # the identity survives without another provider call
    testing.assertEqual(json.asString($out.body, "/login"), "alice");
}

func testRefreshRotatesTheToken() {
    def first as AuthReply init loggedIn(emptyDb());
    def given as string init json.asString($first.body, "/refreshToken");
    def out as AuthReply init refresh(config(), $first.db, refreshBody($given), nowish());
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
    def used as AuthReply init refresh(config(), $first.db, refreshBody($given), nowish());
    def again as AuthReply init refresh(config(), $used.db, refreshBody($given), nowish());
    testing.assertEqual($again.status, 401);
}

func testAnUnknownRefreshTokenIs401() {
    def out as AuthReply init refresh(
        config(),
        emptyDb(),
        refreshBody("0000000000000000000000000000000000000000000000000000000000000000"),
        nowish());
    testing.assertEqual($out.status, 401);
}

func testAnExpiredRefreshTokenIs401AndIsDropped() {
    def db as flatdb.DB init emptyDb();
    def token as string init token.newRefresh();
    def expired as store.Refresh init store.Refresh{
        accountId: ACCOUNT,
        login: "alice",
        expiresAt: 1,
        orgs: {},
        orgsCheckedAt: 0
    };
    $db = store.putRefresh($db, token.fingerprint($token), $expired);
    def out as AuthReply init refresh(config(), $db, refreshBody($token), nowish());
    testing.assertEqual($out.status, 401);
    testing.assertTrue($out.changed);
    testing.assertFalse(store.hasRefresh($out.db, token.fingerprint($token)));
}

# --- authenticating a write -------------------------------------------------

func testAuthenticateAcceptsAMintedToken() {
    def out as AuthReply init loggedIn(emptyDb());
    def header as string init "Bearer " + json.asString($out.body, "/token");
    def who as token.Identity init authenticate(config(), $header);
    testing.assertEqual($who.accountId, ACCOUNT);
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
        $reply = refresh(config(), $reply.db, refreshBody($given), $start + $days * 86400);
        testing.assertEqual($reply.status, 200);
    }
    def last as string init json.asString($reply.body, "/refreshToken");
    def over as AuthReply init refresh(
        config(),
        $reply.db,
        refreshBody($last),
        $start + 31 * 86400);
    testing.assertEqual($over.status, 401);
    testing.assertContains(json.asString($over.body, "/error"), "log in again");
    testing.assertFalse(store.hasRefresh($over.db, token.fingerprint($last)));
}

func testOnlyACanonicalNumberIsAnAccountId() {
    # "07" and "+7" both read as 7, which would make two subjects one account
    testing.assertEqual(accountIdOf("1234567"), 1234567);
    for (def bad in ["07", "+7", "-7", "0", "", "7a", "a1b2-uuid"]) {
        testing.assertEqual(accountIdOf($bad), 0);
    }
}
