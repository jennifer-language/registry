# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * White-box overlay for `stats.j`.
 * @module stats_test
 */

use testing;
use json;

# 2026-08-17T19:20:00Z. Fixed, because every window here is relative to "now"
# and a test that read the clock would change what it asserts twice a day.
def const NOW as int init 1786994400;
# 2026-08-17T23:50:00Z and 2026-08-18T00:10:00Z, twenty minutes apart across a
# day boundary: the case that decides whether a hit is attributed to when it
# happened or to when it was written down.
def const LATE as int init 1787010600;
def const JUST_AFTER as int init 1787011800;

func hitAt(unix as int, n as int) {
    return applyHit(json.map(), hourKey($unix), $n);
}

# --- bucket keys -------------------------------------------------------------

func testTheKeysAreUtcAndSortable() {
    testing.assertEqual(hourKey(NOW), "2026-08-17T19");
    testing.assertEqual(dayKey(NOW), "2026-08-17");
    testing.assertEqual(monthKey(NOW), "2026-08");
}

func testADayAndMonthComeFromTheHourNotTheClock() {
    # the whole point of deriving them: a flush that runs after midnight must
    # still file a 23:xx lookup under the day it happened on
    testing.assertEqual(dayOfHour("2026-08-17T23"), "2026-08-17");
    testing.assertEqual(monthOfHour("2026-08-17T23"), "2026-08");
}

func testAMalformedHourKeyIsRejectedRatherThanTruncated() {
    testing.assertEqual(dayOfHour("2026-08"), "");
    testing.assertEqual(monthOfHour(""), "");
}

# --- recording ---------------------------------------------------------------

func testAHitLandsInAllFourBuckets() {
    def rec as json.Value init hitAt(NOW, 1);
    testing.assertEqual(json.asInt($rec, "/hours/2026-08-17T19"), 1);
    testing.assertEqual(json.asInt($rec, "/days/2026-08-17"), 1);
    testing.assertEqual(json.asInt($rec, "/months/2026-08"), 1);
    testing.assertEqual(json.asInt($rec, "/total"), 1);
}

func testHitsAccumulate() {
    def rec as json.Value init hitAt(NOW, 3);
    $rec = applyHit($rec, hourKey(NOW), 4);
    testing.assertEqual(json.asInt($rec, "/hours/2026-08-17T19"), 7);
    testing.assertEqual(json.asInt($rec, "/total"), 7);
}

func testALateHitIsFiledUnderTheDayItHappenedOn() {
    # recorded at 23:50, flushed at 00:10 the next day: the flush passes the hour
    # key from when the lookup happened, so the day bucket must not follow the
    # flush. Getting this wrong misfiles traffic every single night.
    def rec as json.Value init hitAt(LATE, 1);
    $rec = applyHit($rec, hourKey(JUST_AFTER), 1);
    testing.assertEqual(json.asInt($rec, "/days/2026-08-17"), 1);
    testing.assertEqual(json.asInt($rec, "/days/2026-08-18"), 1);
}

func testAZeroOrNegativeHitIsANoOp() {
    # the flusher subtracts what it wrote, so it can legitimately observe zero
    testing.assertTrue(isEmpty(applyHit(json.map(), hourKey(NOW), 0)));
    testing.assertTrue(isEmpty(applyHit(json.map(), hourKey(NOW), -5)));
}

func testAMalformedHourKeyRecordsNothing() {
    testing.assertTrue(isEmpty(applyHit(json.map(), "not-an-hour", 9)));
}

# --- windows -----------------------------------------------------------------

func testAFreshRecordSummarisesAsZero() {
    def c as Counts init summarise(json.map(), NOW);
    testing.assertEqual($c.total, 0);
    testing.assertEqual($c.today, 0);
    testing.assertEqual($c.last12Months, 0);
}

func testEachWindowCountsItsOwnBucket() {
    def rec as json.Value init hitAt(NOW, 5);
    def c as Counts init summarise($rec, NOW);
    testing.assertEqual($c.thisHour, 5);
    testing.assertEqual($c.today, 5);
    testing.assertEqual($c.last7Days, 5);
    testing.assertEqual($c.last30Days, 5);
    testing.assertEqual($c.last12Months, 5);
    testing.assertEqual($c.total, 5);
}

func testAnOlderHitLeavesTheShorterWindows() {
    # 10 days ago: out of the 7-day window, still inside 30 days
    def rec as json.Value init hitAt(NOW - (10 * 86400), 4);
    def c as Counts init summarise($rec, NOW);
    testing.assertEqual($c.thisHour, 0);
    testing.assertEqual($c.today, 0);
    testing.assertEqual($c.last7Days, 0);
    testing.assertEqual($c.last30Days, 4);
    testing.assertEqual($c.total, 4);
}

func testTotalOutlivesEveryWindow() {
    # two years back: outside every window, and still counted in the lifetime
    # number, which is the one thing that must never fall
    def rec as json.Value init hitAt(NOW - (730 * 86400), 6);
    def c as Counts init summarise($rec, NOW);
    testing.assertEqual($c.last12Months, 0);
    testing.assertEqual($c.total, 6);
}

func testTheMonthWindowWalksTheCalendarNotThirtyDays() {
    # counting back 12 months from August 2026 must reach September 2025 and
    # stop; stepping 30 days at a time would skip a month and reach October
    def months as list of string init recentMonths(NOW, 12);
    testing.assertEqual(len($months), 12);
    testing.assertEqual($months[0], "2026-08");
    testing.assertEqual($months[11], "2025-09");
}

func testTheMonthWindowCrossesAYearBoundary() {
    # from January, the previous bucket is the previous December
    def months as list of string init recentMonths(1768478400, 3);
    testing.assertEqual($months[0], "2026-01");
    testing.assertEqual($months[1], "2025-12");
    testing.assertEqual($months[2], "2025-11");
}

func testTheDayWindowIsInclusiveOfToday() {
    def days as list of string init recentDays(NOW, 7);
    testing.assertEqual(len($days), 7);
    testing.assertEqual($days[0], "2026-08-17");
    testing.assertEqual($days[6], "2026-08-11");
}

# --- pruning -----------------------------------------------------------------

func testPruningDropsBucketsOutsideTheWindows() {
    def rec as json.Value init hitAt(NOW - (400 * 86400), 3);
    $rec = applyHit($rec, hourKey(NOW), 2);
    def out as json.Value init prune($rec, NOW);
    testing.assertTrue(json.has($out, "/days/2026-08-17"));
    testing.assertFalse(json.has($out, "/days/2025-07-13"));
}

func testPruningNeverTouchesTheTotal() {
    # the lifetime number cannot be recomputed once its buckets are gone, so
    # pruning it would silently rewrite history
    def rec as json.Value init hitAt(NOW - (400 * 86400), 3);
    def out as json.Value init prune($rec, NOW);
    testing.assertEqual(json.asInt($out, "/total"), 3);
    testing.assertEqual(summarise($out, NOW).total, 3);
}

func testPruningIsIdempotent() {
    def rec as json.Value init hitAt(NOW, 2);
    def once as json.Value init prune($rec, NOW);
    def twice as json.Value init prune($once, NOW);
    testing.assertEqual(summarise($twice, NOW).today, 2);
    testing.assertEqual(summarise($twice, NOW).total, 2);
}

func testAnHourSurvivesLongEnoughToCrossAFlush() {
    # KEEP_HOURS is two days precisely so "this hour" stays answerable across a
    # restart; an hour from yesterday evening must still be there
    def rec as json.Value init hitAt(NOW - (20 * 3600), 1);
    def out as json.Value init prune($rec, NOW);
    testing.assertTrue(json.has($out, "/hours/" + hourKey(NOW - (20 * 3600))));
}

# --- what the flusher does ---------------------------------------------------

func testRecordAppliesAndPrunesInOnePass() {
    def rec as json.Value init record(json.map(), hourKey(NOW), 9, NOW);
    testing.assertEqual(summarise($rec, NOW).thisHour, 9);
    testing.assertEqual(summarise($rec, NOW).total, 9);
}

func testRecordKeepsALateHourAcrossTheDayBoundary() {
    # the flush at 00:10 records the 23:xx hour, and pruning as of 00:10 must not
    # throw away the bucket it just wrote
    def rec as json.Value init record(json.map(), hourKey(LATE), 2, JUST_AFTER);
    testing.assertEqual(json.asInt($rec, "/hours/2026-08-17T23"), 2);
    testing.assertEqual(json.asInt($rec, "/days/2026-08-17"), 2);
}
