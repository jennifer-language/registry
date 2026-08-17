# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Per-deck lookup counts, as pure functions over a JSON record.
 *
 * **These are not downloads, and this module will not call them that.** The
 * registry indexes; it does not host (specification 6), so a client fetches a
 * deck's code from its git repository and the registry never sees those bytes.
 * What it does see is a client asking *where* a deck is - `GET /deck`,
 * `/decks/:name`, `/resolve` - and that is what is counted here.
 *
 * The difference matters in both directions, which is why the page says
 * "resolutions" and explains itself:
 *
 * - **It undercounts installs.** A lockfile already carries the pin, so
 *   reinstalling a resolved dependency needs no registry call at all.
 * - **It overcounts people.** A CI fleet that resolves on every build is one
 *   user producing hundreds of lookups.
 *
 * So it is a measure of *interest and churn*, useful for "is anyone picking this
 * up" and useless for "how many humans use this". A number labelled `downloads`
 * would be a more satisfying lie.
 *
 * The shape is four buckets, and everything else is derived:
 *
 * ```json
 * { "hours": {"2026-08-17T19": 3}, "days": {"2026-08-17": 12},
 *   "months": {"2026-08": 40}, "total": 40 }
 * ```
 *
 * Buckets rather than a running log because a log is unbounded and a bucket is
 * not: the retention windows below cap a deck's record at a few dozen integers
 * no matter how much traffic it takes. Three resolutions rather than one because
 * "this hour" needs hourly detail that nobody needs a year later, and "the last
 * 12 months" needs a year of reach that would cost 365 numbers at daily detail.
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
 * How many buckets of each resolution are kept. Everything older is pruned on
 * the next write, so a deck's record cannot grow without bound.
 *
 * Hours are kept for two days rather than one, because "this hour" has to stay
 * answerable across a restart and a flush that lands the wrong side of midnight.
 * Days outlive the 30-day window they feed so that window is complete on its
 * oldest day rather than truncated. Months outlive the 12-month window for the
 * same reason.
 */
export def const KEEP_HOURS as int init 48;
export def const KEEP_DAYS as int init 62;
export def const KEEP_MONTHS as int init 24;

def const SECONDS_PER_HOUR as int init 3600;
def const SECONDS_PER_DAY as int init 86400;

/**
 * A deck's counts, summarised for display.
 *
 * The windows are **calendar-anchored for the short ones and rolling for the
 * long ones**, which is what people actually mean: "today" is a day on a
 * calendar, whereas "the last 30 days" is a window, and offering "this month" on
 * the 1st would report a number that looks like a collapse in traffic.
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
 * The hour bucket a moment falls in, as `YYYY-MM-DDTHH` in UTC.
 *
 * UTC and not a local zone: the registry's own timezone is an accident of where
 * it runs, and a bucket boundary that moves when the host moves would make two
 * deployments of the same registry disagree about what "today" counted.
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
 * The day and month a given **hour** key belongs to.
 *
 * Derived from the hour key by truncation rather than from the clock, because a
 * hit is attributed to when it happened and a flush runs later: counting a
 * 23:59 lookup into the next day's bucket because that is when the flush landed
 * would be wrong every single night.
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

# ensureShape gives a record its three bucket objects and its total. `json.set`
# addresses a path but does not create the parents along it, so an empty record
# has to be given its shape before anything can be written into it.
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
 * All four numbers are maintained on write rather than summed on read. A read
 * happens on every page view and a write happens once per flush, so the work
 * belongs on the write; and `total` in particular **cannot** be recomputed from
 * the buckets, since pruning has already thrown away the months it came from.
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
# keys contribute nothing, which is what makes a quiet deck read as zero rather
# than as missing data.
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
 * `unix`.
 *
 * Counted down by calendar arithmetic rather than by subtracting 30 days at a
 * time, which would skip a month twice a year.
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
 * Is this record entirely empty of traffic? Used to keep a never-resolved deck
 * from carrying a stats object at all, so the document does not grow a member
 * per deck the moment the feature ships.
 * @param rec {json.Value} the record
 * @return {bool} true when nothing has ever been counted
 */
export func isEmpty(rec as json.Value) {
    if (not json.has($rec, "/total")) {
        return true;
    }
    return json.asInt($rec, "/total") == 0;
}

# keptOnly rebuilds an object with only the members named in `wanted`, which is
# how a bucket set is pruned. Rebuilding rather than deleting in place avoids
# iterating a structure while removing from it.
func keptOnly(rec as json.Value, at as string, wanted as list of string) {
    def out as json.Value init json.map();
    for (def key in $wanted) {
        if (json.has($rec, $at + "/" + $key)) {
            # A bucket key is a date, so it carries neither "/" nor "~" and needs
            # no pointer escaping; it does need the leading slash that makes it a
            # pointer rather than a bare name.
            $out = json.set($out, "/" + $key, json.asInt($rec, $at + "/" + $key));
        }
    }
    return $out;
}

/**
 * Drop buckets outside the retention windows.
 *
 * `total` is never touched: it is the one number that outlives its buckets, and
 * pruning it would make a deck's lifetime count fall over time.
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
    $out = json.set($out, "/days",
        keptOnly($rec, "/days", recentDays($unix, KEEP_DAYS)));
    $out = json.set($out, "/months",
        keptOnly($rec, "/months", recentMonths($unix, KEEP_MONTHS)));
    return $out;
}

/**
 * Fold a batch of counted lookups into a store record.
 *
 * The flusher hands over what it accumulated in memory: a deck, the hour those
 * lookups happened in, and how many. Pruning runs on the same pass, because a
 * write is the only moment the record is already in hand and about to be
 * persisted anyway.
 *
 * Pure, so the flusher's arithmetic is tested without a server, a clock, or a
 * background task.
 * @param rec {json.Value} the deck's existing record, possibly empty
 * @param hour {string} the hour key those lookups fell in
 * @param n {int} how many lookups
 * @param unix {int} now, for pruning
 * @return {json.Value} the record to persist
 */
export func record(rec as json.Value, hour as string, n as int, unix as int) {
    return prune(applyHit($rec, $hour, $n), $unix);
}
