import QtQuick
import QtTest
import Lumeo

// A frame from the file of an episode on disk, for a card the catalogue has
// no still for: e1 is that episode, and on disk.
Item {
    id: root
    width: 640
    height: 360

    Component {
        id: stillComponent
        EpisodeStill { width: 320; height: 180 }
    }

    TestCase {
        name: "Stills"
        when: windowShown

        function test_anEpisodeOnDiskWithoutAStillShowsAFrameOfItsFile() {
            const download = fakeCore.read("download.json")
            Object.assign(download, { id: "e1", itemId: "tt0052520", season: 1, episode: 1, state: "done" })
            fakeCore.answer("GET", "/api/v1/downloads", 200, { downloads: [download] })
            Downloads.refresh()
            const key = "tt0052520/1/1"
            tryVerify(() => !!EpisodeFrames.known[key], 10000, "a frame taken")
            const still = createTemporaryObject(stillComponent, root, {
                episode: { season: 1, number: 1, title: "Where Is Everybody?" },
                frame: EpisodeFrames.known[key],
            })
            const picture = still.children.find(c => c instanceof Image)
            tryCompare(picture, "status", Image.Ready, 5000)
            verify(picture.sourceSize.width > 0)
            fakeCore.answer("GET", "/api/v1/downloads", 200, { downloads: [] })
        }
    }
}
