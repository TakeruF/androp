// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import AppKit
import Carbon

@MainActor
enum FinderReveal {
    private static let queue = DispatchQueue(label: "com.takeruf.anDrop.finder-reveal")

    // Only reuse windows on the current desktop. Reusing a window on another
    // Space would take the user away from where they clicked.
    nonisolated static let scriptSource = """
    on revealFiles(folderGroups, windowBounds, visibleWindowIDs)
        repeat with folderGroup in folderGroups
            set folderPath to item 1 of folderGroup
            set selectedItems to {}
            repeat with filePath in items 2 thru -1 of folderGroup
                set end of selectedItems to (POSIX file (contents of filePath)) as alias
            end repeat
            set targetFolder to (POSIX file folderPath) as alias
            tell application "Finder"
                set matchingWindow to missing value
                repeat with candidateWindow in (get Finder windows)
                    if visibleWindowIDs contains (id of candidateWindow) then
                        try
                            if (target of candidateWindow as alias) is targetFolder then
                                set matchingWindow to candidateWindow
                                exit repeat
                            end if
                        end try
                    end if
                end repeat
                if matchingWindow is missing value then
                    set matchingWindow to make new Finder window to targetFolder
                    set bounds of matchingWindow to windowBounds
                end if
                set index of matchingWindow to 1
                set selection to selectedItems
            end tell
        end repeat
    end revealFiles
    """

    nonisolated static func groups(for urls: [URL]) -> [[String]] {
        var result: [[String]] = []
        for url in urls where url.isFileURL {
            let folder = url.deletingLastPathComponent().path
            if let index = result.firstIndex(where: { $0.first == folder }) {
                result[index].append(url.path)
            } else {
                result.append([folder, url.path])
            }
        }
        return result
    }

    static func reveal(_ urls: [URL], on screen: NSScreen, completion: @escaping @MainActor @Sendable (Int?) -> Void) {
        let groups = groups(for: urls)
        guard !groups.isEmpty else { completion(-50); return }
        let frame = screen.visibleFrame
        let width = max(1, min(900, frame.width - 40)), height = max(1, min(600, frame.height - 40))
        let left = frame.midX - width / 2
        // Finder uses coordinates measured from the top of the main display.
        let top = (NSScreen.screens.first?.frame.maxY ?? 0) - frame.midY - height / 2
        let bounds = [left, top, left + width, top + height].map { Int32($0.rounded()) }
        // Window IDs are available without reading titles or capturing the screen.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visibleWindowIDs = windows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.int32Value }
        queue.async {
            let errorCode = showFiles(groups: groups, bounds: bounds, visibleWindowIDs: visibleWindowIDs)
            Task { @MainActor in completion(errorCode) }
        }
    }

    nonisolated static func makeEvent(groups: [[String]], bounds: [Int32], visibleWindowIDs: [Int32]) -> NSAppleEventDescriptor {
        let folders = NSAppleEventDescriptor.list()
        for (index, group) in groups.enumerated() {
            let paths = NSAppleEventDescriptor.list()
            for (index, path) in group.enumerated() {
                paths.insert(NSAppleEventDescriptor(string: path), at: index + 1)
            }
            folders.insert(paths, at: index + 1)
        }
        let rectangle = NSAppleEventDescriptor.list()
        for (index, value) in bounds.enumerated() {
            rectangle.insert(NSAppleEventDescriptor(int32: value), at: index + 1)
        }
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(folders, at: 1)
        arguments.insert(rectangle, at: 2)
        let windows = NSAppleEventDescriptor.list()
        for (index, id) in visibleWindowIDs.enumerated() {
            windows.insert(NSAppleEventDescriptor(int32: id), at: index + 1)
        }
        arguments.insert(windows, at: 3)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                          eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "revealfiles"), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    nonisolated private static func showFiles(groups: [[String]], bounds: [Int32], visibleWindowIDs: [Int32]) -> Int? {
        guard let script = NSAppleScript(source: scriptSource) else { return -50 }
        // Paths are data descriptors, never interpolated into executable script.
        var error: NSDictionary?
        script.executeAppleEvent(makeEvent(groups: groups, bounds: bounds, visibleWindowIDs: visibleWindowIDs), error: &error)
        if error == nil { return nil }
        return error?[NSAppleScript.errorNumber] as? Int ?? -1
    }
}
