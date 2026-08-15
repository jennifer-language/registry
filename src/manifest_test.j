# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for manifest.j. Run with:
#
#     jennifer test src/manifest_test.j
#
# This is the file a publish takes the deck's identity from, so the tests care
# most about what must be refused: anything that would put a name or a version
# into the store that a conforming client could not then install.

use testing;

func full() {
    return parse('name = "@acme/routeros"
version = "0.1.0"
description = "MikroTik RouterOS client"
license = "LGPL-3.0-only"
capabilities = ["net", "exec"]

[requires]
"@acme/net" = "^1.0.0"
"@acme/ansi" = "~2.3.0"

[engines]
jennifer = ">=0.24.0"
');
}

func testAFullManifestParses() {
    def m as Manifest init full();
    testing.assertTrue($m.ok);
    testing.assertEqual($m.name, "@acme/routeros");
    testing.assertEqual($m.version, "0.1.0");
    testing.assertEqual($m.description, "MikroTik RouterOS client");
    testing.assertEqual($m.license, "LGPL-3.0-only");
}

func testAScopedDependencyKeySurvives() {
    # the key holds a "/", which addresses a nested table unless escaped
    def m as Manifest init full();
    testing.assertEqual(len($m.requires), 2);
    testing.assertEqual($m.requires["@acme/net"], "^1.0.0");
    testing.assertEqual($m.requires["@acme/ansi"], "~2.3.0");
}

func testEnginesAndCapabilities() {
    def m as Manifest init full();
    testing.assertEqual($m.engines["jennifer"], ">=0.24.0");
    testing.assertEqual(len($m.capabilities), 2);
    testing.assertEqual($m.capabilities[0], "net");
}

func testTheMinimalManifestIsNameAndVersion() {
    def m as Manifest init parse('name = "@acme/tool"
version = "1.0.0"
');
    testing.assertTrue($m.ok);
    # absent tables are empty, not an error
    testing.assertEqual(len($m.requires), 0);
    testing.assertEqual(len($m.engines), 0);
    testing.assertEqual(len($m.capabilities), 0);
    testing.assertEqual($m.description, "");
}

func testTheNameIsFolded() {
    # so a repository declaring @Acme/Tool publishes to @acme/tool, and the scope
    # check runs against the folded form
    def m as Manifest init parse('name = "@Acme/Tool"
version = "1.0.0"
');
    testing.assertTrue($m.ok);
    testing.assertEqual($m.name, "@acme/tool");
}

# --- what must be refused -----------------------------------------------------

func testEmptyIsRefused() {
    testing.assertFalse(parse("").ok);
    testing.assertFalse(parse("   \n  ").ok);
}

func testMalformedTomlIsRefused() {
    def m as Manifest init parse("name = \nversion");
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "not valid TOML");
}

func testAMissingNameIsRefused() {
    def m as Manifest init parse("version = \"1.0.0\"\n");
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "no `name`");
}

func testAMissingVersionIsRefused() {
    def m as Manifest init parse("name = \"@acme/tool\"\n");
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "no `version`");
}

func testABareNameIsRefused() {
    # a bare name denotes a bundled module or a local file, and is not publishable
    def m as Manifest init parse('name = "routeros"
version = "1.0.0"
');
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "scoped");
}

func testANameOutsideTheGrammarIsRefused() {
    # a hyphen is legal in a scope and illegal in a deck name
    def m as Manifest init parse('name = "@acme/route-os"
version = "1.0.0"
');
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "not a valid deck name");
}

func testANonSemverVersionIsRefused() {
    def m as Manifest init parse('name = "@acme/tool"
version = "1.0"
');
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "not a valid version");
}

func testARefusalCarriesNoName() {
    # a caller that ignores `ok` must not find a usable name to check a scope
    # against; every field is zeroed on refusal
    def m as Manifest init parse('name = "routeros"
version = "1.0.0"
');
    testing.assertEqual($m.name, "");
    testing.assertEqual($m.version, "");
}

func testAPrereleaseVersionIsAccepted() {
    def m as Manifest init parse('name = "@acme/tool"
version = "1.0.0-beta.1"
');
    testing.assertTrue($m.ok);
    testing.assertEqual($m.version, "1.0.0-beta.1");
}
