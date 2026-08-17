# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for certs.j. Run with:
#
#     jennifer test src/certs_test.j
#
# The ACME conversation needs a CA and is not tested here. Everything that
# *decides* is, because those are the parts that go wrong quietly: a renewal that
# never fires leaves a dead certificate, one that fires every boot meets a rate
# limit, and a path built from a hostile name writes outside its directory.

use testing;
use fs;

def const NOW as int init 1700000000;
def const DAY as int init 86400;

func tls() {
    def cfg as config.Config init config.defaults();
    def out as config.Tls init $cfg.tls;
    $out.certDir = "data/tls";
    $out.challengeDir = "data/acme-challenge";
    $out.renewBeforeDays = 30;
    return $out;
}

# --- renewal timing -----------------------------------------------------------

func testNothingStoredIsAlwaysDue() {
    testing.assertTrue(dueForRenewal(tls(), 0, NOW));
}

func testAFreshCertificateIsNotDue() {
    testing.assertFalse(dueForRenewal(tls(), NOW - DAY, NOW));
}

func testRenewalFiresAtLifetimeMinusTheWindow() {
    # 90 day lifetime, renew 30 days early, so it is due after 60
    testing.assertFalse(dueForRenewal(tls(), NOW - (59 * DAY), NOW));
    testing.assertTrue(dueForRenewal(tls(), NOW - (60 * DAY), NOW));
    testing.assertTrue(dueForRenewal(tls(), NOW - (89 * DAY), NOW));
}

func testAWindowWiderThanTheLifetimeStillLeavesADay() {
    # otherwise every boot renews, which is the fastest way to a rate limit
    def wide as config.Tls init tls();
    $wide.renewBeforeDays = 200;
    testing.assertFalse(dueForRenewal($wide, NOW - 3600, NOW));
    testing.assertTrue(dueForRenewal($wide, NOW - (2 * DAY), NOW));
}

func testACertificateFromTheFutureIsDue() {
    # a clock that moved backwards or a restored backup; trusting a timestamp we
    # can prove wrong is worse than renewing early
    testing.assertTrue(dueForRenewal(tls(), NOW + DAY, NOW));
}

# --- paths --------------------------------------------------------------------

func testPathsAreUnderTheDomainDirectory() {
    def p as list of string init pathsFor(tls(), "registry.example.com");
    testing.assertEqual($p[0], "data/tls/registry.example.com/cert.pem");
    testing.assertEqual($p[1], "data/tls/registry.example.com/key.pem");
    testing.assertEqual($p[2], "data/tls/registry.example.com/issued");
}

func testTheAccountKeyIsPerDeploymentNotPerDomain() {
    # an ACME account is the deployment's identity to the CA; one per domain
    # would register a new account on every domain added
    testing.assertEqual(accountKeyPath(tls()), "data/tls/account.key");
}

func testADomainCannotEscapeTheCertificateDirectory() {
    # a configured domain is operator input that becomes a filesystem path
    def p as list of string init pathsFor(tls(), "../../etc/evil");
    testing.assertFalse(strings.contains($p[0], ".."));
    testing.assertContains($p[0], "data/tls/");
}

func testADomainIsFolded() {
    testing.assertEqual(dirFor(tls(), "Registry.Example.COM"),
        "data/tls/registry.example.com");
}

func testAChallengeTokenCannotEscapeItsDirectory() {
    # the token comes from the CA and lands in a path; a CA would not send a
    # hostile one, but that is not a property worth depending on
    def p as string init challengePath(tls(), "../../../etc/passwd");
    testing.assertFalse(strings.contains($p, ".."));
    testing.assertContains($p, "data/acme-challenge/");
}

func testAnOrdinaryTokenSurvivesIntact() {
    # the filter must not mangle a real token, or the CA looks for a file that
    # is not there
    def token as string init "abc123-XYZ_token";
    testing.assertEqual(challengePath(tls(), $token),
        "data/acme-challenge/abc123-XYZ_token");
}

func testATokenKeepsItsCase() {
    # an ACME token is base64url and case is significant; folding it would let
    # two distinct tokens collide on one file, and the second challenge would be
    # answered with the first one's response
    testing.assertFalse(challengePath(tls(), "AbC") == challengePath(tls(), "abc"));
}

# --- storage ------------------------------------------------------------------

func testSaveAndLoadRoundTrip() {
    def dir as string init fs.makeTempDir("", "jvc-certs");
    def cfg as config.Tls init tls();
    $cfg.certDir = $dir + "/tls";
    save($cfg, "example.test", "CERTPEM", "KEYPEM", NOW);
    testing.assertTrue(hasBundle($cfg, "example.test"));
    def b as Bundle init load($cfg, "example.test");
    testing.assertEqual($b.cert, "CERTPEM");
    testing.assertEqual($b.key, "KEYPEM");
    testing.assertEqual($b.issuedAt, NOW);
    # and the freshly written certificate is not immediately due again
    testing.assertFalse(dueForRenewal($cfg, issuedAt($cfg, "example.test"), NOW));
    fs.removeAll($dir);
}

func testTheKeyIsNotWorldReadable() {
    def dir as string init fs.makeTempDir("", "jvc-certs");
    def cfg as config.Tls init tls();
    $cfg.certDir = $dir + "/tls";
    save($cfg, "example.test", "CERTPEM", "KEYPEM", NOW);
    def st as fs.Stat init fs.stat(pathsFor($cfg, "example.test")[1]);
    testing.assertEqual($st.mode, 0o600);
    fs.removeAll($dir);
}

func testNothingStoredReadsAsAbsent() {
    def cfg as config.Tls init tls();
    $cfg.certDir = "/no/such/certs";
    testing.assertFalse(hasBundle($cfg, "example.test"));
    testing.assertEqual(issuedAt($cfg, "example.test"), 0);
}

func testADomainOfDotsCannotAddressItsParent() {
    # the character filter alone admits `..`, and a name of exactly `..` would
    # resolve to the directory above the certificate store
    testing.assertEqual(dirFor(tls(), ".."), "data/tls/__");
    testing.assertEqual(dirFor(tls(), "."), "data/tls/_");
    testing.assertEqual(dirFor(tls(), "..."), "data/tls/__.");
    testing.assertEqual(dirFor(tls(), ""), "data/tls/_");
}
