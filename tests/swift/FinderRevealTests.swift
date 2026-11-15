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
    let event = FinderReveal.makeEvent(groups: [["/tmp/共有", path]], bounds: [-900, 30, 0, 630], visibleWindowIDs: [42, 99])
    let arguments = try #require(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
    let folders = try #require(arguments.atIndex(1))
    #expect(folders.atIndex(1)?.atIndex(2)?.stringValue == path)
    #expect(arguments.atIndex(2)?.atIndex(1)?.int32Value == -900)
    #expect(arguments.atIndex(2)?.atIndex(4)?.int32Value == 630)
    #expect(arguments.atIndex(3)?.numberOfItems == 2)
    #expect(arguments.atIndex(3)?.atIndex(1)?.int32Value == 42)
    #expect(arguments.atIndex(3)?.atIndex(2)?.int32Value == 99)
}

@Test func finderRevealSupportsNoWindowsOnCurrentDesktop() throws {
    let event = FinderReveal.makeEvent(groups: [["/tmp", "/tmp/file.txt"]], bounds: [0, 0, 900, 600], visibleWindowIDs: [])
    let arguments = try #require(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
    #expect(arguments.atIndex(3)?.descriptorType == typeAEList)
    #expect(arguments.atIndex(3)?.numberOfItems == 0)
}

@Test @MainActor func finderWindowScriptCompilesWithoutRunningAutomation() throws {
    let script = try #require(NSAppleScript(source: FinderReveal.scriptSource))
    var error: NSDictionary?
    let compiled = script.compileAndReturnError(&error)
    #expect(compiled, "\(error ?? [:])")
}

@Test @MainActor func finderSelectionMustReplaceOldItemsAndMatchTheWholeBatch() throws {
    let script = try #require(NSAppleScript(source: FinderReveal.scriptSource))
    for (actual, expected, matches) in [
        (["old"], ["received"], false),
        (["old", "received"], ["received"], false),
        ([String](), ["received"], false),
        (["first"], ["first", "second"], false),
        (["second", "first"], ["first", "second"], true),
        (["received"], ["received"], true),
    ] {
        let arguments = NSAppleEventDescriptor.list()
        for (index, values) in [actual, expected].enumerated() {
            let items = NSAppleEventDescriptor.list()
            for (index, value) in values.enumerated() {
                items.insert(NSAppleEventDescriptor(string: value), at: index + 1)
            }
            arguments.insert(items, at: index + 1)
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                          eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "hasexactselection"), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        #expect(error == nil, "\(error ?? [:])")
        #expect(result.booleanValue == matches)
    }
}
