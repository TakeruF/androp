import AppKit
import Carbon
import Testing
@testable import anDropIdentity

@Test func finderGroupsKeepAllFilesAndSeparateParentFolders() {
    let urls = [URL(fileURLWithPath: "/tmp/one/a.txt"), URL(fileURLWithPath: "/tmp/two/b.txt"),
                URL(fileURLWithPath: "/tmp/one/c.txt"), URL(string: "https://example.com/file")!]
    #expect(FinderReveal.groups(for: urls) == [["/tmp/one", "/tmp/one/a.txt", "/tmp/one/c.txt"], ["/tmp/two", "/tmp/two/b.txt"]])
    #expect(FinderReveal.groups(for: []) == [])
}

@Test func finderFileNamesArePassedAsData() throws {
    let path = "/tmp/共有/quote\" and \\ slash\nfile.txt"
    let event = FinderReveal.makeEvent(groups: [["/tmp/共有", path]], bounds: [-900, 30, 0, 630])
    let arguments = try #require(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
    let folders = try #require(arguments.atIndex(1))
    #expect(folders.atIndex(1)?.atIndex(2)?.stringValue == path)
    #expect(arguments.atIndex(2)?.atIndex(1)?.int32Value == -900)
    #expect(arguments.atIndex(2)?.atIndex(4)?.int32Value == 630)
}

@Test @MainActor func finderWindowScriptCompilesWithoutRunningAutomation() throws {
    let script = try #require(NSAppleScript(source: FinderReveal.scriptSource))
    var error: NSDictionary?
    let compiled = script.compileAndReturnError(&error)
    #expect(compiled, "\(error ?? [:])")
}
