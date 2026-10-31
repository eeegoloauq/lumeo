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
