package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the #364 historical-sync auto-continue decision ([WhoopBleClient.shouldAutoContinue]). The real
 * bug: the strap offloads OLDEST-first at ~60s/session with a 15-min floor and NO auto-continue, so on a
 * deep backlog each connection drains only the oldest pass then waits — "last night" can take many
 * connections to reach even while the strap stays connected. The predicate decides whether a session that
 * ended on the 60s IDLE cap (not a true HISTORY_COMPLETE) should immediately re-kick instead of tearing
 * down to the floor. Pure → no live GATT stack needed; mirrors the Swift BackfillContinuationTests
 * byte-for-behaviour.
 *
 * #928 pinned here too: the predicate takes the REAL wall clock (`wallNowUnix`) so a strap clock set in
 * the FUTURE (a "newest" more than 48 h ahead of the wall) is excluded from the backlog test instead of
 * reading as endless backlog. Fixtures pass an explicit wall-now consistent with their timestamps.
 */
class BackfillContinuationTest {

    /** The fixtures' "now": all pre-#928 timestamps sit at or before this instant, so the plausibility
     *  check is inert for them and the original #364/#451/#25 semantics stay pinned unchanged. */
    private val wallNow = 1_800_000_000L

    /** Happy path: connected, strap well ahead of our frontier, trim advanced, under the cap ⇒ continue. */
    @Test
    fun continues_whenConnectedBehindAndAdvancing() {
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 86_400L,   // a full day behind
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
            ),
        )
    }

    /** A dropped link must NOT auto-continue — the normal reconnect path owns it. */
    @Test
    fun stops_whenDisconnected() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = false,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 86_400L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
            ),
        )
    }

    /** Caught up: the strap is not meaningfully ahead of our frontier ⇒ nothing left to fetch. */
    @Test
    fun stops_whenCaughtUp() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 120L,      // 2 min behind, under the 5-min gap
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
            ),
        )
    }

    /** The gap boundary is NOT "behind" (strictly-greater); one second past it IS. */
    @Test
    fun gapBoundary_isNotBehind() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 300L,      // exactly the 300s gap
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                behindGapSeconds = 300L,
            ),
        )
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 301L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                behindGapSeconds = 300L,
            ),
        )
    }

    /** Spin-detector: a frozen trim cursor (console-only / refusing to trim) must NOT re-kick. */
    @Test
    fun stops_whenTrimFrozen() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 86_400L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = false,
                consecutiveCount = 0,
            ),
        )
    }

    /** Hard per-connection cap: at/above the cap we stop and let the 900s timer take over. */
    @Test
    fun stops_atCap() {
        val cap = WhoopBleClient.MAX_AUTO_CONTINUES
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 86_400L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = cap - 1,
            ),
        )
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 86_400L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = cap,
            ),
        )
    }

    /** Unknown range (no GET_DATA_RANGE answer, or nothing persisted yet) ⇒ don't auto-continue. */
    @Test
    fun stops_whenRangeUnknown() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = null,
                ourFrontierTs = 1_700_000_000L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
            ),
        )
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = null,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
            ),
        )
    }

    /** #451: GET_DATA_RANGE latched a STALE / wrong-epoch "newest" (e.g. 2024 when the real newest is
     *  2026), which reads as BEHIND our frontier — the old "strap ahead" test fails and we'd stop after one
     *  session. But the trim advanced AND this pass persisted real sensor rows ⇒ keep draining. */
    @Test
    fun continues_whenNewestStaleButRowsFlowing() {
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_700_000_000L,             // stale range answer…
                ourFrontierTs = 1_800_000_000L,             // …reads as behind our real frontier
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 240,
            ),
        )
    }

    /** The discriminator that keeps the #451 fallback safe: a caught-up / console-only strap persists ZERO
     *  rows, so even with the trim nudging it must NOT spin. */
    @Test
    fun stops_whenNewestStaleAndNoRows() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_700_000_000L,
                ourFrontierTs = 1_800_000_000L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 0,
            ),
        )
    }

    /** GET_DATA_RANGE unanswered (null) but real rows flowing and the trim advanced ⇒ keep draining. */
    @Test
    fun continues_whenRangeUnknownButRowsFlowing() {
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = null,
                ourFrontierTs = 1_800_000_000L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 180,
            ),
        )
    }

    /** The rows-flowing fallback never overrides the earlier guards: frozen trim, cap, and dropped link
     *  still stop even with rows > 0. */
    @Test
    fun rowsFallback_stillRespectsHardGuards() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_700_000_000L,
                ourFrontierTs = 1_800_000_000L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = false,                   // frozen cursor wins
                consecutiveCount = 0,
                rowsPersistedThisSession = 240,
            ),
        )
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_700_000_000L,
                ourFrontierTs = 1_800_000_000L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = WhoopBleClient.MAX_AUTO_CONTINUES,   // cap wins
                rowsPersistedThisSession = 240,
            ),
        )
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = false,                     // dropped link wins
                strapNewestTs = 1_700_000_000L,
                ourFrontierTs = 1_800_000_000L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 240,
            ),
        )
    }

    /** A deep backlog drains pass-after-pass until caught up OR the cap is hit — never stalling at one. */
    @Test
    fun multiPassDrain_untilCaughtUpOrCapped() {
        val strapNewest = 1_800_000_000L
        var frontier = strapNewest - 7L * 86_400L   // a week behind
        var count = 0
        var passes = 0
        while (WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = strapNewest,
                ourFrontierTs = frontier,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = count,
            )
        ) {
            frontier += 86_400L
            count += 1
            passes += 1
            assertTrue("auto-continue must be bounded", passes <= WhoopBleClient.MAX_AUTO_CONTINUES + 1)
        }
        assertEquals(WhoopBleClient.MAX_AUTO_CONTINUES, count)
    }

    // #25 — HISTORY_COMPLETE-sliced offloads

    /** #25: the user goes to bed with a charged strap, the phone dies, and overnight banks a deep backlog.
     *  Some strap firmware segments that offload into many SMALL HISTORY_COMPLETE slices rather than one
     *  long session. Before #25, exitBackfilling only auto-continued on a 60s TIMEOUT, so a strap that
     *  completed-then-stopped between slices stalled until the periodic floor — "last night" drained an hour
     *  at a time. The predicate is reason-agnostic: a small completion STILL far behind the strap's newest,
     *  with the trim advancing and real rows banked, must auto-continue exactly as a timeout would. */
    @Test
    fun smallHistoryComplete_stillBehind_continues() {
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 6L * 3600L,   // still 6 h behind after this slice
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 90,                 // a small slice, but real rows landed
            ),
        )
    }

    /** #25: the LAST slice of the overnight drain brings us level with the strap's newest record. Firing
     *  the auto-continue on HISTORY_COMPLETE must NOT spin a caught-up strap — the frontier is now within
     *  the behind-gap, so the predicate returns false and the session tears down to the periodic floor. */
    @Test
    fun finalHistoryComplete_caughtUp_stops() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 60L,          // within the 5-min gap ⇒ caught up
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                // A genuinely caught-up strap hands over NO new rows on the final END (empty / console-only).
                // 0 rows means the #451 guard-2b "keep draining if still persisting real backlog" does NOT
                // fire, so the predicate returns false and the session tears down to the periodic floor.
                rowsPersistedThisSession = 0,
            ),
        )
    }

    /** #25: a pathological strap that emits an endless run of tiny far-behind HISTORY_COMPLETE slices must
     *  still be bounded by the per-connection cap — otherwise firing on completion would let it pin the
     *  radio. Each slice persists rows and stays behind, yet the drain stops at exactly MAX_AUTO_CONTINUES. */
    @Test
    fun historyCompleteSlices_areCapped_notRunaway() {
        var count = 0
        var continued = 0
        while (WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = 1_800_000_000L,
                ourFrontierTs = 1_800_000_000L - 7L * 86_400L, // never catches up — frontier stays far behind
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = count,
                rowsPersistedThisSession = 30,                 // every tiny slice banks a few rows
            )
        ) {
            count += 1
            continued += 1
            assertTrue("HISTORY_COMPLETE slices must be capped, not spin forever", continued <= WhoopBleClient.MAX_AUTO_CONTINUES + 1)
        }
        assertEquals(WhoopBleClient.MAX_AUTO_CONTINUES, count)
    }

    // #928: strap clock set in the FUTURE

    /** #928 THE BUG: a strap clock set ahead makes the range "newest" future-dated, which reads as
     *  permanently AHEAD of every real frontier, so the backlog guard fired on every connect and burned up
     *  to the full cap in EMPTY offloads. An implausibly future newest (more than 48 h past the wall
     *  clock) must be EXCLUDED from the backlog test: with no real rows this session there is no evidence
     *  of backlog, so the very first empty session stops the drain. */
    @Test
    fun futureClockNewest_excluded_stopsEmptySpin() {
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = wallNow + 30L * 86_400L,   // strap clock a month ahead of the wall
                ourFrontierTs = wallNow - 600L,            // we're genuinely caught up to 10 min ago
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 0,              // the offloads come back empty
            ),
        )
    }

    /** #928 + #451 symmetry: a future-dated range answer is unreliable, but REAL rows persisting this
     *  session are direct evidence of backlog, so the rows path still continues the drain (the exclusion
     *  only removes the untrustworthy range shortcut, it never blocks demonstrated progress). */
    @Test
    fun futureClockNewest_stillContinuesOnRealRows() {
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = wallNow + 30L * 86_400L,   // same future-dated answer
                ourFrontierTs = wallNow - 600L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 240,            // but this pass banked real records
            ),
        )
    }

    /** #928 boundary: exactly 48 h ahead is still plausible (the guard is strictly-greater, absorbing
     *  timezone confusion and mild drift); one second past it is implausible and excluded. */
    @Test
    fun futureSkewBoundary() {
        // Exactly at the skew cap: still trusted, and far ahead of the frontier ⇒ continue.
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = wallNow + 48L * 3600L,
                ourFrontierTs = wallNow - 86_400L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
            ),
        )
        // One second past the cap: excluded, and an empty session must not continue.
        assertFalse(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = wallNow + 48L * 3600L + 1L,
                ourFrontierTs = wallNow - 86_400L,
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
                rowsPersistedThisSession = 0,
            ),
        )
    }

    /** #928: mild clock skew (an hour ahead, i.e. a timezone hiccup or drift) stays inside the 48 h
     *  tolerance, so a genuinely-behind frontier still auto-continues exactly as before the clamp. */
    @Test
    fun mildFutureSkew_stillTrusted() {
        assertTrue(
            WhoopBleClient.shouldAutoContinue(
                stillConnected = true,
                strapNewestTs = wallNow + 3600L,           // an hour ahead: plausible skew, not a broken clock
                ourFrontierTs = wallNow - 86_400L,         // a real day of backlog
                wallNowUnix = wallNow,
                lastTrimAdvanced = true,
                consecutiveCount = 0,
            ),
        )
    }
}
