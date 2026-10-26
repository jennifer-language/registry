# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for manifest.j. Run with:
#
#     jennifer test src/manifest_test.j
#
# Most tests cover refusals: names or versions a conforming client could not
# install.

use testing;

func full() {
    # the specification's appendix, verbatim, plus a license
    return parse('[package]
name = "@acme/routeros"
version = "0.1.0"
description = "MikroTik RouterOS client"
license = "LGPL-3.0-only"
capabilities = ["net", "exec"]

[engines]
jennifer = ">=0.24.0"

[decks]
"@acme/net" = "^1.0.0"
"@acme/ansi" = "~2.3.0"
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
    def m as Manifest init parse('[package]
name = "@acme/tool"
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
    # the scope check runs against the folded form
    def m as Manifest init parse('[package]
name = "@Acme/Tool"
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
    def m as Manifest init parse("[package]\nversion = \"1.0.0\"\n");
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "no `name` under [package]");
}

func testAMissingVersionIsRefused() {
    def m as Manifest init parse("[package]\nname = \"@acme/tool\"\n");
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "no `version` under [package]");
}

func testABareNameIsRefused() {
    # a bare name denotes a bundled module or a local file, and is not publishable
    def m as Manifest init parse('[package]
name = "routeros"
version = "1.0.0"
');
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "scoped");
}

func testANameOutsideTheGrammarIsRefused() {
    # a hyphen is legal in a scope and illegal in a deck name
    def m as Manifest init parse('[package]
name = "@acme/route-os"
version = "1.0.0"
');
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "not a valid deck name");
}

func testANonSemverVersionIsRefused() {
    def m as Manifest init parse('[package]
name = "@acme/tool"
version = "1.0"
');
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "not a valid version");
}

func testARefusalCarriesNoName() {
    # every field is zeroed, so a caller ignoring `ok` has no name to check
    def m as Manifest init parse('[package]
name = "routeros"
version = "1.0.0"
');
    testing.assertEqual($m.name, "");
    testing.assertEqual($m.version, "");
}

func testAPrereleaseVersionIsAccepted() {
    def m as Manifest init parse('[package]
name = "@acme/tool"
version = "1.0.0-beta.1"
');
    testing.assertTrue($m.ok);
    testing.assertEqual($m.version, "1.0.0-beta.1");
}

# --- what a manifest may not say ------------------------------------------------

func withBody(extra as string) {
    return '[package]
name = "@acme/tool"
version = "1.0.0"
' + $extra;
}

func testAVersionTooLargeToOrderIsRefused() {
    # valid SemVer, but it would throw in every listing that sorted it
    def m as Manifest init parse('[package]
name = "@acme/tool"
version = "99999999999999999999.0.0"
');
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "18 digits");
}

func testADependencyConstraintMustBeInTheGrammar() {
    def m as Manifest init parse(withBody('[decks]
"@acme/net" = "~>1.2"
'));
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "not a valid version constraint");
}

func testAnEmptyDependencyConstraintIsRefused() {
    def m as Manifest init parse(withBody('[decks]
"@acme/net" = ""
'));
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "empty version constraint for @acme/net");
    testing.assertContains($m.error, "write \"*\"");
}

func testABlankEngineConstraintIsRefused() {
    def m as Manifest init parse(withBody('[engines]
jennifer = "  "
'));
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "empty version constraint for jennifer");
}

func testAWildcardDependencyStillParses() {
    def m as Manifest init parse(withBody('[decks]
"@acme/net" = "*"
'));
    testing.assertTrue($m.ok);
    testing.assertEqual($m.requires["@acme/net"], "*");
}

func testADependencyMustBeAScopedDeckName() {
    def m as Manifest init parse(withBody('[decks]
"not a name!" = "^1"
'));
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "not a deck name");
}

func testOneDependencyUnderTwoSpellingsIsRefused() {
    # names fold, so these would be one deck required at two versions
    def m as Manifest init parse(withBody('[decks]
"@acme/net" = "^1"
"@ACME/Net" = "^2"
'));
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "two spellings");
}

func testDependencyNamesAreFolded() {
    def m as Manifest init parse(withBody('[decks]
"@ACME/Net" = "^1"
'));
    testing.assertTrue($m.ok);
    testing.assertTrue(maps.has($m.requires, "@acme/net"));
}

func testAWrongTypeIsAnErrorNotACrash() {
    # guards against `parse` throwing, which failed a publish with no message
    def name as Manifest init parse('[package]
name = 5
version = "1.0.0"
');
    testing.assertFalse($name.ok);
    testing.assertContains($name.error, "must be a string");
    def dep as Manifest init parse(withBody('[decks]
"@acme/net" = 1
'));
    testing.assertFalse($dep.ok);
    testing.assertContains($dep.error, "in quotes");
    def caps as Manifest init parse(withBody('capabilities = ["net", 1]
'));
    testing.assertFalse($caps.ok);
}

func testABadKeywordNeverFailsAPublish() {
    def m as Manifest init parse(withBody('keywords = ["net", 1, "router"]
'));
    testing.assertTrue($m.ok);
    testing.assertEqual(len($m.keywords), 2);
}

# --- limits ---------------------------------------------------------------------

func testADeckCannotRequireItself() {
    def m as Manifest init parse(withBody('[decks]
"@ACME/Tool" = "^1"
'));
    testing.assertFalse($m.ok);
    testing.assertContains($m.error, "cannot require itself");
}

func testLongTextFieldsAreRefused() {
    def long as string init strings.repeat("x", MAX_DESCRIPTION + 1);
    def d as Manifest init parse(withBody('description = "' + $long + '"
'));
    testing.assertFalse($d.ok);
    testing.assertContains($d.error, "description");
    def l as Manifest init parse(withBody('license = "' + strings.repeat("A", MAX_LICENSE + 1) +
        '"
'));
    testing.assertFalse($l.ok);
    testing.assertContains($l.error, "license");
    testing.assertTrue(parse(withBody('description = "' + strings.repeat("x", MAX_DESCRIPTION) +
        '"
')).ok);
}

func testCapabilitiesAreNamesAndFew() {
    testing.assertTrue(parse(withBody('capabilities = ["net", "exec", "sql"]
')).ok);
    def odd as Manifest init parse(withBody('capabilities = ["Net Work"]
'));
    testing.assertFalse($odd.ok);
    testing.assertContains($odd.error, "capability");
    def many as list of string init [];
    for (def i in 0..MAX_CAPABILITIES + 1) {
        $many[] = '"cap' + convert.toString($i) + '"';
    }
    def too as Manifest init parse(withBody('capabilities = [' + strings.join($many, ", ") + ']
'));
    testing.assertFalse($too.ok);
    testing.assertContains($too.error, "more than");
}

func testEngineKeysAreNamesAndFew() {
    def odd as Manifest init parse(withBody('[engines]
"../weird" = ">=1"
'));
    testing.assertFalse($odd.ok);
    testing.assertContains($odd.error, "engine name");
    def lines as list of string init [];
    for (def i in 0..MAX_ENGINES + 1) {
        $lines[] = 'engine' + convert.toString($i) + ' = ">=1"';
    }
    def too as Manifest init parse(withBody('[engines]
' + strings.join($lines, "\n") + '
'));
    testing.assertFalse($too.ok);
    testing.assertContains($too.error, "more than");
}

func testTooManyDependenciesAreRefused() {
    def lines as list of string init [];
    for (def i in 0..MAX_REQUIRES + 1) {
        $lines[] = '"@acme/dep' + convert.toString($i) + '" = "^1"';
    }
    def too as Manifest init parse(withBody('[decks]
' + strings.join($lines, "\n") + '
'));
    testing.assertFalse($too.ok);
    testing.assertContains($too.error, "more than");
}

func testNameOfReadsTheNameFromABrokenManifest() {
    testing.assertEqual(nameOf(withBody('[decks]
"@acme/net" = "~>1"
')), "@acme/tool");
    testing.assertEqual(nameOf("name = \nbroken"), "");
    testing.assertEqual(nameOf('[package]
name = "bare"
'), "");
    testing.assertEqual(nameOf('[package]
name = 5
'), "");
}
