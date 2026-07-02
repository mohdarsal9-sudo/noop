package com.noop.analytics

import java.time.Instant
import java.time.ZoneId

/**
 * Pure guards for the hand-edit sleep-time pickers (#940). The reporter corrected a late-tracked
 * night's bed time from 01:06 back to 23:00; the picker kept the calendar DATE, so the "corrected"
 * bed landed on the COMING evening: a future-dated night whose staged window came back all-awake,
 * and the Sleep tab then hid the intact history behind it. Three layered rules, the byte-for-byte
 * twin of Swift StrandAnalytics.SleepEditGuard, all pure and unit-tested:
 *   1. [autoCorrectedBed]: a time-only roll that lands the bed in the future, or at/after the
 *      night's wake, almost always means the PREVIOUS evening; auto-decrement the date.
 *   2. [isDisjoint]: a corrected window with no overlap of the night's recorded coverage needs an
 *      explicit confirm ("this moves the night to a time with no recorded data"), never silent
 *      acceptance.
 *   3. [clampedEditWindow]: the repository belt-and-braces; no code path may persist a future or
 *      inverted window even if a client UI misbehaves.
 */
object SleepEditGuard {

    /**
     * Rule 1: the cross-midnight bed auto-correct. [candidateBedTs] is what the picker just
     * produced, [previousBedTs] the value it held before this change (a DELIBERATE date change,
     * where the two sit on different calendar days, is always respected verbatim; the Android
     * picker is time-only, so this always holds there). When the change was time-only (same
     * calendar day) and the candidate is impossible for a bed time (in the future, or at/after
     * [originalWakeTs], the night's CURRENT wake), the user almost always meant the previous
     * evening: return the candidate moved one day back, provided that lands in the past.
     * [originalWakeTs] is null for the "Add a nap" picker, whose anchor deliberately sits after
     * the night's wake, so only the future test applies there. All timestamps unix seconds.
     */
    fun autoCorrectedBed(
        previousBedTs: Long,
        candidateBedTs: Long,
        originalWakeTs: Long?,
        nowTs: Long,
        zone: ZoneId = ZoneId.systemDefault(),
    ): Long {
        val prevDay = Instant.ofEpochSecond(previousBedTs).atZone(zone).toLocalDate()
        val candZoned = Instant.ofEpochSecond(candidateBedTs).atZone(zone)
        if (candZoned.toLocalDate() != prevDay) return candidateBedTs
        val violates = candidateBedTs > nowTs ||
            (originalWakeTs != null && candidateBedTs >= originalWakeTs)
        if (!violates) return candidateBedTs
        // minusDays is DST-correct: "the same wall-clock time one calendar day earlier".
        val decremented = candZoned.minusDays(1).toEpochSecond()
        return if (decremented <= nowTs) decremented else candidateBedTs
    }

    /**
     * Rule 2: true when the corrected window `[newStart, newEnd)` shares NOTHING with the night's
     * recorded coverage `[coverageStart, coverageEnd)` (unix seconds). A disjoint window has no
     * data to stage from, so accepting it silently fabricates an all-awake phantom night; the UI
     * must confirm the move instead.
     */
    fun isDisjoint(newStart: Long, newEnd: Long, coverageStart: Long, coverageEnd: Long): Boolean =
        newEnd <= coverageStart || newStart >= coverageEnd

    /**
     * Rule 3: the persistence belt-and-braces. Caps the corrected wake at `nowTs + slackSec` (a
     * sleep cannot END in the future; the slack absorbs clock skew) and refuses (null) any window
     * that is inverted or entirely in the future once capped. The editor's own guards should make
     * this unreachable; it exists so NO client code path can write a phantom night the display
     * merge cannot render.
     */
    fun clampedEditWindow(start: Long, end: Long, nowTs: Long, slackSec: Long = 300L): Pair<Long, Long>? {
        val cappedEnd = minOf(end, nowTs + slackSec)
        if (cappedEnd <= start) return null
        return start to cappedEnd
    }
}
