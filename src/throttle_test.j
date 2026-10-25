# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for throttle.j. Run with:
#
#     jennifer test src/throttle_test.j

use testing;

func testAPortDoesNotMakeANewBucket() {
    testing.assertEqual(keyOf("203.0.113.7:51234"), "203.0.113.7");
    testing.assertEqual(keyOf("203.0.113.7:51235"), "203.0.113.7");
    testing.assertEqual(keyOf("203.0.113.7"), "203.0.113.7");
}

func testAnIPv6ClientCountsAgainstItsSlash64() {
    testing.assertEqual(keyOf("[2001:db8:1:2::1]:443"), "2001:db8:1:2::/64");
    testing.assertEqual(keyOf("2001:db8:1:2:ffff::9"), "2001:db8:1:2::/64");
    testing.assertEqual(keyOf("2001:db8:1:3::1"), "2001:db8:1:3::/64");
}

func testAMappedIPv4AddressIsTheIPv4Bucket() {
    testing.assertEqual(keyOf("[::ffff:203.0.113.7]:80"), "203.0.113.7");
}

func testSomethingThatIsNotAnAddressIsUsedAsItIs() {
    testing.assertEqual(keyOf(" unix-socket "), "unix-socket");
    testing.assertEqual(keyOf(""), "");
}

func testTheLimiterRefusesPastTheLimitPerKey() {
    def lim as ratelimit.Limiter init limiter(2);
    testing.assertTrue(ratelimit.check($lim, "a").allowed);
    testing.assertTrue(ratelimit.check($lim, "a").allowed);
    def third as ratelimit.Result init ratelimit.check($lim, "a");
    testing.assertFalse($third.allowed);
    testing.assertTrue($third.retryAfter > 0);
    testing.assertTrue(ratelimit.check($lim, "b").allowed);
}

func testALimitOfZeroStillBuildsALimiter() {
    testing.assertEqual(limiter(0).limit, 1);
}
