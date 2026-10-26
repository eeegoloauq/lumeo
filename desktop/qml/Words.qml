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
        const date = new Date(utc.getUTCFullYear(), utc.getUTCMonth(), utc.getUTCDate())
        const locale = Qt.locale()
        return date.toLocaleDateString(locale, locale.name.startsWith("en") ? "MMM d" : "d MMM")
    }
}
