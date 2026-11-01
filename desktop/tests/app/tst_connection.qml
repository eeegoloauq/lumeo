import QtQuick
import QtTest
import QtQuick.Controls.Basic
import Lumeo

Item {
    id: window
    width: 1440
    height: 900

    Component { id: shellComponent; Shell { anchors.fill: parent; focus: true } }

    TestCase {
        name: "Connection"
        when: windowShown

        readonly property string media: "https://media.example.com"

        // Read by CoreConnection when Settings first asks for it.
        function initTestCase() {
            fakeCore.answer("GET", "/api/v1/link", 200, { url: media, running: media, saved: [media] })
            fakeCore.answer("PATCH", "/api/v1/link", 200, { url: "", running: media, saved: [media] })
            fakeCore.answer("DELETE", "/api/v1/link", 200, { url: "", running: media, saved: [] })
        }

        function asked(request) {
            return fakeCore.requests.some(line => line.startsWith(request))
        }

        function test_aSavedMediaServerIsChosenAndForgottenThroughThisMachinesCore() {
            const shell = createTemporaryObject(shellComponent, window)
            mouseClick(findChild(shell, "tab-settings"))
            const thisComputer = findChild(shell, "useThisComputer")
            tryVerify(() => thisComputer?.visible === true)
            verify(!findChild(shell, "restartCore").visible)
            // The rows came with the core's answer: placed, then clicked.
            waitForPolish(shell.Window.window)
            mouseClick(thisComputer)
            tryVerify(() => asked("PATCH /api/v1/link"))
            tryVerify(() => findChild(shell, "restartCore").visible)
            verify(!thisComputer.visible)
            waitForPolish(shell.Window.window)
            mouseClick(findChild(shell, "forgetCore"))
            tryVerify(() => asked("DELETE /api/v1/link?url="))
            tryVerify(() => findChild(shell, "forgetCore") === null)
        }

        function test_connectionIsReachableWithoutAWorkingCore() {
            const shell = createTemporaryObject(shellComponent, window)
            mouseClick(findChild(shell, "tab-settings"))
            const connect = findChild(shell, "connectCore")
            tryVerify(() => connect?.visible === true)
            mouseClick(connect)
            const overlay = window.Overlay.overlay
            const address = findChild(overlay, "coreAddress")
            tryVerify(() => address?.activeFocus === true)
            address.text = "http://example.com"
            findChild(overlay, "coreDeviceName").text = "Laptop"
            findChild(overlay, "corePairCode").text = "one-time-code"
            mouseClick(findChild(overlay, "pairCore"))
            verify(CoreConnection.error !== "")
            verify(!CoreConnection.busy)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !address.visible)
        }
    }
}
