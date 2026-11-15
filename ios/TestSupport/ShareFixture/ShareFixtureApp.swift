// SPDX-License-Identifier: GPL-3.0-only
// A separate simulator-only QA host; never embedded in the product.
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main struct ShareFixtureApp: App {
    var body: some Scene { WindowGroup { FixtureView() } }
}

private struct Payload: Identifiable { let id = UUID(); let items: [URL] }
private struct FixtureView: View {
    @State private var payload: Payload?
    var body: some View {
        NavigationStack {
            List {
                Button("PDFを共有") { share(names: ["Share Fixture.pdf"]) }.accessibilityIdentifier("sharePDF")
                Button("画像2枚を共有") { share(names: ["original-one.png", "original-two.png"]) }.accessibilityIdentifier("shareImages")
                Button("背景転送用ファイルを共有") { share(names: ["background-verification.bin"]) }.accessibilityIdentifier("shareBackground")
                Button("URLを共有") { payload = Payload(items: [URL(string: "https://example.com/")!]) }.accessibilityIdentifier("shareURL")
            }.navigationTitle("Share Fixture")
        }.sheet(item: $payload) { ActivityView(items: $0.items) }
    }
    private func share(names: [String]) {
        let root = FileManager.default.temporaryDirectory.appending(path: "ShareFixture", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var urls: [URL] = []
        for name in names {
            let url = root.appending(path: name)
            if name.hasSuffix(".bin") {
                try? Data(repeating: 37, count: 20 * 1024 * 1024).write(to: url)
            } else if name.hasSuffix(".pdf") {
                try? UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 100)).writePDF(to: url) { context in
                    context.beginPage(); ("anDrop Share Fixture" as NSString).draw(at: CGPoint(x: 10, y: 10), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                }
            } else {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
                    UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
                }
                try? image.pngData()?.write(to: url)
            }
            urls.append(url)
        }
        payload = Payload(items: urls)
    }
}
private struct ActivityView: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
