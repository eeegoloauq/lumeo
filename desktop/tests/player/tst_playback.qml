import QtQuick
import QtTest
import Lumeo

Item {
    width: 640
    height: 360

    MpvItem {
        id: mpv
        anchors.fill: parent
    }

    TestCase {
        name: "Playback"
        when: windowShown

        // The player's whole path: mpv opens the file, plays it through the
        // render thread, and its properties come back observed.
        function test_aFilePlaysAndItsPositionMoves() {
            verify(testClip !== "", "LUMEO_TEST_CLIP names the clip")
            mpv.open(testClip)
            tryVerify(() => mpv.duration > 0, 10000)
            const from = mpv.position
            tryVerify(() => mpv.position > from + 0.5, 10000)
            verify(!mpv.paused)
        }
    }
}
