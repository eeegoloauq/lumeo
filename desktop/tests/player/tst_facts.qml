import QtQuick
import QtTest
import Lumeo

Item {
    TestCase {
        name: "Facts"
        when: windowShown

        // The headless mpv answers once, then closes; its queued wakeups must
        // leave all three answers available after the reader is finished.
        function test_theHeadlessMpvFinishesAllItsAnswers() {
            tryVerify(() => MpvFacts.answered && MpvFacts.version !== "" && MpvFacts.bindings.length > 0)
            const version = MpvFacts.version
            const bindings = MpvFacts.bindings.length
            wait(0)
            verify(MpvFacts.answered)
            compare(MpvFacts.version, version)
            compare(MpvFacts.bindings.length, bindings)
        }
    }
}
