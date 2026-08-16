# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for authview.j. Run with:
#
#     jennifer test src/authview_test.j
#
# Everything except the two GitHub calls inside `token` is a pure function of
# its arguments and the store, so issuing, rotating, and refreshing are all
# exercised here without a socket. `now` is a parameter, so a token is placed
# either side of its expiry by passing a different one.

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
        name: "github", baseUrl: "", clientId: $clientId, clientSecret: "", scopes: ""
    };
}

func config() {
    return Config{
        provider: githubIdentity.provider(),
        providerConfig: providerCfg("Iv1.0123456789abcdef"),
        signingKey: convert.bytesFromString("a signing secret nobody else has", "utf-8"),
        tokenTtl: TOKEN_TTL,
        refreshTtl: REFRESH_TTL
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
        refreshTtl: 0
    };
}

# --- the configuration gate -------------------------------------------------

func testEnabledNeedsBothHalves() {
    testing.assertTrue(enabled(config()));
    testing.assertFalse(enabled(offConfig()));
    # a client id with no signing key cannot verify anything afterwards
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
    # both mean "the request was not usable", so both answer ""
    testing.assertEqual(bodyField('{"other": "abc"}', "deviceCode"), "");
    testing.assertEqual(bodyField("not json at all", "deviceCode"), "");
    testing.assertEqual(bodyField("", "deviceCode"), "");
}

func testMissingFieldsAre400() {
    def db as flatdb.DB init emptyDb();
    testing.assertEqual(token(config(), $db, '{}', nowish()).status, 400);
    testing.assertEqual(refresh(config(), $db, '{}', nowish()).status, 400);
}

# --- poll states ------------------------------------------------------------

func testPollStatesMapToStatusCodes() {
    def db as flatdb.DB init emptyDb();
    # the outcome rides on the status code so a client branches without prose
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
    # waiting cannot recover from an error we do not recognise, and treating it
    # as pending would spin a client until its code expired
    testing.assertEqual(stateReply(emptyDb(), "something-new").status, 403);
}

# --- issuing ----------------------------------------------------------------

func testIssueReturnsAUsableTokenPair() {
    def out as AuthReply init issue(config(), emptyDb(), ACCOUNT, "alice", [], 0, nowish());
    testing.assertEqual($out.status, 200);
    testing.assertTrue($out.changed);
    testing.assertEqual(json.asInt($out.body, "/accountId"), ACCOUNT);
    testing.assertEqual(json.asString($out.body, "/login"), "alice");
    testing.assertEqual(json.asInt($out.body, "/expiresIn"), TOKEN_TTL);
    # the bearer token verifies, and carries the identity
    def who as token.Identity init token.verify(config().signingKey,
        json.asString($out.body, "/token"));
    testing.assertEqual($who.accountId, ACCOUNT);
    testing.assertEqual($who.login, "alice");
}

func testIssueRecordsTheRefreshTokenByFingerprintOnly() {
    def out as AuthReply init issue(config(), emptyDb(), ACCOUNT, "alice", [], 0, nowish());
    def given as string init json.asString($out.body, "/refreshToken");
    testing.assertTrue(store.hasRefresh($out.db, token.fingerprint($given)));
    # the credential itself must not be what is written down
    testing.assertFalse(store.hasRefresh($out.db, $given));
}

func testIssuePurgesExpiredRefreshTokens() {
    def db as flatdb.DB init emptyDb();
    $db = store.putRefresh($db, "deadbeef", store.Refresh{
        accountId: 999, login: "old", expiresAt: 1, orgs: [], orgsCheckedAt: 0
    });
    testing.assertTrue(store.hasRefresh($db, "deadbeef"));
    def out as AuthReply init issue(config(), $db, ACCOUNT, "alice", [], 0, nowish());
    testing.assertFalse(store.hasRefresh($out.db, "deadbeef"));
}

# --- refreshing -------------------------------------------------------------

# loggedIn issues a pair and returns the refresh token from it.
func loggedIn(db as flatdb.DB) {
    return issue(config(), $db, ACCOUNT, "alice", [], 0, nowish());
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
    # the identity survives the exchange without another trip to GitHub
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
    # this is the whole point of rotating: a captured token works once, and the
    # theft shows up as an unexpected logout rather than as silent access
    def first as AuthReply init loggedIn(emptyDb());
    def given as string init json.asString($first.body, "/refreshToken");
    def used as AuthReply init refresh(config(), $first.db, refreshBody($given), nowish());
    def again as AuthReply init refresh(config(), $used.db, refreshBody($given), nowish());
    testing.assertEqual($again.status, 401);
}

func testAnUnknownRefreshTokenIs401() {
    def out as AuthReply init refresh(config(), emptyDb(),
        refreshBody("0000000000000000000000000000000000000000000000000000000000000000"),
        nowish());
    testing.assertEqual($out.status, 401);
}

func testAnExpiredRefreshTokenIs401AndIsDropped() {
    def db as flatdb.DB init emptyDb();
    def token as string init token.newRefresh();
    $db = store.putRefresh($db, token.fingerprint($token), store.Refresh{
        accountId: ACCOUNT, login: "alice", expiresAt: 1, orgs: [], orgsCheckedAt: 0
    });
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
