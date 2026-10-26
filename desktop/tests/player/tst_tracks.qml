import QtQuick
import QtTest
import Lumeo

// Audio and subtitles over a real mpv: download dt has an English dub and a
// Japanese soundtrack, and two English subtitles, Full (the default) and
// Honorifics; the database has a Russian one for it.
Item {
    id: root
    width: 1280
    height: 720

    Component {
        id: playerComponent
        Player { anchors.fill: parent }
    }

    TestCase {
        name: "Tracks"
        when: windowShown

        property var player
        property int asked
        readonly property string item: "tt0050083"

        function requests() {
            return fakeCore.requests.slice(asked)
        }

        function bodies(line) {
            return requests().filter(r => r.startsWith(line)).map(r => JSON.parse(r.slice(line.length + 1)))
        }

        function row(name) {
            const menu = findChild(player, "tracksMenu")
            return menu.visible ? findChild(menu, name) : null
        }

        function start() {
            player = createTemporaryObject(playerComponent, root, { downloadId: "dt", name: "The Seventh Seal" })
            player.forceActiveFocus()
            tryVerify(() => player.mpv.hasPicture && player.mpv.tracks.length >= 5, 10000, "playing, its tracks listed")
        }

        // Opened, answered and laid out: a click before then lands where the
        // rows are not yet, and a row the lookup adds lies at the top until
        // its column is laid out again.
        function openMenu() {
            keyClick(Qt.Key_C)
            tryVerify(() => !!row("subtitlesOff"), 5000, "the menu open")
            tryVerify(() => !row("looking"), 5000, "the database answered")
            verify(waitForPolish(row("subtitles")))
            verify(waitForRendering(findChild(player, "tracksMenu")))
        }

        // mpv's own value, asked until it is [expected].
        function readsBack(property, expected) {
            let value
            tryVerify(() => {
                player.mpv.get(property, v => value = v)
                return String(value).toUpperCase() === String(expected).toUpperCase()
            }, 5000, property + " is " + expected + ", not " + value)
        }

        function init() {
            // A property mpv does not take is a decision that did nothing.
            failOnWarning(/mpv refused/)
            asked = fakeCore.requests.length
            const download = fakeCore.read("download.json")
            Object.assign(download, { id: "dt", itemId: item, ready: true })
            fakeCore.answer("GET", "/api/v1/downloads/dt", 200, download)
            fakeCore.answer("GET", "/api/v1/downloads/dt/subtitles", 200, { subtitles: [] })
            fakeCore.answer("GET", "/api/v1/choices/" + item, 200, {})
            fakeCore.answer("PATCH", "/api/v1/choices/" + item, 200, {})
            fakeCore.answer("GET", "/api/v1/progress/" + item, 200, { entries: [] })
            fakeCore.answer("PUT", "/api/v1/progress/" + item, 200, {})
            fakeCore.answer("GET", "/api/v1/subtitles", 200, { subtitles: [{
                id: "ru", language: "ru", languageName: "Russian", name: "Seal.1957.ru",
                url: "/api/v1/subtitles/ru", providerId: "opensubtitles" }] })
        }

        // mpv chose by the preferences (English subtitles, always): the
        // file's default; the menu names the languages and tells the two
        // English tracks apart by their titles, on a line of their own.
        function test_theMenuListsTheFilesTracksAndTheDatabases() {
            start()
            compare(player.mpv.sid, "1")
            openMenu()
            compare(row("audio-1").label, "English")
            compare(row("audio-1").note, "English Dub · 1.0")
            verify(row("audio-1").current)
            compare(row("audio-2").label, "Japanese")
            compare(row("audio-2").note, "1.0")
            compare(row("subtitle-1").label, "English")
            compare(row("subtitle-1").note, "English Full")
            compare(row("subtitle-2").note, "English Honorifics")
            verify(row("subtitle-1").current)
            tryVerify(() => !!row("found-0"), 5000, "the database's copy listed")
            compare(row("found-0").label, "Russian")
        }

        // Several copies of a language are one row that opens into their
        // names, and stays open at the one on screen.
        function test_aLanguagesCopiesOpenFromItsRow() {
            fakeCore.answer("GET", "/api/v1/subtitles", 200, { subtitles: [
                { id: "ru1", language: "ru", languageName: "Russian", name: "Seal.1957.BD.ru", url: "/api/v1/subtitles/ru" },
                { id: "ru2", language: "ru", languageName: "Russian", name: "Seal.1957.DVD.ru", url: "/api/v1/subtitles/ru" }] })
            start()
            openMenu()
            tryVerify(() => !!row("group-online:ru"), 5000, "the language listed")
            compare(row("group-online:ru").count, 2)
            verify(!row("found-0"), "folded")
            mouseClick(row("group-online:ru"))
            tryVerify(() => !!row("found-1"))
            compare(row("found-1").label, "Seal.1957.DVD.ru")
            mouseClick(row("found-1"))
            tryVerify(() => player.mpv.tracks.some(t => t.type === "sub" && t.external && t.selected), 5000)
            openMenu()
            verify(row("found-1").current, "opened at the copy on screen")
        }

        // Kept for the title, so the next episode starts with them; mpv's own
        // choice is not the viewer's and is not kept.
        function test_tracksPickedByHandAreKeptForTheTitle() {
            start()
            openMenu()
            mouseClick(row("subtitle-2"))
            tryCompare(player.mpv, "sid", "2")
            verify(!findChild(player, "tracksMenu").visible, "a pick closes the menu")
            tryVerify(() => bodies("PATCH /api/v1/choices/" + item).length === 1)
            compare(JSON.stringify(bodies("PATCH /api/v1/choices/" + item)[0]),
                    JSON.stringify({ subtitle: { language: "eng", title: "English Honorifics" } }))

            openMenu()
            mouseClick(row("audio-2"))
            tryCompare(player.mpv, "aid", "2")
            tryVerify(() => bodies("PATCH /api/v1/choices/" + item).length === 2)
            compare(JSON.stringify(bodies("PATCH /api/v1/choices/" + item)[1]),
                    JSON.stringify({ audio: { language: "jpn", title: "Japanese" } }))

            // The rows are made again as mpv's list catches up with the pick.
            tryVerify(() => player.mpv.tracks.some(t => t.type === "audio" && t.id === 2 && t.selected))
            openMenu()
            mouseClick(row("subtitlesOff"))
            tryCompare(player.mpv, "sid", "no")
            tryVerify(() => bodies("PATCH /api/v1/choices/" + item).length === 3)
            compare(JSON.stringify(bodies("PATCH /api/v1/choices/" + item)[2]),
                    JSON.stringify({ subtitle: { off: true } }))
        }

        function test_theTitlesPicksArePlayedAgain() {
            fakeCore.answer("GET", "/api/v1/choices/" + item, 200, {
                audio: { language: "jpn", title: "Japanese" },
                subtitle: { language: "eng", title: "English Honorifics" } })
            start()
            tryCompare(player.mpv, "aid", "2")
            tryCompare(player.mpv, "sid", "2")
            // Ours, not the viewer's: nothing to remember.
            wait(100)
            compare(bodies("PATCH /api/v1/choices/" + item).length, 0)
        }

        function test_subtitlesTurnedOffForTheTitleStayOff() {
            fakeCore.answer("GET", "/api/v1/choices/" + item, 200, { subtitle: { off: true } })
            start()
            tryCompare(player.mpv, "sid", "no")
        }

        // Fetched by the core and handed to mpv as a file, never as the
        // address (decisions/subtitles.md).
        function test_aDatabaseSubtitleIsHandedToMpvAsAFile() {
            start()
            openMenu()
            tryVerify(() => !!row("found-0"))
            mouseClick(row("found-0"))
            tryVerify(() => player.mpv.tracks.some(t => t.type === "sub" && t.external && t.selected), 5000)
            const track = player.mpv.tracks.find(t => t.type === "sub" && t.external)
            verify(!track["external-filename"].startsWith("http"), track["external-filename"])
            compare(track.lang, "ru")
            openMenu()
            verify(row("found-0").current, "the copy on screen is lit")
        }

        // The last pick wins: a file that arrives after Off stays off screen.
        function test_subtitlesTurnedOffWhileThePickedOnesDownloadStayOff() {
            start()
            openMenu()
            tryVerify(() => !!row("found-0"))
            fakeCore.hold("GET", "/api/v1/subtitles/ru")
            mouseClick(row("found-0"))
            tryVerify(() => requests().some(r => r.startsWith("GET /api/v1/subtitles/ru")))
            openMenu()
            mouseClick(row("subtitlesOff"))
            tryCompare(player.mpv, "sid", "no")
            fakeCore.release()
            // The file's answer and mpv's, had it been added.
            wait(300)
            compare(player.mpv.sid, "no")
            verify(!player.mpv.tracks.some(t => t.external), "not handed to mpv")
        }

        // A delay is a fact about one copy: it comes back with this episode
        // and goes out with its position.
        function test_aSubtitleDelayComesBackWithTheEpisode() {
            fakeCore.answer("GET", "/api/v1/progress/" + item, 200,
                            { entries: [{ season: 0, episode: 0, position: 0, duration: 20, subtitleDelay: 1.5 }] })
            start()
            tryCompare(player.mpv, "subDelay", 1.5)
            keyClick(Qt.Key_Space)
            tryVerify(() => bodies("PUT /api/v1/progress/" + item).length > 0, 5000)
            compare(bodies("PUT /api/v1/progress/" + item).pop().subtitleDelay, 1.5)
        }

        // The size, height and edge are mpv's properties, read back from it.
        function test_theStyleIsDrawnByMpv() {
            start()
            readsBack("sub-font-size", 48)
            readsBack("sub-margin-y", 36)
            readsBack("sub-color", "#FFFFFFFF")
            readsBack("sub-ass-override", "scale")
            openMenu()
            const menu = findChild(player, "tracksMenu")
            mouseClick(findChild(menu, "subtitleStyle"))
            tryVerify(() => !!findChild(menu, "background-box")?.visible)
            verify(waitForRendering(menu))
            // The box reaches mpv as its colour whichever way this mpv draws
            // it: sub-border-style exists from 0.38 on (Tracks::backgroundProperties).
            mouseClick(findChild(menu, "background-box"))
            readsBack("sub-back-color", SubtitleStyle.boxColour)
            compare(player.playback.tracks.background, "box")
            mouseClick(findChild(menu, "size-3"))
            tryCompare(player.mpv, "subScale", 1.5)
            mouseClick(findChild(menu, "background-none"))
            readsBack("sub-back-color", "#00000000")
        }
    }
}
