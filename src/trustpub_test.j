# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for trustpub.j. Run with:
#
#     jennifer test src/trustpub_test.j
#
# Weighted toward refusals: every check in `check` has a test showing the
# refusal when its condition fails.

use testing;
use json;
use crypto;
use encoding;
use convert;
use strings;
use time;

def const AUD as string init "jennifer-registry";
def const ISS as string init "https://token.actions.githubusercontent.com";
def const REPO_ID as string init "123456789";
def const WORKFLOW as string init "acme/deck-routeros/.github/workflows/publish.yml";

# A binding as `deckadmin trust` would record it.
func binding() {
    return Binding{
        provider: GITHUB,
        repositoryId: REPO_ID,
        repository: "acme/deck-routeros",
        workflow: WORKFLOW,
        refPattern: "refs/tags/*",
        deck: "@acme/routeros",
        pending: false,
        createdAt: "1700000000"
    };
}

func testOnlyAPendingBindingExpires() {
    def b as Binding init binding();
    def late as int init 1700000000 + PENDING_TTL_SECONDS + 1;
    testing.assertFalse(pendingExpired($b, $late));
    $b.pending = true;
    testing.assertFalse(pendingExpired($b, 1700000000 + PENDING_TTL_SECONDS));
    testing.assertTrue(pendingExpired($b, $late));
}

# A token GitHub Actions would mint for a tag build of that repository.
func token() {
    def doc as json.Value init json.map();
    $doc = json.set($doc, "/iss", ISS);
    $doc = json.set($doc, "/aud", AUD);
    $doc = json.set($doc, "/repository_id", REPO_ID);
    $doc = json.set($doc, "/repository", "acme/deck-routeros");
    $doc = json.set($doc, "/job_workflow_ref", WORKFLOW + "@refs/tags/v0.1.0");
    $doc = json.set($doc, "/ref", "refs/tags/v0.1.0");
    return $doc;
}

func claims() {
    return claimsFrom(GITHUB, token());
}

func allowed(c as Claims) {
    return check(binding(), $c, AUD, ISS).allowed;
}

# --- the happy path -----------------------------------------------------------

func testAMatchingBuildIsAuthorised() {
    def v as Verdict init check(binding(), claims(), AUD, ISS);
    testing.assertTrue($v.allowed);
    testing.assertContains($v.reason, "acme/deck-routeros");
}

func testClaimsAreLiftedFromTheGithubShape() {
    def c as Claims init claims();
    testing.assertEqual($c.repositoryId, REPO_ID);
    testing.assertEqual($c.repository, "acme/deck-routeros");
    testing.assertEqual($c.ref, "refs/tags/v0.1.0");
    # the ref suffix is stripped, or every binding would name one tag
    testing.assertEqual($c.workflow, WORKFLOW);
}

func testANumericRepositoryIdIsReadAsText() {
    # the binding stores text; comparing 42 to "42" would never match
    def doc as json.Value init json.set(token(), "/repository_id", 123456789);
    testing.assertEqual(claimsFrom(GITHUB, $doc).repositoryId, REPO_ID);
}

# --- what must be refused -----------------------------------------------------

func testATokenForAnotherAudienceIsRefused() {
    # replay: a token minted for another service must not work here
    def c as Claims init claimsFrom(GITHUB, json.set(token(), "/aud", "some-other-service"));
    def v as Verdict init check(binding(), $c, AUD, ISS);
    testing.assertFalse($v.allowed);
    testing.assertContains($v.reason, "audience");
}

func testATokenForADifferentRegistryIsRefused() {
    # a valid token from the same issuer, for somebody else
    def c as Claims init claimsFrom(GITHUB, json.set(token(), "/aud", "registry.other.example"));
    testing.assertFalse(allowed($c));
}

func testAnUnconfiguredAudienceRefusesEverything() {
    # a missing audience must not read as "accept any"
    def v as Verdict init check(binding(), claims(), "", ISS);
    testing.assertFalse($v.allowed);
    testing.assertContains($v.reason, "no trusted-publishing audience");
}

func testAnUnconfiguredIssuerRefusesEverything() {
    def v as Verdict init check(binding(), claims(), AUD, "");
    testing.assertFalse($v.allowed);
    testing.assertContains($v.reason, "no issuer");
}

func testATokenFromAnotherIssuerIsRefused() {
    # a self-hosted Gitea signing its own tokens is not github.com
    def c as Claims init claimsFrom(GITHUB, json.set(token(), "/iss", "https://ci.evil.example"));
    testing.assertFalse(allowed($c));
}

func testAnotherRepositoryIsRefused() {
    def c as Claims init claimsFrom(GITHUB, json.set(token(), "/repository_id", "999"));
    def v as Verdict init check(binding(), $c, AUD, ISS);
    testing.assertFalse($v.allowed);
    testing.assertContains($v.reason, "not the one bound");
}

func testARenamedRepositoryStillPublishes() {
    # keyed on the id: the path changed, the project did not
    def doc as json.Value init json.set(token(), "/repository", "acme/deck-routeros-ng");
    $doc = json.set(
        $doc,
        "/job_workflow_ref",
        "acme/deck-routeros-ng/.github/workflows/publish.yml@refs/tags/v0.2.0");
    def b as Binding init binding();
    # the workflow claim carries the path, so a rename breaks a pinned workflow
    $b.workflow = "acme/deck-routeros-ng/.github/workflows/publish.yml";
    testing.assertTrue(check($b, claimsFrom(GITHUB, $doc), AUD, ISS).allowed);
}

func testWhoeverTakesTheFreedPathDoesNotInheritTheBinding() {
    # somebody registers the released path on a new repository, with a new id
    def doc as json.Value init json.set(token(), "/repository_id", "777777");
    testing.assertFalse(allowed(claimsFrom(GITHUB, $doc)));
}

func testAnEmptyRepositoryIdNeverMatches() {
    # an absent claim and an unconfigured binding must not authorise each other
    def doc as json.Value init json.map();
    $doc = json.set($doc, "/iss", ISS);
    $doc = json.set($doc, "/aud", AUD);
    $doc = json.set($doc, "/ref", "refs/tags/v1");
    def v as Verdict init check(binding(), claimsFrom(GITHUB, $doc), AUD, ISS);
    testing.assertFalse($v.allowed);
    testing.assertContains($v.reason, "no repository id");

    def blank as Binding init binding();
    $blank.repositoryId = "";
    testing.assertFalse(check($blank, claims(), AUD, ISS).allowed);
}

func testAnotherWorkflowInTheSameRepositoryIsRefused() {
    # a pull-request workflow in the same repository must not publish
    def doc as json.Value init json.set(
        token(),
        "/job_workflow_ref",
        "acme/deck-routeros/.github/workflows/pr.yml@refs/heads/main");
    def v as Verdict init check(binding(), claimsFrom(GITHUB, $doc), AUD, ISS);
    testing.assertFalse($v.allowed);
    testing.assertContains($v.reason, "workflow");
}

func testABranchBuildIsRefusedWhenTheBindingWantsTags() {
    def doc as json.Value init json.set(token(), "/ref", "refs/heads/main");
    def v as Verdict init check(binding(), claimsFrom(GITHUB, $doc), AUD, ISS);
    testing.assertFalse($v.allowed);
    testing.assertContains($v.reason, "does not match");
}

func testAProviderMismatchIsRefused() {
    def b as Binding init binding();
    $b.provider = GITLAB;
    testing.assertFalse(check($b, claims(), AUD, ISS).allowed);
}

func testAnUnknownProviderIsRefused() {
    def c as Claims init claimsFrom("jenkins", token());
    def v as Verdict init check(binding(), $c, AUD, ISS);
    testing.assertFalse($v.allowed);
    testing.assertContains($v.reason, "unknown CI provider");
}

# --- ref patterns -------------------------------------------------------------

func testRefPatterns() {
    testing.assertTrue(refMatches("refs/tags/v1.0.0", "refs/tags/v1.0.0"));
    testing.assertFalse(refMatches("refs/tags/v1.0.0", "refs/tags/v1.0.1"));
    testing.assertTrue(refMatches("refs/tags/*", "refs/tags/v1.0.0"));
    testing.assertFalse(refMatches("refs/tags/*", "refs/heads/main"));
    testing.assertTrue(refMatches("*", "anything"));
    # an empty pattern is the permissive default a binding should narrow
    testing.assertTrue(refMatches("", "refs/heads/main"));
}

func testAPrefixPatternDoesNotMatchASiblingPrefix() {
    # refs/tags/v1* must not admit refs/tags/v2
    testing.assertTrue(refMatches("refs/tags/v1*", "refs/tags/v1.5.0"));
    testing.assertFalse(refMatches("refs/tags/v1*", "refs/tags/v2.0.0"));
}

# --- other providers ----------------------------------------------------------

func testGitlabClaimNames() {
    def doc as json.Value init json.map();
    $doc = json.set($doc, "/iss", "https://gitlab.example");
    $doc = json.set($doc, "/aud", AUD);
    $doc = json.set($doc, "/project_id", "42");
    $doc = json.set($doc, "/project_path", "acme/routeros");
    $doc = json.set($doc, "/workflow_ref", "acme/routeros//.gitlab-ci.yml@refs/tags/v1");
    $doc = json.set($doc, "/ref", "refs/tags/v1");
    def c as Claims init claimsFrom(GITLAB, $doc);
    testing.assertEqual($c.repositoryId, "42");
    testing.assertEqual($c.repository, "acme/routeros");
}

func testGiteaNamesTheWorkflowPlainly() {
    def doc as json.Value init json.map();
    $doc = json.set($doc, "/repository_id", "7");
    $doc = json.set($doc, "/workflow", "publish.yml");
    testing.assertEqual(claimsFrom(GITEA, $doc).workflow, "publish.yml");
}

func testASelfHostedIssuerMustBeConfigured() {
    # an unset self-hosted issuer must refuse rather than accept any instance
    testing.assertEqual(expectedIssuer(GITHUB, ""), GITHUB_ISSUER);
    testing.assertEqual(expectedIssuer(GITEA, ""), "");
    testing.assertEqual(expectedIssuer(GITEA, "https://git.example"), "https://git.example");
    # a configured issuer overrides even for github, for GitHub Enterprise
    testing.assertEqual(expectedIssuer(GITHUB, "https://ghe.example"), "https://ghe.example");
}

func testWorkflowPathStripsTheRef() {
    testing.assertEqual(
        workflowPath("a/b/.github/workflows/p.yml@refs/tags/v1"),
        "a/b/.github/workflows/p.yml");
    testing.assertEqual(workflowPath("publish.yml"), "publish.yml");
}

func testTheDeckKeyIsFolded() {
    testing.assertEqual(keyFor("@Acme/Tool"), "@acme/tool");
}

# --- signature and expiry, against a real key set --------------------------

# segment is one unpadded base64url JWT segment.
func segment(raw as bytes) {
    return strings.replace(encoding.toText($raw, "base64-url"), "=", "");
}

# signedBy builds an RS256 token carrying `kid`, the way a CI issuer signs one.
# `jwt.sign` takes no header, and the key set picks its key by `kid`.
func signedBy(privatePem as bytes, claims as string) {
    def head as string init segment(convert.bytesFromString(
        '{"alg":"RS256","kid":"ci-1","typ":"JWT"}',
        "utf-8"));
    def body as string init segment(convert.bytesFromString($claims, "utf-8"));
    def input as string init $head + "." + $body;
    def signed as bytes init convert.bytesFromString($input, "utf-8");
    def sig as bytes init crypto.rsaSign($privatePem, $signed, "sha256");
    return $input + "." + segment($sig);
}

# keySetOf is the JWKS an issuer would publish for the key.
func keySetOf(privatePem as bytes) {
    def jwk as json.Value init json.decode(crypto.jwkPublic($privatePem));
    $jwk = json.set($jwk, "/kid", "ci-1");
    return '{"keys":[' + json.encode($jwk) + ']}';
}

func testATokenSignedByTheIssuerVerifies() {
    def key as bytes init crypto.rsaGenerateKey(2048);
    def exp as string init convert.toString(time.unix(time.utc()) + 300);
    def token as string init signedBy($key, '{"repository_id":"42","exp":' + $exp + '}');
    def c as Claims init verified($token, keySetOf($key), GITHUB);
    testing.assertEqual($c.repositoryId, "42");
}

func testATokenWithoutExpiryIsRefused() {
    # a token without exp never expires (RFC 7519) and must not publish
    def key as bytes init crypto.rsaGenerateKey(2048);
    def token as string init signedBy($key, '{"repository_id":"42"}');
    def message as string init "";
    try {
        verified($token, keySetOf($key), GITHUB);
    } catch (err) {
        $message = $err.message;
    }
    testing.assertContains($message, "exp");
}

func testATokenFromAnotherKeyIsRefused() {
    def key as bytes init crypto.rsaGenerateKey(2048);
    def exp as string init convert.toString(time.unix(time.utc()) + 300);
    def token as string init signedBy($key, '{"repository_id":"42","exp":' + $exp + '}');
    def threw as bool init false;
    try {
        verified($token, keySetOf(crypto.rsaGenerateKey(2048)), GITHUB);
    } catch (err) {
        $threw = true;
    }
    testing.assertTrue($threw);
}

func testDiscoveryUrlJoin() {
    testing.assertEqual(
        discoveryUrl("https://token.actions.githubusercontent.com"),
        "https://token.actions.githubusercontent.com/.well-known/openid-configuration");
    # a trailing slash must not produce a doubled one
    testing.assertEqual(
        discoveryUrl("https://git.example/"),
        "https://git.example/.well-known/openid-configuration");
    testing.assertEqual(
        discoveryUrl("  https://git.example//  "),
        "https://git.example/.well-known/openid-configuration");
}

func testGitlabBareRefsAreCompletedFromTheirType() {
    # a bare `v1` must not match `v*` as both tag and branch
    def doc as json.Value init json.map();
    $doc = json.set($doc, "/project_id", "42");
    $doc = json.set($doc, "/ref", "v1");
    $doc = json.set($doc, "/ref_type", "branch");
    testing.assertEqual(claimsFrom(GITLAB, $doc).ref, "refs/heads/v1");
    $doc = json.set($doc, "/ref_type", "tag");
    testing.assertEqual(claimsFrom(GITLAB, $doc).ref, "refs/tags/v1");
    $doc = json.set($doc, "/ref_type", "other");
    testing.assertFalse(refMatches("refs/tags/*", claimsFrom(GITLAB, $doc).ref));
}

func testTheRunMustHaveBuiltTheRelease() {
    def commit as string init "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293";
    def other as string init "0f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293";
    def c as Claims init claimsFrom(GITHUB, token());
    $c.sha = $commit;
    $c.ref = "refs/tags/v1.0.0";
    testing.assertTrue(matchesRelease($c, "v1.0.0", $commit, 1000).allowed);
    testing.assertFalse(matchesRelease($c, "v0.9.0", $commit, 1000).allowed);
    testing.assertFalse(matchesRelease($c, "v1.0.0", $other, 1000).allowed);
    # a branch run may publish a tag on the commit it built
    $c.ref = "refs/heads/main";
    testing.assertTrue(matchesRelease($c, "v1.0.0", $commit, 1000).allowed);
    $c.issuedAt = 2000;
    testing.assertFalse(matchesRelease($c, "v1.0.0", $commit, 1000).allowed);
}

func testAnIdentityTokenIsRecognisedByItsIssuer() {
    # 8.9: sent in place of a bearer token, routed by its unverified `iss`
    def key as bytes init crypto.rsaGenerateKey(2048);
    def token as string init signedBy($key, '{"iss":"https://ci.example","repository_id":"42"}');
    testing.assertTrue(isIdentityToken($token, "https://ci.example"));
    testing.assertFalse(isIdentityToken($token, "https://other.example"));
    testing.assertFalse(isIdentityToken($token, ""));
    testing.assertFalse(isIdentityToken("jvcp_abc", "https://ci.example"));
    testing.assertFalse(isIdentityToken("a.b", "https://ci.example"));
}
