// SPDX-License-Identifier: GPL-3.0-only
// Synthetic-fixture host for test-sandbox.py; never included in the product.
import Foundation

@main
struct SandboxChecks {
    @MainActor static func main() throws {
        let resource = Bundle.main.resourceURL!
        let process = Process()
        process.executableURL = resource.appendingPathComponent("SandboxProbe/SandboxProbe")
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = NSHomeDirectory(); environment["TMPDIR"] = NSTemporaryDirectory()
        environment["ANDROP_SANDBOXED"] = "1"
        process.environment = environment
        // The child starts before the host obtains any dynamic file grants.
        try process.run()
        let data = FileHandle.standardInput.readDataToEndOfFile()
        var request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let access = FileAccess()
        defer { access.close() }
        let denied = URL(fileURLWithPath: request["denied"] as! String)
        var checks = ["host_container": NSHomeDirectory().contains("/Library/Containers/"),
                      "host_denied": (try? Data(contentsOf: denied)) == nil]
        let folder: URL
        if request["restore"] as? Bool == true {
            folder = try access.restoreDestination()
            checks["restored_destination"] = folder.path == request["destination"] as? String
        } else {
            let urls = try access.resolveShared(request["bookmarks"] as! [String])
            checks["host_selected_read"] = (try Data(contentsOf: urls[0])) == Data("sandbox fixture".utf8)
            folder = try FileBookmarks.resolve(request["destination_bookmark"] as! String)
            defer { folder.stopAccessingSecurityScopedResource() }
            try access.selectDestination(folder)
            request["bookmarks"] = try urls.map(FileBookmarks.encode)
        }
        request["destination_bookmark"] = try FileBookmarks.encode(folder)
        request["destination"] = folder.path
        request["helper"] = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("anDropLivePhoto").path
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
        try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
        checks.merge(try JSONSerialization.jsonObject(with: result) as! [String: Bool]) { _, new in new }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: checks))
    }
}
