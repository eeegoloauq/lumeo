pragma Singleton
import QtQuick

// How the core's facts read on screen, the same wherever they appear: a
// copy, a size, a provider that failed, a date.
QtObject {
    function padded(n) {
        return n < 10 ? "0" + n : String(n)
    }

    // 1:05:09, or 4:07 under an hour.
    function clock(seconds) {
        const s = Math.max(0, Math.floor(seconds))
        const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60)
        return (h > 0 ? h + ":" + padded(m) : m) + ":" + padded(s % 60)
    }

    // "12 min left", or "1 h 05 min left".
    function timeLeft(seconds) {
        const minutes = Math.ceil(seconds / 60)
        if (minutes < 60)
            return qsTrId("downloadsTimeLeftMinutes", minutes)
        return qsTrId("downloadsTimeLeftHours", Math.floor(minutes / 60)).arg(padded(minutes % 60))
    }

    // A span as the downloads panel says it: "12 min", "1 h 5 min", "2 h";
    // rounded up, so a few seconds away is never "0 min".
    function minutes(seconds) {
        const m = Math.max(1, Math.ceil(seconds / 60))
        if (m < 60)
            return qsTrId("downloadsMinutes", m)
        return m % 60 === 0 ? qsTrId("downloadsHours", m / 60)
                            : qsTrId("downloadsHoursMinutes", Math.floor(m / 60))
                                  .arg(qsTrId("downloadsHoursMinutes_minutes", m % 60))
    }

    // The catalogue's name for an episode, or empty when it is only "Episode 3".
    function episodeTitle(episode) {
        const title = episode?.title ?? ""
        return title && title !== "Episode " + episode.number ? title : ""
    }

    // "Episode 3 · The Title", or "Episode 3" when the catalogue's title is
    // only that.
    function episodeName(episode) {
        const named = episodeTitle(episode)
        return named ? qsTrId("itemEpisodeNamed").arg(episode.number).arg(named)
                     : qsTrId("itemEpisodeNumber").arg(episode.number)
    }

    function count(n) {
        return Number(n).toLocaleString(Qt.locale(), "f", 0)
    }

    // Under a poster on My list, what the poster cannot say: how far the
    // viewer is, the kind only when there is neither that nor a score.
    function listedCaption(listed) {
        const watched = listed.seen?.watched ?? 0, released = listed.seen?.released ?? 0
        const series = listed.item.kind === "series"
        const seen = series ? (watched > 0 && released > 0
                               ? (watched >= released ? qsTrId("libraryWatched")
                                                      : qsTrId("libraryWatchedOf").arg(count(watched)).arg(count(released)))
                               : "")
                            : (watched > 0 ? qsTrId("libraryWatched") : "")
        if (seen === "" && !listed.rating)
            return series ? qsTrId("commonSeries") : qsTrId("commonFilm")
        return seen
    }

    // Which episode is new and when it came out: "S4 E18 · Today", with how
    // many there are when there are more.
    function newEpisodeCaption(found) {
        const e = found.episode, n = found.count ?? 1
        // Released at the provider's midnight UTC: that day, and today as UTC
        // has it, are the pair that belong together.
        const date = e.released ? dayLabel(e.released.slice(0, 10), new Date().toISOString().slice(0, 10)) : ""
        if (date && n > 1)
            return qsTrId("libraryNewEpisodeDateCount", n).arg(e.season).arg(e.number).arg(date)
        if (date)
            return qsTrId("libraryNewEpisodeDate").arg(e.season).arg(e.number).arg(date)
        if (n > 1)
            return qsTrId("libraryNewEpisodeCount", n).arg(e.season).arg(e.number)
        return qsTrId("libraryNewEpisode").arg(e.season).arg(e.number)
    }

    // A history line's title: the series and the episode, or the film.
    function viewingTitle(item, entry, episode) {
        if (item.kind !== "series")
            return item.title
        const named = episodeTitle(episode)
        return named ? qsTrId("libraryViewingNamedTitle").arg(item.title).arg(entry.season).arg(entry.episode).arg(named)
                     : qsTrId("libraryViewingTitle").arg(item.title).arg(entry.season).arg(entry.episode)
    }

    // Where a viewing was left: the time still to go, or that it was finished.
    function viewingState(entry) {
        if (entry.position > 0 && entry.duration > entry.position)
            return timeLeft(entry.duration - entry.position)
        return entry.watched ? qsTrId("libraryWatched") : qsTrId("libraryStarted")
    }

    // 4.2 GB: powers of 1024, one decimal under a hundred.
    function bytes(value) {
        if (value <= 0)
            return "—"
        const units = [qsTrId("downloadsByteUnit"), qsTrId("downloadsKilobyteUnit"),
                       qsTrId("downloadsMegabyteUnit"), qsTrId("downloadsGigabyteUnit"),
                       qsTrId("downloadsTerabyteUnit")]
        let v = value, unit = 0
        while (v >= 1024 && unit < units.length - 1) {
            v /= 1024
            ++unit
        }
        const size = Number(v).toLocaleString(Qt.locale(), "f", v >= 100 || unit === 0 ? 0 : 1)
        return qsTrId("downloadsSize").arg(size).arg(units[unit])
    }

    // What the copy is, without the resolution: a season pack, a remux or
    // its source, its HDR.
    function releaseKind(release) {
        const parts = []
        if (release.season > 0 && !release.episode)
            parts.push(qsTrId("downloadsSeasonPack").arg(padded(release.season)))
        if (release.remux)
            parts.push(qsTrId("downloadsRemux"))
        else if (release.source)
            parts.push(release.source)
        if (release.hdr?.length)
            parts.push(release.hdr[0])
        return parts.join(" · ")
    }

    // Who made the copy, else where it was found, and what it is.
    function sourceTitle(source) {
        const release = source.release ?? {}
        return [release.group || source.tracker || "", releaseKind(release)]
               .filter(part => part !== "").join(" · ")
    }

    // A provider's failure as what it means: a 403 is a block, not an empty
    // list, and a 503 an outage that goes away on its own.
    function providerFailure(failure) {
        const status = failure.status ?? 0
        if (status === 0)
            return qsTrId("playerProviderNoAnswer").arg(failure.provider)
        if (status === 401 || status === 403)
            return qsTrId("playerProviderBlocked").arg(failure.provider).arg(status)
        if (status === 429)
            return qsTrId("playerProviderLimited").arg(failure.provider)
        if (status >= 500)
            return qsTrId("playerProviderDown").arg(failure.provider).arg(status)
        return qsTrId("playerProviderError").arg(failure.provider).arg(failure.reason)
    }

    // Oct 25, or 25 окт.: the day and the month, as the reader writes them.
    function shortDate(iso) {
        // The provider dates a release at midnight UTC: that day, wherever
        // the reader is.
        const utc = new Date(iso)
        return dayMonth(new Date(utc.getUTCFullYear(), utc.getUTCMonth(), utc.getUTCDate()), false)
    }

    function dayMonth(date, year) {
        const english = Qt.locale().name.startsWith("en")
        const format = english ? (year ? "MMM d, yyyy" : "MMM d") : (year ? "d MMM yyyy" : "d MMM")
        return date.toLocaleDateString(Qt.locale(), format)
    }

    // A day as somebody says it: Today, Yesterday, the weekday within the
    // last week, the date after that, and the year only when it is not this
    // one. Both are calendar dates, "2026-10-26"; [today] is this machine's
    // when not given.
    function dayLabel(day, today) {
        const date = (iso => new Date(iso.slice(0, 4), iso.slice(5, 7) - 1, iso.slice(8, 10)))
        const now = new Date()
        const base = today ? date(today) : new Date(now.getFullYear(), now.getMonth(), now.getDate())
        const then = date(day)
        // Rounded: a day that changes the clocks is an hour short or long.
        const days = Math.round((base - then) / 86400000)
        if (days === 0)
            return qsTrId("libraryToday")
        if (days === 1)
            return qsTrId("libraryYesterday")
        if (days > 1 && days < 7)
            return then.toLocaleDateString(Qt.locale(), "ddd")
        return dayMonth(then, then.getFullYear() !== base.getFullYear())
    }
}
