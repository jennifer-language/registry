# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.26.0
#
# White-box tests for outbound.j. Run with:
#
#     jennifer test src/outbound_test.j
#
# The event builders are pure; `request` is run against a loopback server and a
# port nothing listens on, logging to a temporary file.

use testing;
use fs;
use httpd;
use task;

func testAPathKeepsNoHostQueryOrFragment() {
    testing.assertEqual(
        pathOf("https://api.github.com/repos/a/b/contents/deck.toml?ref=abc"),
        "/repos/a/b/contents/deck.toml");
    testing.assertEqual(pathOf("https://h.test/oauth/token?client_secret=s#x"), "/oauth/token");
    testing.assertEqual(pathOf("https://h.test"), "/");
}

func testAnAnsweredCallIsDebugUnlessItFailed() {
    def ok as audit.Event init callAnswered("github", "GET", "/repos/a/b", 200, 12, {}, '{}');
    testing.assertEqual($ok.level, audit.DEBUG);
    # a 404 is how the adapters ask whether something exists
    def absent as audit.Event init callAnswered("github", "GET", "/x", 404, 3, {}, "");
    testing.assertEqual($absent.level, audit.DEBUG);
    def bad as audit.Event init callAnswered("gitlab", "GET", "/x", 500, 3, {}, "oops");
    testing.assertEqual($bad.level, audit.WARN);
    testing.assertEqual($bad.message, "outbound call failed");
    testing.assertEqual($bad.fields["kind"], "status");
    testing.assertFalse(maps.has($bad.fields, "message"));
}

func testARateLimitedCallKeepsWhatGithubSaid() {
    def h as map of string to string init {
        "x-github-request-id": "C0DE:1234",
        "x-ratelimit-remaining": "0",
        "x-ratelimit-reset": "1794768489",
        "retry-after": "60",
        "set-cookie": "session=secret",
        "content-type": "application/json"
    };
    def ev as audit.Event init callAnswered(
        "github",
        "GET",
        "/repos/deckyard/deck-forgejo/git/ref/tags/0.4.0",
        403,
        87,
        $h,
        '{"message":"API rate limit exceeded for 203.0.113.7."}');
    testing.assertEqual($ev.level, audit.WARN);
    testing.assertEqual($ev.fields["service"], "github");
    testing.assertEqual($ev.fields["method"], "GET");
    testing.assertEqual($ev.fields["path"], "/repos/deckyard/deck-forgejo/git/ref/tags/0.4.0");
    testing.assertEqual($ev.fields["status"], "403");
    testing.assertEqual($ev.fields["ms"], "87");
    testing.assertEqual($ev.fields["x-github-request-id"], "C0DE:1234");
    testing.assertEqual($ev.fields["x-ratelimit-remaining"], "0");
    testing.assertEqual($ev.fields["x-ratelimit-reset"], "1794768489");
    testing.assertEqual($ev.fields["retry-after"], "60");
    testing.assertEqual($ev.fields["message"], "API rate limit exceeded for 203.0.113.7.");
    # only the named headers: never a cookie
    testing.assertFalse(maps.has($ev.fields, "set-cookie"));
}

func testAForgeMessageIsCutAndOnlyTheMessageIsRead() {
    def long as string init strings.repeat("x", 500);
    testing.assertEqual(len(messageOf('{"message":"' + $long + '"}')), 203);
    testing.assertEqual(messageOf('{"error":"bad_verification_code"}'), "bad_verification_code");
    # anything else in the body is never read
    testing.assertEqual(messageOf('{"access_token":"gho_secret"}'), "");
    testing.assertEqual(messageOf("<html>"), "");
    testing.assertEqual(messageOf('["message"]'), "");
}

func testANetworkFailureKeepsWhyItFailed() {
    def ev as audit.Event init callFailed(
        "github",
        "GET",
        "/repos/a/b",
        20,
        "net",
        {"reason": "refused", "sent": "false", "replied": "false"});
    testing.assertEqual($ev.level, audit.WARN);
    testing.assertEqual($ev.fields["status"], "0");
    testing.assertEqual($ev.fields["kind"], "net");
    testing.assertEqual($ev.fields["reason"], "refused");
    testing.assertEqual($ev.fields["sent"], "false");
    testing.assertEqual($ev.fields["replied"], "false");
}

func testAnUntracedCallCountsNothing() {
    testing.assertEqual(calls(none()), 0);
}

# serveOne answers one request with GitHub's rate-limit reply.
func serveOne(srv as httpd.Server) {
    def req as httpd.Request init httpd.accept($srv);
    httpd.setHeader($req, "x-ratelimit-remaining", "0");
    httpd.setHeader($req, "x-github-request-id", "C0DE:1");
    httpd.respond($req, 403, '{"message":"API rate limit exceeded"}');
    return null;
}

func testCallsAreCountedAndLoggedUnderTheRequestId() {
    def dir as string init fs.makeTempDir("", "jvc-outbound");
    def path as string init $dir + "/registry.log";
    def sink as audit.Sink init audit.withRequest(
        audit.open("info", "logfmt", $path, false),
        "ray-7");
    def t as Trace init traced($sink, "ray-7", kv.open());
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    defer httpd.shutdown($srv);
    def server as task of null init spawn {
        return serveOne($srv);
    };
    def h as map of string to string init {"Authorization": "Bearer gho_secret_token"};
    def res as http.Response init request(
        $t,
        "github",
        "GET",
        "http://" + httpd.address($srv) + "/repos/a/b?access_token=gho_query_secret",
        $h,
        "",
        5000,
        0);
    task.wait($server);
    testing.assertEqual($res.status, 403);
    # a port nothing listens on: a net.NetError, logged and passed on unchanged
    def kind as string init "";
    try {
        request($t, "github", "GET", "http://127.0.0.1:1/repos/a/b", $h, "", 2000, 0);
    } catch (e) {
        $kind = $e.kind;
    }
    testing.assertEqual($kind, "net");
    testing.assertEqual(calls($t), 2);
    forget($t);
    testing.assertEqual(calls($t), 0);
    def text as string init fs.readString($path);
    def lines as list of string init strings.split(strings.trim($text), "\n");
    testing.assertEqual(len($lines), 2);
    for (def line in $lines) {
        testing.assertContains($line, "outbound call failed");
        testing.assertContains($line, "request=ray-7");
        testing.assertContains($line, "path=/repos/a/b ");
    }
    testing.assertContains($lines[0], "status=403");
    testing.assertContains($lines[0], "x-github-request-id=C0DE:1");
    testing.assertContains($lines[1], "kind=net");
    testing.assertContains($lines[1], "reason=refused");
    # neither the header nor the query reaches the log
    testing.assertFalse(strings.contains($text, "gho_"));
    fs.removeAll($dir);
}
