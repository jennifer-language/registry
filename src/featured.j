# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The featured decks on the landing page: one deck per card, each chosen by a
 * measure the registry already records.
 *
 * | card | the deck with the most | needs |
 * | --- | --- | --- |
 * | Most resolved | lookups in the last 30 days | at least one |
 * | Busy this week | lookups in the last 7 days | at least one |
 * | Most depended on | live decks requiring it from their newest version | at least one |
 * | Newest | recent first publish | a live deck |
 * | Latest release | recent publish after the first | a second version |
 * | Deck of the day | (none: a daily rotation) | live before today began, not on another card |
 *
 * Lookups are `stats` resolutions, not downloads (see that module). A deck
 * appears on one card at most: each card takes the best deck the cards before
 * it left, so one busy deck does not fill the page. Ties go to listing order.
 * Only decks with a live version count, since a card is an invitation to
 * install. A card nothing qualifies for is left out, so a new registry shows
 * fewer.
 *
 * The deck of the day steps by a large prime per day through the decks that
 * were live when the day began (UTC), so every reader sees the same one, every
 * deck gets a turn, and nothing that happens during the day moves it to
 * another deck: a deck published today joins tomorrow's rotation, and the
 * other cards are not consulted. When one of them already shows today's deck,
 * the card is left out rather than replaced. No randomness: a page that
 * changed per request could not be cached.
 *
 * `build` reads every deck's versions and counts, so the server builds it with
 * the shared index, once per version of the file, and serves the result.
 * @module featured
 * @example
 * import "./featured.j" as featured;
 * def picks as json.Value init featured.build($db, search.index($db), $now);
 * def cards as list of featured.Pick init featured.fromJson($picks);
 */

use json;
use maps;
use strings;
use convert;
import "flatdb.j" as flatdb;
import "./store.j" as store;
import "./stats.j" as stats;
import "./deckname.j" as deckname;

/**
 * One featured card.
 * @field label {string} what the card is for, e.g. "Most resolved"
 * @field name {string} the deck
 * @field description {string} the deck's description ("" when it has none)
 * @field detail {string} why it is here, e.g. "12 resolutions in the last 30 days"
 */
export def struct Pick {
    label as string,
    name as string,
    description as string,
    detail as string
};

/** The most cards `build` returns. */
export def const MAX_PICKS as int init 6;

# The day-to-day step of the deck of the day. A prime, so for any listing
# shorter than it the rotation reaches every deck before repeating.
def const DAY_STEP as int init 7919;

def const SECONDS_PER_DAY as int init 86400;

# Measured is one live deck with the numbers the cards rank by.
def struct Measured {
    name as string,
    description as string,
    month as int,
    week as int,
    dependents as int,
    firstAt as int,
    lastAt as int,
    lastVersion as string,
    versions as int
};

/**
 * Choose the featured decks.
 * @param db {flatdb.DB} the registry to read
 * @param index {json.Value} its deck index, from `search.index`
 * @param now {int} the current time (Unix seconds), for the count windows and
 *     the day
 * @return {json.Value} up to `MAX_PICKS` cards as a list of objects with the
 *     `Pick` fields, in card order
 */
export func build(db as flatdb.DB, index as json.Value, now as int) {
    def decks as list of Measured init measure($db, $index, $now);
    def taken as map of string to bool init {};
    def picks as list of Pick init [];
    def best as int init 0;

    $best = bestBy($decks, $taken, "month");
    if ($best >= 0) {
        def d as Measured init $decks[$best];
        $picks[] = pickOf(
            "Most resolved",
            $d,
            counted($d.month, "resolution") +
                " in the last 30 days");
        $taken[$d.name] = true;
    }
    $best = bestBy($decks, $taken, "week");
    if ($best >= 0) {
        def d as Measured init $decks[$best];
        $picks[] = pickOf(
            "Busy this week",
            $d,
            counted($d.week, "resolution") +
                " in the last 7 days");
        $taken[$d.name] = true;
    }
    $best = bestBy($decks, $taken, "dependents");
    if ($best >= 0) {
        def d as Measured init $decks[$best];
        $picks[] = pickOf("Most depended on", $d, "required by " +
            counted($d.dependents, "deck"));
        $taken[$d.name] = true;
    }
    $best = bestBy($decks, $taken, "firstAt");
    if ($best >= 0) {
        def d as Measured init $decks[$best];
        $picks[] = pickOf("Newest", $d, "first published " + stats.dayKey($d.firstAt));
        $taken[$d.name] = true;
    }
    $best = bestBy($decks, $taken, "lastAt");
    if ($best >= 0) {
        def d as Measured init $decks[$best];
        $picks[] = pickOf("Latest release", $d, $d.lastVersion + " on " +
            stats.dayKey($d.lastAt));
        $taken[$d.name] = true;
    }
    def today as int init ofTheDay($decks, $now);
    if ($today >= 0 and not maps.has($taken, $decks[$today].name)) {
        $picks[] = pickOf("Deck of the day", $decks[$today], "one deck a day, in turn");
    }

    def out as list of json.Value init [];
    for (def p in $picks) {
        def o as json.Value init json.map();
        $o = json.set($o, "/label", $p.label);
        $o = json.set($o, "/name", $p.name);
        $o = json.set($o, "/description", $p.description);
        $o = json.set($o, "/detail", $p.detail);
        $out[] = $o;
    }
    return json.list($out);
}

/**
 * Read the cards `build` returned.
 * @param picks {json.Value} the list from `build`
 * @return {list of Pick} the cards, in order
 */
export func fromJson(picks as json.Value) {
    def out as list of Pick init [];
    for (def i in 0..json.length($picks, "")) {
        def at as string init "/" + convert.toString($i);
        $out[] = Pick{
            label: json.asString($picks, $at + "/label"),
            name: json.asString($picks, $at + "/name"),
            description: json.asString($picks, $at + "/description"),
            detail: json.asString($picks, $at + "/detail")
        };
    }
    return $out;
}

# pickOf is a card for one deck.
func pickOf(label as string, d as Measured, detail as string) {
    return Pick{label: $label, name: $d.name, description: $d.description, detail: $detail};
}

# counted is "1 deck" or "3 decks".
func counted(n as int, noun as string) {
    if ($n == 1) {
        return "1 " + $noun;
    }
    return convert.toString($n) + " " + $noun + "s";
}

# measure reads the numbers of every live deck, in index order.
func measure(db as flatdb.DB, index as json.Value, now as int) {
    def live as list of string init [];
    def descriptions as map of string to string init {};
    for (def i in 0..json.length($index, "")) {
        def at as string init "/" + convert.toString($i);
        if (json.asBool($index, $at + "/live")) {
            def name as string init json.asString($index, $at + "/name");
            $live[] = $name;
            $descriptions[$name] = json.asString($index, $at + "/description");
        }
    }
    def dependents as map of string to int init requiredBy($db, $live);
    def out as list of Measured init [];
    for (def name in $live) {
        def c as stats.Counts init stats.summarise(store.getStats($db, $name), $now);
        def m as Measured init Measured{
            name: $name,
            description: $descriptions[$name],
            month: $c.last30Days,
            week: $c.last7Days,
            dependents: 0,
            firstAt: 0,
            lastAt: 0,
            lastVersion: "",
            versions: 0
        };
        if (maps.has($dependents, $name)) {
            $m.dependents = $dependents[$name];
        }
        $out[] = dated($db, $m);
    }
    return $out;
}

# dated fills in when a deck was first published and when it last released:
# the earliest and latest `publishedAt` of its live versions. The latest by date,
# not the highest version, so a patch to an older line counts as a release.
func dated(db as flatdb.DB, m as Measured) {
    def out as Measured init $m;
    def first as int init -1;
    for (def v in store.listLiveVersions($db, $m.name)) {
        def at as int init secondsOf(store.getVersionRecord($db, $m.name, $v).publishedAt);
        $out.versions = $out.versions + 1;
        if ($first < 0 or $at < $first) {
            $first = $at;
        }
        if ($at >= $out.lastAt) {
            $out.lastAt = $at;
            $out.lastVersion = $v;
        }
    }
    if ($first > 0) {
        $out.firstAt = $first;
    }
    return $out;
}

# secondsOf reads a `publishedAt` (Unix seconds as text); 0 when it is not one,
# so an undated version never looks recent.
func secondsOf(text as string) {
    if (len($text) == 0 or len($text) > 12) {
        return 0;
    }
    for (def ch in strings.chars($text)) {
        if ($ch < "0" or $ch > "9") {
            return 0;
        }
    }
    return convert.toInt($text);
}

# requiredBy counts, for each live deck, how many other live decks require it
# from their newest live version. A deck requiring itself is not counted.
func requiredBy(db as flatdb.DB, live as list of string) {
    def isLive as map of string to bool init {};
    for (def name in $live) {
        $isLive[$name] = true;
    }
    def counts as map of string to int init {};
    for (def name in $live) {
        def newest as string init newestOf($db, $name);
        if ($newest == "") {
            continue;
        }
        for (def dep in maps.keys(store.versionRequires($db, $name, $newest))) {
            def folded as string init deckname.fold($dep);
            if (not maps.has($isLive, $folded) or $folded == $name) {
                continue;
            }
            if (maps.has($counts, $folded)) {
                $counts[$folded] = $counts[$folded] + 1;
            } else {
                $counts[$folded] = 1;
            }
        }
    }
    return $counts;
}

# newestOf is a deck's highest live version.
func newestOf(db as flatdb.DB, name as string) {
    for (def v in store.listVersionsDescending($db, $name)) {
        if (not store.isYanked($db, $name, $v)) {
            return $v;
        }
    }
    return "";
}

# bestBy is the position of the untaken deck with the highest value of one
# measure, the earliest in listing order on a tie; -1 when none has one above
# zero. "lastAt" counts only decks with a release after their first.
func bestBy(decks as list of Measured, taken as map of string to bool, measure as string) {
    def best as int init -1;
    def top as int init 0;
    for (def i in 0..len($decks)) {
        def d as Measured init $decks[$i];
        if (maps.has($taken, $d.name)) {
            continue;
        }
        def value as int init 0;
        match ($measure) {
            when "month" { $value = $d.month; }
            when "week" { $value = $d.week; }
            when "dependents" { $value = $d.dependents; }
            when "firstAt" { $value = $d.firstAt; }
            when "lastAt" {
                if ($d.versions > 1) {
                    $value = $d.lastAt;
                }
            }
        }
        if ($value > $top) {
            $top = $value;
            $best = $i;
        }
    }
    return $best;
}

# ofTheDay is the position of today's deck, -1 when no deck was live before the
# day began. It reads only the day and the decks first published before it, not
# the other cards, so a publish or a lookup during the day cannot move it.
func ofTheDay(decks as list of Measured, now as int) {
    def start as int init $now - $now % SECONDS_PER_DAY;
    def rotation as list of int init [];
    for (def i in 0..len($decks)) {
        # An undated deck (firstAt 0) predates dating, so it is in.
        if ($decks[$i].firstAt < $start) {
            $rotation[] = $i;
        }
    }
    if (len($rotation) == 0) {
        return -1;
    }
    def day as int init convert.toInt($start / SECONDS_PER_DAY);
    return $rotation[($day * DAY_STEP) % len($rotation)];
}
