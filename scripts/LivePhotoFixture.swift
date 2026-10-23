// SPDX-License-Identifier: GPL-3.0-only
// Synthetic media and PhotoKit validation for test-live-photo-native.py.
import AVFoundation
import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

private enum FixtureError: Error { case failed }

private func pixelBuffer(_ frame: Int) throws -> CVPixelBuffer {
    var value: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32ARGB,
                              [kCVPixelBufferCGImageCompatibilityKey: true,
                               kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &value) == kCVReturnSuccess,
          let value else { throw FixtureError.failed }
    CVPixelBufferLockBaseAddress(value, [])
    defer { CVPixelBufferUnlockBaseAddress(value, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(value), width: 320, height: 240,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(value),
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
        throw FixtureError.failed
    }
    context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
    context.setFillColor(CGColor(red: 1, green: 0.6, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: frame * 3, y: 50, width: 40, height: 90))
    return value
}

private func generate(_ folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let still = try pixelBuffer(45)
    CVPixelBufferLockBaseAddress(still, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(still), width: 320, height: 240, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(still), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
    guard let image = context?.makeImage() else { throw FixtureError.failed }
    CVPixelBufferUnlockBaseAddress(still, [])
    for (ext, type) in [("jpg", UTType.jpeg), ("heic", UTType.heic)] {
        guard let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent("source." + ext) as CFURL,
                                                                type.identifier as CFString, 1, nil) else { throw FixtureError.failed }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6,
                                                      kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.failed }
    }
    let writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("source.mov"), fileType: .mov)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                    AVVideoWidthKey: 320, AVVideoHeightKey: 240])
    video.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)
    let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
                                                     sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                                    AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                                                                    AVEncoderBitRateKey: 64_000])
    writer.add(video)
    writer.add(audio)
    guard writer.startWriting() else { throw FixtureError.failed }
    writer.startSession(atSourceTime: .zero)
    var audioDescription = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
        mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &audioDescription, layoutSize: 0,
                                        layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                        formatDescriptionOut: &format) == noErr, let format else { throw FixtureError.failed }
    var frame = 0
    var audioOffset = 0
    while frame < 90 || audioOffset < 132_300 {
        if frame < 90, video.isReadyForMoreMediaData {
            guard pixels.append(try pixelBuffer(frame), withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw FixtureError.failed
            }
            frame += 1
            if frame == 90 { video.markAsFinished() }
        }
        if audioOffset < 132_300, audio.isReadyForMoreMediaData {
            let count = min(1024, 132_300 - audioOffset)
            let samples = (0..<count).map { Int16(sin(Double(audioOffset + $0) * 2 * .pi * 440 / 44_100) * 3000) }
            let data = samples.withUnsafeBytes { Data($0) }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr,
                  let block else { throw FixtureError.failed }
            let copied = data.withUnsafeBytes { bytes in
                CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                              dataLength: data.count)
            }
            guard copied == noErr else { throw FixtureError.failed }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100),
                presentationTimeStamp: CMTime(value: Int64(audioOffset), timescale: 44_100), decodeTimeStamp: .invalid)
            var size = 2
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
                  let sample, audio.append(sample) else { throw FixtureError.failed }
            audioOffset += count
            if audioOffset == 132_300 { audio.markAsFinished() }
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    await writer.finishWriting()
    guard writer.status == .completed else { throw FixtureError.failed }
}

private func snapshot(_ url: URL) async throws -> [[String: Any]] {
    let asset = AVURLAsset(url: url)
    var result: [[String: Any]] = []
    for track in try await asset.load(.tracks) where track.mediaType == .audio || track.mediaType == .video {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw FixtureError.failed }
        var hasher = SHA256()
        var timestamps: [Int64] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw FixtureError.failed }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            guard status == noErr else { throw FixtureError.failed }
            hasher.update(data: data)
            for index in 0..<CMSampleBufferGetNumSamples(sample) {
                var timing = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing) == noErr else {
                    throw FixtureError.failed
                }
                timestamps.append(CMTimeConvertScale(timing.presentationTimeStamp, timescale: 1_000_000,
                                                    method: .roundHalfAwayFromZero).value)
            }
        }
        guard reader.status == .completed else { throw FixtureError.failed }
        if track.mediaType == .video {
            // Validate actual presentation timing independently of the encoded
            // track's composition offsets and movie edit-list representation.
            let decoder = try AVAssetReader(asset: asset)
            let pictures = AVAssetReaderTrackOutput(track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            decoder.add(pictures)
            guard decoder.startReading() else { throw FixtureError.failed }
            timestamps = []
            while let sample = pictures.copyNextSampleBuffer() {
                timestamps.append(CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 1_000_000,
                                                    method: .roundHalfAwayFromZero).value)
            }
            guard decoder.status == .completed else { throw FixtureError.failed }
        }
        let transform = try await track.load(.preferredTransform)
        result.append(["type": track.mediaType.rawValue, "hash": hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                       "timestamps": timestamps, "transform": [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]])
    }
    return result
}

@main
private enum LivePhotoFixture {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { throw FixtureError.failed }
        if args[0] == "generate" {
            try await generate(URL(fileURLWithPath: args[1], isDirectory: true))
            print("{}")
        } else if args[0] == "snapshot" {
            let result = try await snapshot(URL(fileURLWithPath: args[1]))
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        } else if args[0] == "validate", args.count == 3 {
            let urls = args.dropFirst().map { URL(fileURLWithPath: $0) }
            let valid: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                PHLivePhoto.request(withResourceFileURLs: urls, placeholderImage: nil, targetSize: .zero,
                                    contentMode: .aspectFit) { photo, info in
                    guard !(info[PHLivePhotoInfoIsDegradedKey] as? Bool ?? false) else { return }
                    continuation.resume(returning: photo != nil)
                }
            }
            print(valid ? "{\"valid\":true}" : "{\"valid\":false}")
            if !valid { exit(1) }
        } else if args[0] == "plan-import", args.count == 3 {
            // Exercise the production importer against an actual converted
            // package, without requesting access to a personal Photos library.
            let plans = try await MainActor.run {
                var file: [String: Any] = ["path": args[1]]
                if args[2] == "live_photo" { file["kind"] = "live_photo" }
                return try LivePhotoImporter.plans(for: [file])
            }
            let result: [String: Any] = ["asset_count": plans.count,
                "resources": plans.flatMap { $0.resources.map { $0.kind == .photo ? "photo" : "pairedVideo" } }]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
        } else { throw FixtureError.failed }
    }
}
