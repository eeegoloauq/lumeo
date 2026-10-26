import QtQuick
import QtTest
import Lumeo

// Frames out of the film over a real mpv: the seek bar's previews, from a
// second mpv, and mpv's own screenshots. d1 is the test card.
Item {
    id: root
    width: 1280
    height: 720

    Component {
        id: playerComponent
        Player { anchors.fill: parent }
    }

    TestCase {
        name: "Frames"
        when: windowShown

        property var player

        function playing() {
            const download = fakeCore.read("download.json")
            Object.assign(download, { id: "d1", ready: true })
            fakeCore.answer("GET", "/api/v1/downloads/d1", 200, download)
            fakeCore.answer("GET", "/api/v1/progress/tt0063350", 200, { entries: [] })
            fakeCore.answer("PUT", "/api/v1/progress/tt0063350", 200, {})
            player = createTemporaryObject(playerComponent, root, { downloadId: "d1", name: "Night of the Living Dead" })
            player.forceActiveFocus()
            tryVerify(() => player.mpv.hasPicture, 10000, "playing")
        }

        function cleanup() {
            LocalSettings.timelinePreviews = true
        }

        // The frame under the pointer, made when it gets there and dropped
        // when it leaves.
        function test_theBarShowsTheFrameUnderThePointer() {
            playing()
            const bar = findChild(player, "seekBar")
            const frame = findChild(bar, "previewFrame")
            mouseMove(player, player.width / 2, player.height - 30)
            mouseMove(bar, bar.width * 0.5, bar.height / 2)
            tryVerify(() => frame.visible, 10000, "a frame under the pointer")
            verify(frame.width > 150 && frame.height > 80, frame.width + "×" + frame.height)
            // The picture itself, opaque: the test card is in colour where
            // the frame's edge is white.
            verify(waitForRendering(frame))
            const middle = frame.mapToItem(root, frame.width / 2, frame.height / 2)
            const shot = grabImage(root)
            const pixel = shot.pixel(middle.x, middle.y)
            verify(pixel.a > 0.99 && !Qt.colorEqual(pixel, "white"), "a picture in the frame, not " + pixel)
            mouseMove(player, player.width / 2, player.height / 2)
            tryVerify(() => !frame.visible, 5000, "gone with the pointer")
        }

        // Off in the settings, no second mpv is made for the bar.
        function test_previewsOffMakeNoSecondMpv() {
            LocalSettings.timelinePreviews = false
            playing()
            compare(player.playback.previews, null)
            const bar = findChild(player, "seekBar")
            mouseMove(player, player.width / 2, player.height - 30)
            mouseMove(bar, bar.width * 0.5, bar.height / 2)
            verify(!findChild(bar, "previewFrame").visible)
        }

        // mpv's `s` takes a frame, named after the film, into the folder the
        // settings name, drawn by the GPU renderer.
        function test_aScreenshotIsTakenIntoTheChosenFolder() {
            playing()
            const before = disk.list(screenshots).length
            keyClick(Qt.Key_S)
            tryVerify(() => disk.list(screenshots).length > before, 10000, "a file in " + screenshots)
            verify(disk.list(screenshots).some(f => f.startsWith("Night of the Living Dead ")),
                   disk.list(screenshots).join(", "))
        }
    }
}
