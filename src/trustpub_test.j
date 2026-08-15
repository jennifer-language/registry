# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for trustpub.j. Run with:
#
#     jennifer test src/trustpub_test.j
#
# This module decides whether an unauthenticated HTTP request may write to the
# registry, so the tests are weighted toward what must be **refused**. Every
# check in `check` has a test that removes it and shows the refusal, because a
# check that silently stops working is indistinguishable from one that never
# existed.

use testing;
use json;

def const AUD as string init "jennifer-registry";
def const ISS as string init "https://token.actions.githubusercontent.com";
def const REPO_ID as string init "123456789";
def const WORKFLOW as string init "acme/deck-routeros/.github/workflows/publish.yml";

# A binding as `deckadmin trust add` would record it.
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
    # the replay case: CI hands its token to whatever action asks, and a token
    # minted for another service must not work here
    def c as Claims init claimsFrom(GITHUB, json.set(token(), "/aud", "some-other-service"));
    def v as Verdict init check(binding(), $c, AUD, ISS);
    testing.assertFalse($v.allowed);
    testing.assertContains($v.reason, "audience");
}

func testATokenForADifferentRegistryIsRefused() {
    # the same shape, the same issuer, a real token - for somebody else
    def c as Claims init claimsFrom(GITHUB, json.set(token(), "/aud", "registry.other.example"));
    testing.assertFalse(allowed($c));
}

func testAnUnconfiguredAudienceRefusesEverything() {
    # a missing audience must not read as "accept any": that would turn every
    # CI token on the internet into a credential for this registry
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
    # the point of keying on the id: the path changed, the project did not
    def doc as json.Value init json.set(token(), "/repository", "acme/deck-routeros-ng");
    $doc = json.set($doc, "/job_workflow_ref",
        "acme/deck-routeros-ng/.github/workflows/publish.yml@refs/tags/v0.2.0");
    def b as Binding init binding();
    # the workflow claim carries the path too, so a rename changes it; a binding
    # that pins the workflow must be updated, which is the documented cost
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
    # a pull-request workflow in the same repository must not publish; that is
    # the difference between "this project" and "any code a contributor proposes"
    def doc as json.Value init json.set(token(), "/job_workflow_ref",
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
    # github.com is a constant; anything self-hosted is not guessable, and an
    # unguessable issuer left unset must refuse rather than accept any instance
    testing.assertEqual(expectedIssuer(GITHUB, ""), GITHUB_ISSUER);
    testing.assertEqual(expectedIssuer(GITEA, ""), "");
    testing.assertEqual(expectedIssuer(GITEA, "https://git.example"), "https://git.example");
    # a configured issuer overrides even for github, for GitHub Enterprise
    testing.assertEqual(expectedIssuer(GITHUB, "https://ghe.example"), "https://ghe.example");
}

func testWorkflowPathStripsTheRef() {
    testing.assertEqual(workflowPath("a/b/.github/workflows/p.yml@refs/tags/v1"),
        "a/b/.github/workflows/p.yml");
    testing.assertEqual(workflowPath("publish.yml"), "publish.yml");
}

func testTheDeckKeyIsFolded() {
    testing.assertEqual(keyFor("@Acme/Tool"), "@acme/tool");
}

func testDiscoveryUrlJoin() {
    testing.assertEqual(discoveryUrl("https://token.actions.githubusercontent.com"),
        "https://token.actions.githubusercontent.com/.well-known/openid-configuration");
    # a trailing slash must not produce a doubled one
    testing.assertEqual(discoveryUrl("https://git.example/"),
        "https://git.example/.well-known/openid-configuration");
    testing.assertEqual(discoveryUrl("  https://git.example//  "),
        "https://git.example/.well-known/openid-configuration");
}
