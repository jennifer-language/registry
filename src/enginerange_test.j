# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for enginerange.j. Run with:
#
#     jennifer test src/enginerange_test.j

use testing;
use convert;

# Case is one admits() question and its answer.
def struct Case {
    range as string,
    version as string,
    want as bool
};

# labelled pairs an answer with the case it answers, so a failing row of a
# table names itself.
func labelled(label as string, answer as bool) {
    return $label + " -> " + convert.toString($answer);
}

func testTheTwoFormsAreValid() {
    def good as list of string init [
        ">=0.25.0",
        ">=0.25.0 <0.26.0",
        ">=0.0.0",
        ">=1.2.3 <1.2.4",
        ">=10.20.30 <11.0.0"
    ];
    for (def r in $good) {
        testing.assertEqual(labelled($r, isValidRange($r)), labelled($r, true));
    }
}

func testEverythingElseIsRefused() {
    def bad as list of string init [
        "",
        "*",
        "0.25.0",
        "^0.25.0",
        "~0.25.0",
        ">0.25.0",
        "<0.26.0",
        "<=0.26.0",
        ">=0.25",
        ">=0.25.0-rc.1",
        ">=0.25.0+b",
        ">=v0.25.0",
        ">=00.25.0",
        ">= 0.25.0",
        " >=0.25.0",
        ">=0.25.0 ",
        ">=0.25.0  <0.26.0",
        ">=0.25.0 <0.26.0 ",
        ">=0.25.0 <=0.26.0",
        ">=0.25.0 >0.26.0",
        ">=0.25.0 <0.26",
        ">=0.25.0 <0.26.0 <0.27.0",
        ">=0.25.0 || >=0.27.0",
        ">=0.25.0,<0.26.0",
        ">=0.25.0 <0.26.0-dev",
        ">=1.0.0 <1.0.0",
        ">=1.0.0 <0.9.0",
        ">=1234567890123456789.0.0"
    ];
    for (def r in $bad) {
        testing.assertEqual(labelled($r, isValidRange($r)), labelled($r, false));
    }
}

func testARefusalSaysWhy() {
    testing.assertContains(parse("^0.25.0").problem, "starts with a \">=\" floor");
    testing.assertContains(parse(">=0.25.0 <=0.26.0").problem, "exclusive bound");
    testing.assertContains(parse(">=0.26.0 <0.26.0").problem, "not above the floor 0.26.0");
    testing.assertContains(parse(">=0.26 <0.27.0").problem, "plain X.Y.Z");
    testing.assertContains(parse(">=0.25.0  <0.26.0").problem, "one space");
}

func testParseSplitsTheBounds() {
    def r as Range init parse(">=0.25.0 <0.26.0");
    testing.assertTrue($r.ok);
    testing.assertEqual($r.floor, "0.25.0");
    testing.assertEqual($r.upper, "0.26.0");
    testing.assertEqual(parse(">=0.25.0").upper, "");
}

func testAdmitsTable() {
    def cases as list of Case init [
        # Release builds: floor <= v < upper, by the X.Y.Z core.
        Case{range: ">=0.25.0", version: "0.25.0", want: true},
        Case{range: ">=0.25.0", version: "0.24.9", want: false},
        Case{range: ">=0.25.0", version: "1.0.0", want: true},
        Case{range: ">=0.25.0 <0.26.0", version: "0.25.0", want: true},
        Case{range: ">=0.25.0 <0.26.0", version: "0.25.17", want: true},
        Case{range: ">=0.25.0 <0.26.0", version: "0.26.0", want: false},
        Case{range: ">=0.25.0 <0.26.0", version: "0.24.99", want: false},
        Case{range: ">=0.25.0 <0.26.0", version: "1.0.0", want: false},
        # Numeric, not text, order.
        Case{range: ">=0.9.0 <0.10.0", version: "0.10.0", want: false},
        Case{range: ">=0.9.0 <0.10.0", version: "0.9.10", want: true},
        Case{range: ">=0.9.0", version: "0.10.0", want: true},
        # A release candidate or build metadata is judged by its core.
        Case{range: ">=0.25.0 <0.26.0", version: "0.26.0-rc.1", want: false},
        Case{range: ">=0.26.0", version: "0.26.0-rc.1", want: true},
        Case{range: ">=0.25.0 <0.26.0", version: "0.25.1+build.5", want: true},
        # Development builds pass every floor and fail every upper bound.
        Case{range: ">=9.0.0", version: "0.25.0-dev+131.afd9207", want: true},
        Case{range: ">=0.25.0", version: "dev", want: true},
        Case{range: ">=0.25.0 <0.26.0", version: "0.25.0-dev+131.afd9207", want: false},
        Case{range: ">=0.25.0 <9.0.0", version: "0.25.0-dev+1", want: false},
        Case{range: ">=0.25.0 <0.26.0", version: "dev", want: false},
        # A malformed range admits nothing; nor does an unreadable version.
        Case{range: "^0.25.0", version: "0.25.0", want: false},
        Case{range: ">=0.26.0 <0.26.0", version: "dev", want: false},
        Case{range: ">=0.25.0", version: "", want: false},
        Case{range: ">=0.25.0", version: "unknown", want: false}
    ];
    for (def c in $cases) {
        def label as string init $c.range + " / " + $c.version;
        testing.assertEqual(
            labelled($label, admits($c.range, $c.version)),
            labelled($label, $c.want));
    }
}

func testDevBuildsAndKnownVersions() {
    testing.assertTrue(isDevBuild("dev"));
    testing.assertTrue(isDevBuild("0.25.0-dev+131.afd9207"));
    testing.assertFalse(isDevBuild("0.26.0-rc.1"));
    testing.assertFalse(isDevBuild("0.26.0"));
    testing.assertTrue(isKnownVersion("dev"));
    testing.assertTrue(isKnownVersion("0.26.0-rc.1"));
    testing.assertFalse(isKnownVersion(""));
    testing.assertFalse(isKnownVersion("unknown"));
    testing.assertFalse(isKnownVersion("0.26"));
}

func testEngineKeys() {
    testing.assertTrue(isEngineKey("jennifer"));
    testing.assertTrue(isEngineKey("Jennifer-Tiny"));
    testing.assertFalse(isEngineKey("node"));
}

func testRunsOn() {
    def none as map of string to string init {};
    # Old data with no engines is eligible everywhere.
    testing.assertTrue(runsOn($none, "jennifer", "0.26.0"));
    def capped as map of string to string init {"jennifer": ">=0.25.0 <0.26.0"};
    testing.assertTrue(runsOn($capped, "jennifer", "0.25.4"));
    testing.assertFalse(runsOn($capped, "jennifer", "0.26.0"));
    testing.assertFalse(runsOn($capped, "jennifer", "0.26.0-dev+1"));
    # The keys are an allowlist; a key is matched without case.
    testing.assertFalse(runsOn($capped, "jennifer-tiny", "0.25.4"));
    testing.assertTrue(runsOn({"Jennifer": ">=0.25.0"}, "jennifer", "0.25.4"));
    # An unknown version is judged by the list alone.
    testing.assertTrue(runsOn($capped, "jennifer", ""));
    testing.assertFalse(runsOn($capped, "jennifer-tiny", ""));
    testing.assertEqual(rangeFor($capped, "JENNIFER"), ">=0.25.0 <0.26.0");
    testing.assertEqual(rangeFor($capped, "jennifer-tiny"), "");
}
