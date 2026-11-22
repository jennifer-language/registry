# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.27.0
#
# White-box tests for the GitHub forge. Run with:
#
#     jennifer test src/forge/github_test.j
#
# The network calls are not covered (they need GitHub and a token); every
# decision made about a response is.

use testing;
use json;
use httpd;
use task;

func cfg() {
    return forge.Config{
        name: "github",
        baseUrl: "",
        apiToken: "",
        host: "",
        trace: outbound.none()
    };
}

func doc(text as string) {
    return json.decode($text);
}

func testHandlesTheHostedInstance() {
    testing.assertTrue(handlesUrl(cfg(), "https://github.com/acme/deck.git"));
    testing.assertFalse(handlesUrl(cfg(), "https://gitlab.com/acme/deck.git"));
}

func testAnEnterpriseInstanceClaimsItsOwnHost() {
    def ent as forge.Config init forge.Config{
        name: "github",
        baseUrl: "https://gh.corp.test/api/v3",
        apiToken: "",
        host: "gh.corp.test",
        trace: outbound.none()
    };
    testing.assertTrue(handlesUrl($ent, "https://gh.corp.test/acme/deck.git"));
    testing.assertFalse(handlesUrl($ent, "https://github.com/acme/deck.git"));
}

func testPushGrantsAccess() {
    def p as forge.Permission init permissionFrom(doc('{"permissions":{"push":true}}'));
    testing.assertTrue($p.known);
    testing.assertTrue($p.push);
}

func testNoPushIsARefusalNotAnUnknown() {
    def p as forge.Permission init permissionFrom(doc('{"permissions":{"push":false}}'));
    testing.assertTrue($p.known);
    testing.assertFalse($p.push);
}

func testAMissingPermissionsBlockIsUnknown() {
    # an unauthenticated caller is unverified (7.1), not refused or granted
    def p as forge.Permission init permissionFrom(doc('{"name":"deck"}'));
    testing.assertFalse($p.known);
    testing.assertFalse($p.push);
}

func testRepoCarriesTheIdsThatSurviveARename() {
    def body as string init '{"id":1296269,"name":"deck","owner":{"id":6154722,"login":"acme"}}';
    def r as forge.Repo init repoFrom(doc($body));
    testing.assertEqual($r.id, "1296269");
    testing.assertEqual($r.ownerId, "6154722");
    testing.assertEqual($r.owner, "acme");
    testing.assertEqual($r.name, "deck");
}

func testRepoToleratesAPartialPayload() {
    def r as forge.Repo init repoFrom(doc('{"name":"deck"}'));
    testing.assertEqual($r.id, "");
    testing.assertEqual($r.ownerId, "");
    testing.assertEqual($r.name, "deck");
}

func testRefTargetIsRead() {
    testing.assertEqual(refTargetFrom(doc('{"object":{"sha":"abc123"}}')), "abc123");
    testing.assertEqual(refTargetFrom(doc('{}')), "");
}

func testPermissionNeverAsksWithTheRegistrysOwnToken() {
    # an empty caller token must not fall back to the service token, which would
    # report the registry's push access as the caller's; answered before any request
    def c as forge.Config init cfg();
    $c.apiToken = "service-token";
    def p as forge.Permission init permission($c, "https://github.com/acme/deck", "");
    testing.assertFalse($p.known);
    testing.assertFalse($p.push);
    testing.assertContains($p.reason, "caller credential");
}

# --- a rate-limited GitHub, on loopback -----------------------------------------

# serveRateLimit answers `count` requests the way GitHub answers an anonymous
# caller past 60 requests an hour.
func serveRateLimit(srv as httpd.Server, count as int, reset as int) {
    for (def i in 0..$count) {
        def req as httpd.Request init httpd.accept($srv);
        httpd.setHeader($req, "Content-Type", "application/json; charset=utf-8");
        httpd.setHeader($req, "x-ratelimit-limit", "60");
        httpd.setHeader($req, "x-ratelimit-remaining", "0");
        httpd.setHeader($req, "x-ratelimit-reset", convert.toString($reset));
        httpd.setHeader($req, "x-github-request-id", "C0DE:1234:ABCD");
        httpd.respond(
            $req,
            403,
            '{"message":"API rate limit exceeded for 203.0.113.7.","documentation_url":"x"}');
    }
    return null;
}

func testARateLimitedReadThrowsTheForgesWait() {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    defer httpd.shutdown($srv);
    def reset as int init nowSeconds() + 1800;
    def server as task of null init spawn {
        return serveRateLimit($srv, 3, $reset);
    };
    def c as forge.Config init cfg();
    $c.baseUrl = "http://" + httpd.address($srv);
    def repoUrl as string init "https://github.com/deckyard/deck-forgejo";
    # the first read of a publish: a 403 that is a rate limit, not a refusal
    def wait as int init 0;
    def status as int init 0;
    try {
        resolveTag($c, $repoUrl, "0.4.0");
    } catch (e) {
        testing.assertEqual($e.kind, "forge");
        $status = $e.status;
        $wait = $e.retryAfter;
    }
    testing.assertEqual($status, 403);
    testing.assertTrue($wait > 1790 and $wait <= 1800);
    # the repository read throws the same
    $wait = 0;
    try {
        repo($c, $repoUrl);
    } catch (e) {
        $wait = $e.retryAfter;
    }
    testing.assertTrue($wait > 1790);
    # a permission check that is rate-limited is not "unknown" (a 403 refusal)
    $wait = 0;
    try {
        permission($c, $repoUrl, "caller-token");
    } catch (e) {
        $wait = $e.retryAfter;
    }
    testing.assertTrue($wait > 1790);
    task.wait($server);
}

# serveRefusal answers one request the way GitHub answers a token an
# organisation's policy forbids.
func serveRefusal(srv as httpd.Server) {
    def req as httpd.Request init httpd.accept($srv);
    httpd.setHeader($req, "Content-Type", "application/json; charset=utf-8");
    httpd.setHeader($req, "x-ratelimit-remaining", "4990");
    def said as string init "The 'deckyard' organization forbids access via a fine-grained " +
        "personal access tokens if the token's lifetime is greater than 366 days.";
    httpd.respond($req, 403, json.encode(json.map({"message": $said, "documentation_url": "x"})));
    return null;
}

func testARefusedServiceTokenIsTheRegistrys() {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    defer httpd.shutdown($srv);
    def server as task of null init spawn {
        return serveRefusal($srv);
    };
    def c as forge.Config init cfg();
    $c.baseUrl = "http://" + httpd.address($srv);
    $c.apiToken = "github_pat_service";
    def credential as string init "";
    def said as string init "";
    def refused as bool init false;
    try {
        resolveTag($c, "https://github.com/deckyard/deck-routeros", "0.3.0");
    } catch (e) {
        testing.assertEqual($e.status, 403);
        testing.assertEqual($e.retryAfter, 0);
        $credential = $e.credential;
        $said = $e.said;
        $refused = forge.credentialRefused($e);
    }
    task.wait($server);
    testing.assertEqual($credential, forge.REGISTRY_CRED);
    testing.assertTrue($refused);
    testing.assertContains($said, "organization forbids access via a fine-grained");
}
