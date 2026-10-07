import Testing
@testable import TUFFMac

/// The packaged bundle links every executable name to one binary, so the role
/// comes from the name alone.
@Suite struct ProcessRoleTests {
    @Test func linkedNamesSelectTheirRole() {
        let bin = "/Applications/TUFF.app/Contents/Resources/bin/"
        #expect(ProcessRole(invokedAs: "/Applications/TUFF.app/Contents/MacOS/TUFFDecodeService")
            == .decodeService)
        #expect(ProcessRole(invokedAs: bin + "TUFFServer") == .server)
        #expect(ProcessRole(invokedAs: bin + "TUFFCLI") == .commandLine)
        // launchd passes the agent's first program argument, not a path.
        #expect(ProcessRole(invokedAs: "TUFFServer") == .server)
    }

    @Test func anyOtherNameIsTheApp() {
        #expect(ProcessRole(invokedAs: "/Applications/TUFF.app/Contents/MacOS/TUFF") == .app)
        #expect(ProcessRole(invokedAs: "/tmp/Copy.app/Contents/MacOS/TUFF") == .app)
        #expect(ProcessRole(invokedAs: "tuffserver") == .app)
        #expect(ProcessRole(invokedAs: "") == .app)
    }
}
