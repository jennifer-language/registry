# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Per-deck lookup counts, as pure functions over a JSON record.
 *
 * These are not downloads. The registry indexes and does not host
 * (specification 6), so it never sees a deck's code being fetched. It counts
 * clients asking where a deck is (`GET /deck`, `/decks/:name`, `/resolve`),
 * which the page labels "resolutions":
 *
 * - **Undercounts installs.** A lockfile carries the pin, so reinstalling needs
 *   no registry call.
 * - **Overcounts people.** A CI fleet resolving on every build is one user
 *   producing hundreds of lookups.
 *
 * The record is three bucket sets and a total; everything else is derived:
 *
 * ```json
 * { "hours": {"2026-08-17T19": 3}, "days": {"2026-08-17": 12},
 *   "months": {"2026-08": 40}, "total": 40 }
 * ```
 *
 * The retention windows cap a record at a few dozen integers regardless of
 * traffic. Three resolutions give hourly detail for "this hour" and a year of
 * reach without 365 daily numbers.
 * @module stats
 * @example
 * import "./stats.j" as stats;
 * def rec as json.Value init stats.applyHit(json.map(), stats.hourKey($now), 1);
 * def c as stats.Counts init stats.summarise($rec, $now);
 */

use json;
use time;
use convert;
use strings;

/**
 * How many buckets of each resolution are kept; older ones are pruned on the
 * next write.
 *
 * Hours cover two days so "this hour" survives a restart and a flush landing
 * past midnight. Days and months outlive the 30-day and 12-month windows they
 * feed, so each window is complete on its oldest bucket.
 */
export def const KEEP_HOURS as int init 48;
export def const KEEP_DAYS as int init 62;
export def const KEEP_MONTHS as int init 24;

def const SECONDS_PER_HOUR as int init 3600;
def const SECONDS_PER_DAY as int init 86400;

/**
 * A deck's counts, summarised for display.
 *
 * Short windows are calendar-anchored ("today"), long ones rolling ("the last
 * 30 days"); a calendar "this month" would read as a traffic collapse on the
 * 1st.
 * @field thisHour {int} lookups in the current clock hour, UTC
 * @field today {int} lookups so far today, UTC
 * @field last7Days {int} lookups in the last 7 day-buckets including today
 * @field last30Days {int} lookups in the last 30 day-buckets including today
 * @field last12Months {int} lookups in the last 12 month-buckets including this one
 * @field total {int} every lookup ever counted for this deck
 */
export def struct Counts {
    thisHour as int,
    today as int,
    last7Days as int,
    last30Days as int,
    last12Months as int,
    total as int
};

/**
 * The hour bucket a moment falls in, as `YYYY-MM-DDTHH` in UTC, so bucket
 * boundaries do not depend on the host's timezone.
 * @param unix {int} the moment, Unix seconds
 * @return {string} the bucket key
 */
export func hourKey(unix as int) {
    return time.format(time.fromUnix($unix), "%Y-%m-%dT%H");
}

/**
 * The day bucket a moment falls in, as `YYYY-MM-DD` in UTC.
 * @param unix {int} the moment, Unix seconds
 * @return {string} the bucket key
 */
export func dayKey(unix as int) {
    return time.format(time.fromUnix($unix), "%Y-%m-%d");
}

/**
 * The month bucket a moment falls in, as `YYYY-MM` in UTC.
 * @param unix {int} the moment, Unix seconds
 * @return {string} the bucket key
 */
export func monthKey(unix as int) {
    return time.format(time.fromUnix($unix), "%Y-%m");
}

/**
 * The day key containing an hour key, by truncation. Derived from the key,
 * not the clock, so a 23:59 lookup flushed after midnight counts on its own day.
 * @param hour {string} an hour key from `hourKey`
 * @return {string} the day key containing it, or "" if the key is malformed
 */
export func dayOfHour(hour as string) {
    if (len($hour) < 13) {
        return "";
    }
    return strings.substring($hour, 0, 10);
}

/**
 * The month key containing an hour key.
 * @param hour {string} an hour key from `hourKey`
 * @return {string} the month key containing it, or "" if the key is malformed
 */
export func monthOfHour(hour as string) {
    if (len($hour) < 13) {
        return "";
    }
    return strings.substring($hour, 0, 7);
}

# ensureShape gives a record its three bucket objects and its total, since
# `json.set` does not create missing parents.
func ensureShape(rec as json.Value) {
    def out as json.Value init $rec;
    for (def at in ["/hours", "/days", "/months"]) {
        if (not json.has($out, $at)) {
            $out = json.set($out, $at, json.map());
        }
    }
    if (not json.has($out, "/total")) {
        $out = json.set($out, "/total", 0);
    }
    return $out;
}

# bump adds n to an object member, creating it at n when absent.
func bump(rec as json.Value, at as string, n as int) {
    def out as json.Value init $rec;
    def now as int init 0;
    if (json.has($out, $at)) {
        $now = json.asInt($out, $at);
    }
    return json.set($out, $at, $now + $n);
}

/**
 * Record `n` lookups against an hour bucket, updating every resolution at once.
 *
 * All four numbers are maintained on write, which happens once per flush
 * rather than per page view. `total` cannot be recomputed from the buckets,
 * since pruning discards old months.
 * @param rec {json.Value} the deck's stats record, possibly empty
 * @param hour {string} the hour key the lookups happened in
 * @param n {int} how many lookups; a value below 1 is a no-op
 * @return {json.Value} the updated record
 */
export func applyHit(rec as json.Value, hour as string, n as int) {
    if ($n < 1 or dayOfHour($hour) == "") {
        return $rec;
    }
    def out as json.Value init ensureShape($rec);
    $out = bump($out, "/hours/" + $hour, $n);
    $out = bump($out, "/days/" + dayOfHour($hour), $n);
    $out = bump($out, "/months/" + monthOfHour($hour), $n);
    $out = bump($out, "/total", $n);
    return $out;
}

# sumOver adds up the members of an object whose keys are in `wanted`. Absent
# keys count as zero.
func sumOver(rec as json.Value, at as string, wanted as list of string) {
    def total as int init 0;
    for (def key in $wanted) {
        if (json.has($rec, $at + "/" + $key)) {
            $total = $total + json.asInt($rec, $at + "/" + $key);
        }
    }
    return $total;
}

/**
 * The last `n` day keys, most recent first, ending with the day containing `unix`.
 * @param unix {int} the moment the window ends in
 * @param n {int} how many days
 * @return {list of string} the keys
 */
export func recentDays(unix as int, n as int) {
    def out as list of string init [];
    def i as int init 0;
    while ($i < $n) {
        $out[] = dayKey($unix - ($i * SECONDS_PER_DAY));
        $i = $i + 1;
    }
    return $out;
}

/**
 * The last `n` month keys, most recent first, ending with the month containing
 * `unix`. Uses calendar arithmetic; subtracting 30 days at a time would skip a
 * month twice a year.
 * @param unix {int} the moment the window ends in
 * @param n {int} how many months
 * @return {list of string} the keys
 */
export func recentMonths(unix as int, n as int) {
    def at as time.Time init time.fromUnix($unix);
    def year as int init convert.toInt(time.format($at, "%Y"));
    def month as int init convert.toInt(time.format($at, "%m"));
    def out as list of string init [];
    def i as int init 0;
    while ($i < $n) {
        $out[] = twoDigitMonth($year, $month);
        $month = $month - 1;
        if ($month < 1) {
            $month = 12;
            $year = $year - 1;
        }
        $i = $i + 1;
    }
    return $out;
}

# twoDigitMonth renders a year and month as a bucket key.
func twoDigitMonth(year as int, month as int) {
    def m as string init convert.toString($month);
    if ($month < 10) {
        $m = "0" + $m;
    }
    return convert.toString($year) + "-" + $m;
}

/**
 * Summarise a stats record as of `unix`.
 * @param rec {json.Value} the deck's stats record, possibly empty
 * @param unix {int} the moment to summarise as of, Unix seconds
 * @return {Counts} the counts for display
 */
export func summarise(rec as json.Value, unix as int) {
    def total as int init 0;
    if (json.has($rec, "/total")) {
        $total = json.asInt($rec, "/total");
    }
    return Counts{
        thisHour: sumOver($rec, "/hours", [hourKey($unix)]),
        today: sumOver($rec, "/days", [dayKey($unix)]),
        last7Days: sumOver($rec, "/days", recentDays($unix, 7)),
        last30Days: sumOver($rec, "/days", recentDays($unix, 30)),
        last12Months: sumOver($rec, "/months", recentMonths($unix, 12)),
        total: $total
    };
}

/**
 * Report whether a record has no traffic, so a never-resolved deck carries no
 * stats object.
 * @param rec {json.Value} the record
 * @return {bool} true when nothing has ever been counted
 */
export func isEmpty(rec as json.Value) {
    if (not json.has($rec, "/total")) {
        return true;
    }
    return json.asInt($rec, "/total") == 0;
}

# keptOnly rebuilds an object with only the members named in `wanted`, to
# prune a bucket set without removing while iterating.
func keptOnly(rec as json.Value, at as string, wanted as list of string) {
    def out as json.Value init json.map();
    for (def key in $wanted) {
        if (json.has($rec, $at + "/" + $key)) {
            # A bucket key is a date with no "/" or "~", so it needs no pointer
            # escaping, only the leading slash.
            $out = json.set($out, "/" + $key, json.asInt($rec, $at + "/" + $key));
        }
    }
    return $out;
}

/**
 * Drop buckets outside the retention windows. `total` is left unchanged: it is
 * the lifetime count and outlives its buckets.
 * @param rec {json.Value} the record to prune
 * @param unix {int} the moment to prune as of, Unix seconds
 * @return {json.Value} the pruned record
 */
export func prune(rec as json.Value, unix as int) {
    def hours as list of string init [];
    def i as int init 0;
    while ($i < KEEP_HOURS) {
        $hours[] = hourKey($unix - ($i * SECONDS_PER_HOUR));
        $i = $i + 1;
    }
    def out as json.Value init ensureShape($rec);
    $out = json.set($out, "/hours", keptOnly($rec, "/hours", $hours));
    $out = json.set($out, "/days", keptOnly($rec, "/days", recentDays($unix, KEEP_DAYS)));
    $out = json.set($out, "/months", keptOnly($rec, "/months", recentMonths($unix, KEEP_MONTHS)));
    return $out;
}

/**
 * Fold a batch of counted lookups (from the flusher: the hour they happened in
 * and how many) into a store record, pruning in the same pass.
 * @param rec {json.Value} the deck's existing record, possibly empty
 * @param hour {string} the hour key those lookups fell in
 * @param n {int} how many lookups
 * @param unix {int} now, for pruning
 * @return {json.Value} the record to persist
 */
export func record(rec as json.Value, hour as string, n as int, unix as int) {
    return prune(applyHit($rec, $hour, $n), $unix);
}
