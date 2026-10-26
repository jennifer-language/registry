# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Per-address rate limiting for the token exchange (section 11).
 *
 * `/auth/device`, `/auth/token` and `/auth/refresh` are unauthenticated and each
 * calls the identity provider, so without a limit anybody can spend the
 * registry's provider quota. They share one sliding one-minute window per
 * client address.
 *
 * `webapi`'s own limiter is not used: it keys on `web.remoteAddr`, which carries
 * the source port, so every connection would get a fresh bucket, and it ignores
 * the configured client-address header.
 * @module throttle
 */

use strings;

import "ipnet.j" as ipnet;
import "kvstore.j" as kvstore;
import "ratelimit.j" as ratelimit;

/** The window, in seconds. */
export def const WINDOW_SECONDS as int init 60;

/**
 * A limiter for `perMinute` requests per key, in this process's memory. Counters
 * expire on their own, so nothing needs reaping.
 * @param perMinute {int} requests allowed per key per minute; below 1 counts as
 *     1, since `ratelimit` refuses 0 (a caller that turns limiting off skips it)
 * @return {ratelimit.Limiter} the limiter
 */
export func limiter(perMinute as int) {
    def limit as int init $perMinute;
    if ($limit < 1) {
        $limit = 1;
    }
    return ratelimit.slidingWindow(kvstore.inProcessStore(), $limit, WINDOW_SECONDS);
}

/**
 * The bucket a client address counts against. An IPv4 address is its own
 * bucket; an IPv6 address counts against its /64, the smallest block a host is
 * routinely given, so rotating through one's own addresses does not reset the
 * count. A port, as `web.remoteAddr` reports it, is dropped. Anything that does
 * not parse as an address is used as it is.
 * @param client {string} the address, as `audit.clientOf` returns it
 * @return {string} the key
 */
export func keyOf(client as string) {
    def host as string init hostOf(strings.trim($client));
    try {
        def addr as ipnet.Address init ipnet.parseAddress($host);
        if (ipnet.version($addr) == 4) {
            return ipnet.toString($addr);
        }
        return ipnet.networkString(ipnet.parse(ipnet.toString($addr) + "/64"));
    } catch (err) {
        return $host;
    }
}

/**
 * Whether a connection peer is one whose client-address header may be believed:
 * a loopback or private address, where a reverse proxy sits. A public peer, or
 * one that does not parse, is a client speaking for itself, and its header is
 * ignored.
 * @param peer {string} the address, as `web.remoteAddr` reports it
 * @return {bool} true for loopback and private peers
 */
export func isTrustedPeer(peer as string) {
    try {
        def addr as ipnet.Address init ipnet.parseAddress(hostOf(strings.trim($peer)));
        return ipnet.isLoopback($addr) or ipnet.isPrivate($addr);
    } catch (err) {
        return false;
    }
}

# hostOf strips a port: `[v6]:port` and `v4:port` lose it, a bare IPv6 address
# (more than one colon, no brackets) is left whole.
func hostOf(s as string) {
    if (strings.startsWith($s, "[")) {
        def close as int init strings.indexOf($s, "]");
        if ($close > 0) {
            return $s[1..$close];
        }
        return $s;
    }
    def colon as int init strings.indexOf($s, ":");
    if ($colon >= 0 and strings.lastIndexOf($s, ":") == $colon) {
        return $s[..$colon];
    }
    return $s;
}
