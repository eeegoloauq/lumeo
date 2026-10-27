import QtQuick
import QtTest
import Lumeo

Item {
    id: window
    width: 1440
    height: 900

    Component { id: shellComponent; Shell { anchors.fill: parent; focus: true } }

    SignalSpy { id: watched; signalName: "watch" }
    SignalSpy { id: trailered; signalName: "trailer" }

    TestCase {
        name: "Title"
        when: windowShown

        property var shell
        // Where this test's requests start in the fake core's log.
        property int asked

        function requests() {
            return fakeCore.requests.slice(asked)
        }

        readonly property var copy: ({
            providerId: "torrentio",
            rawName: "Nosferatu 1922 1080p BluRay x264",
            release: { resolution: "1080p", source: "BluRay", group: "GROUP" },
            locator: { scheme: "torrent", infoHash: "abc", fileIndex: 0 },
        })
        readonly property var other: ({
            providerId: "torrentio",
            rawName: "Nosferatu 1922 720p WEB x264",
            release: { resolution: "720p", source: "WEB", group: "OTHER" },
            locator: { scheme: "torrent", infoHash: "def", fileIndex: 0 },
        })

        function cleanup() {
            if (Preferences.current.askCopy) {
                const prefs = fakeCore.read("preferences.json")
                fakeCore.answer("PATCH", "/api/v1/preferences", 200, prefs)
                Preferences.patch({ askCopy: false })
                tryVerify(() => !Preferences.current.askCopy)
            }
        }

        // The title page of a film from the banner, its copies listed: Play
        // is on while they are asked for, the line under it only once here.
        function film() {
            mouseClick(findChild(shell, "moreInfo"))
            tryVerify(() => !!findChild(shell, "playLineChoose")?.enabled, 5000, "the copies listed")
        }

        // A row of the copies' drawer, which lives over the window rather
        // than in the page.
        function row(name) {
            const drawer = findChild(shell, "sourcesDrawer")
            return drawer.opened ? findChild(drawer.contentItem, name) : null
        }

        function openDrawer() {
            const line = findChild(shell, "playLineChoose")
            verify(waitForPolish(line.parent))
            mouseClick(line)
            // Opened once its slide is over, and its rows are laid out by then.
            tryVerify(() => !!row("copy-1"), 5000, "the drawer open")
            return row("copy-1")
        }

        function init() {
            const items = []
            for (let i = 0; i < 3; ++i) {
                const film = { id: "tt" + (2000 + i), kind: "movie", title: "Film " + i, year: 1920 + i }
                items.push(film)
                fakeCore.answer("GET", "/api/v1/items/" + film.id, 200, film)
                fakeCore.answer("GET", "/api/v1/progress/" + film.id, 200, {})
                fakeCore.answer("GET", "/api/v1/list/" + film.id, 200, { inList: false })
                fakeCore.answer("PUT", "/api/v1/list/" + film.id, 200, { inList: true })
                fakeCore.answer("GET", "/api/v1/ratings/" + film.id, 200, { ratings: [] })
                fakeCore.answer("PUT", "/api/v1/ratings/" + film.id, 200, { rating: 7 })
            }
            fakeCore.answer("GET", "/api/v1/catalog", 200, { items: items })
            fakeCore.answer("GET", "/api/v1/sources", 200, { sources: [copy, other], providers: 1 })
            fakeCore.answer("PATCH", "/api/v1/choices/tt2001", 200, {})
            fakeCore.answer("PATCH", "/api/v1/choices/tt2002", 200, {})
            fakeCore.answer("POST", "/api/v1/downloads", 201, { id: "d1", itemId: "tt2001", state: "active" })
            asked = fakeCore.requests.length
            shell = createTemporaryObject(shellComponent, window)
            watched.clear()
            watched.target = shell
            tryVerify(() => findChild(shell, "play") !== null, 5000, "the hero")
            waitForRendering(shell)
        }

        // Play in the banner opened the title without starting it, and later
        // started it without a download behind it.
        function test_playInTheBannerStartsTheTitle() {
            mouseClick(findChild(shell, "play"))
            compare(shell.page, "title")
            watched.wait(5000)
            compare(watched.signalArguments[0][0], "d1")
        }

        // Trailers are offered where yt-dlp can play them, all in the
        // metadata's order, with the title's Play to start from them.
        function test_theTrailerPlaysWhereYtdlpIs() {
            for (let i = 0; i < 3; ++i)
                fakeCore.answer("GET", "/api/v1/items/tt" + (2000 + i), 200, {
                    id: "tt" + (2000 + i), kind: "movie", title: "Film " + i, year: 1920 + i,
                    trailers: ["https://www.youtube.com/watch?v=0000trailer", "https://www.youtube.com/watch?v=1111trailer"] })
            LocalSettings.trailerPreviews = false
            film()
            const button = findChild(shell, "trailerButton")
            verify(!button.visible, "no trailer without yt-dlp")

            MpvFacts.ytdl = true
            trailered.target = shell
            trailered.clear()
            verify(waitForPolish(button.parent))
            mouseClick(button)
            compare(trailered.count, 1)
            const [trailer, name] = trailered.signalArguments[0]
            compare(trailer.urls, ["https://www.youtube.com/watch?v=0000trailer", "https://www.youtube.com/watch?v=1111trailer"])
            compare(trailer.play, "Play")
            trailer.played()
            watched.wait(5000)
            compare(watched.signalArguments[0][0], "d1")
            compare(watched.signalArguments[0][1], name)

            MpvFacts.ytdl = false
            LocalSettings.trailerPreviews = true
        }

        function test_moreInfoOpensTheTitleAndStartsNothing() {
            mouseClick(findChild(shell, "moreInfo"))
            compare(shell.page, "title")
            tryVerify(() => findChild(shell, "titlePlay")?.enabled, 5000, "the copies listed")
            wait(50)
            compare(watched.count, 0)
            compare(posted().length, 0)
        }

        // A series never watched, opened on its first episode with the
        // keyboard on it.
        function series() {
            const show = openSeries({}, null)
            const strip = findChild(shell, "episodes")
            tryVerify(() => strip.itemAtIndex(0)?.activeFocus, 5000, "the first episode has the keyboard")
            return show
        }

        function openSeries(progress, at) {
            const show = fakeCore.read("items.json").find(item => item.kind === "series")
            fakeCore.answer("GET", "/api/v1/items/" + show.id, 200, show)
            fakeCore.answer("GET", "/api/v1/progress/" + show.id, 200, progress)
            shell.open(show, false, at)
            tryVerify(() => !!findChild(shell, "titlePlay")?.text.includes(" S"), 5000, "the episodes")
            return show
        }

        function posted() {
            return requests().filter(r => r.startsWith("POST /api/v1/downloads"))
        }

        // The arrows walk the season with the selection; Enter plays what
        // they reached, and a run of steps asks for one list, not one per card.
        function test_theArrowsChooseAnEpisodeAndEnterPlaysIt() {
            series()
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(findChild(shell, "titlePlay").text, "Play S1 E3")
            keyClick(Qt.Key_Return)
            watched.wait(5000)
            verify(posted().length === 1 && posted()[0].includes('"episode":3'), posted()[0])
            verify(!requests().some(r => r.includes("/api/v1/sources") && r.includes("episode=2")),
                   "no list for the episode passed over")
        }

        // Specials aside, the arrows go on into the next season.
        function test_theArrowsCrossIntoTheNextSeason() {
            series()
            for (let i = 0; i < 6; ++i)
                keyClick(Qt.Key_Right)
            compare(findChild(shell, "titlePlay").text, "Play S2 E1")
            verify(findChild(shell, "season-2"), "two seasons, two tabs")
            keyClick(Qt.Key_Left)
            compare(findChild(shell, "titlePlay").text, "Play S1 E6")
        }

        function test_aSeasonTabShowsItsEpisodes() {
            series()
            mouseClick(findChild(shell, "season-2"))
            const strip = findChild(shell, "episodes")
            compare(strip.count, 1)
            compare(findChild(shell, "titlePlay").text, "Play S2 E1")
        }

        // Opened on another season, as a new episode opens it, a season still
        // goes on where it was left.
        function test_aSeasonGoesOnWhereItWasLeft() {
            openSeries({ entries: [{ season: 1, episode: 3, position: 0, duration: 2900, watched: true,
                                     updatedAt: "2026-09-01T00:00:00Z" }] }, { season: 2, episode: 1 })
            compare(findChild(shell, "titlePlay").text, "Play S2 E1")
            mouseClick(findChild(shell, "season-1"))
            compare(findChild(shell, "titlePlay").text, "Play S1 E4")
        }

        // Back from the player the page is where watching now goes on, not
        // on the episode it was left on.
        function test_thePageGoesOnFromWhatWasWatchedSince() {
            const show = series()
            keyClick(Qt.Key_Right)
            compare(findChild(shell, "titlePlay").text, "Play S1 E2")
            fakeCore.answer("GET", "/api/v1/progress/" + show.id, 200, {
                entries: [{ season: 1, episode: 2, position: 0, duration: 2900, watched: true,
                            updatedAt: "2026-09-01T00:00:00Z" }],
                next: { season: 1, episode: 3, position: 0, duration: 0, watched: false,
                        updatedAt: "2026-09-01T00:00:00Z" } })
            shell.visible = false
            shell.visible = true
            tryCompare(findChild(shell, "titlePlay"), "text", "Play S1 E3")
        }

        // Continue watching plays where watching goes on. The page passes
        // through season 0 as the title arrives, and that once started a special.
        function test_playFromContinueStartsTheNextEpisodeNotASpecial() {
            const base = fakeCore.read("items.json").find(item => item.kind === "series")
            const show = Object.assign({}, base, { episodes: base.episodes.concat([{ season: 0, number: 1 }]) })
            fakeCore.answer("GET", "/api/v1/items/" + show.id, 200, show)
            fakeCore.answer("GET", "/api/v1/progress/" + show.id, 200, {
                entries: [{ season: 0, episode: 1, position: 300, duration: 1400, watched: false,
                            updatedAt: "2026-09-01T00:00:00Z" },
                          { season: 1, episode: 3, position: 0, duration: 2900, watched: true,
                            updatedAt: "2026-09-02T00:00:00Z" }],
                next: { season: 1, episode: 4, position: 0, duration: 0, watched: false,
                        updatedAt: "2026-09-02T00:00:00Z" } })
            fakeCore.answer("POST", "/api/v1/downloads", 201, { id: "d1", itemId: show.id, state: "active" })
            shell.open(show, true, null)
            watched.wait(5000)
            verify(posted().length === 1 && posted()[0].includes('"season":1') && posted()[0].includes('"episode":4'),
                   posted()[0])
        }

        // A pick is the title's release, which the core keeps, so the next
        // episode goes on from it; nothing starts.
        function test_aCopyPickedInTheDrawerIsTheTitlesRelease() {
            film()
            mouseClick(openDrawer())
            tryVerify(() => requests().some(r => r.startsWith("PATCH /api/v1/choices/") && r.includes("720p WEB")))
            tryVerify(() => !findChild(shell, "sourcesDrawer").visible, 2000, "the drawer closed")
            compare(posted().length, 0)
        }

        function test_automaticForgetsTheRelease() {
            film()
            openDrawer()
            mouseClick(row("best"))
            tryVerify(() => requests().some(r => r.startsWith("PATCH /api/v1/choices/") && r.includes('{"source":null}')))
        }

        // "Ask every time": Play opens the copies, and the one picked plays.
        function test_askEveryTimeOpensTheCopiesAndPlaysThePick() {
            const prefs = fakeCore.read("preferences.json")
            prefs.askCopy = true
            fakeCore.answer("PATCH", "/api/v1/preferences", 200, prefs)
            Preferences.patch({ askCopy: true })
            tryVerify(() => Preferences.current.askCopy)
            film()
            mouseClick(findChild(shell, "titlePlay"))
            tryVerify(() => !!row("copy-1"), 5000, "the drawer open")
            compare(posted().length, 0)
            // What the core answers once the pick is recorded.
            const picked = Object.assign({ lastUsed: true }, other)
            fakeCore.answer("GET", "/api/v1/sources", 200, { sources: [copy, picked], providers: 1 })
            mouseClick(row("copy-1"))
            watched.wait(5000)
            verify(posted()[0].includes("720p WEB"), posted()[0])
        }

        // Both change at once and go to the core behind the change.
        // A copy nothing here decodes stays in the drawer, marked, and Play
        // starts the next one; the same copy plays on the next machine.
        function test_aCopyThisMachineCannotDecodeIsMarkedAndNotPlayed() {
            tryVerify(() => MpvFacts.answered, 5000, "mpv's decoders")
            MpvFacts.setDecoders([{ codec: "h264" }, { codec: "aac" }])
            const hevc = Object.assign({}, copy, { rawName: "Nosferatu 1922 2160p x265",
                release: { resolution: "2160p", videoCodec: "HEVC", audioCodec: "AAC" } })
            fakeCore.answer("GET", "/api/v1/sources", 200, { sources: [hevc, other], providers: 1 })
            film()
            openDrawer()
            compare(findChild(row("copy-0"), "decoderMark").text, "no hevc here")
            const drawer = findChild(shell, "sourcesDrawer")
            drawer.close()
            tryVerify(() => !drawer.visible)
            mouseClick(findChild(shell, "titlePlay"))
            tryVerify(() => posted().length === 1, 5000)
            verify(posted()[0].includes("720p WEB"), posted()[0])
            MpvFacts.setDecoders([{ codec: "h264" }, { codec: "hevc" }, { codec: "aac" }])
        }

        function test_myListAndTheScoreReachTheCore() {
            film()
            const list = findChild(shell, "listButton")
            tryVerify(() => list.enabled, 5000, "the core said")
            mouseClick(list)
            compare(list.glyph, "check")
            tryVerify(() => requests().some(r => r.startsWith("PUT /api/v1/list/")))

            const rating = findChild(shell, "ratingButton")
            mouseClick(rating)
            const scores = findChild(rating, "ratingScale")
            tryVerify(() => scores.opened)
            // Under the button, at the banner's foot, it ran off the window.
            const box = scores.background.mapToItem(window, 0, 0, scores.width, scores.height)
            verify(box.y + box.height <= window.height && box.x + box.width <= window.width,
                   "the scale is inside the window: " + JSON.stringify(box))
            mouseClick(findChild(scores.contentItem, "score-7"))
            compare(rating.score, 7)
            tryVerify(() => requests().some(r => r.startsWith("PUT /api/v1/ratings/") && r.includes('"rating":7')))
        }

        // None ships with the app: the empty list is the way to add one.
        function test_noSourceAddonLeadsToTheSettings() {
            fakeCore.answer("GET", "/api/v1/sources", 200, { sources: [], providers: 0 })
            mouseClick(findChild(shell, "moreInfo"))
            const add = findChild(shell, "playLineAction")
            tryVerify(() => add.visible, 5000, "Add one")
            // Placed in its row, so the pointer lands on it.
            verify(waitForPolish(add.parent))
            fakeCore.answer("GET", "/api/v1/addons", 200, { addons: [] })
            mouseClick(add)
            compare(shell.page, "settings")
            const settings = findChild(shell, "settings")
            tryCompare(settings, "lit", "sources")

            // A source of copies added there offers the way back.
            fakeCore.answer("POST", "/api/v1/addons", 200, {
                id: "copies", name: "Copies", url: "https://copies.example", enabled: true, resources: ["stream"],
            })
            const address = findChild(settings, "address")
            tryVerify(() => address.visible, 2000)
            address.forceActiveFocus()
            address.text = "https://copies.example"
            keyClick(Qt.Key_Return)
            const back = findChild(settings, "backTo")
            tryVerify(() => back.visible, 2000, "the way back")
            verify(waitForPolish(back.parent))
            mouseClick(back)
            compare(shell.page, "title")
        }
    }
}
