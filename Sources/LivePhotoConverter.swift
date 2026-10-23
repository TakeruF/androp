// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors
// Standalone helper: swiftc -parse-as-library LivePhotoConverter.swift -o anDropLivePhoto
import AVFoundation
import AppKit
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

private enum ConversionError: String, Error {
    case arguments = "invalid_arguments"
    case image = "invalid_image"
    case video = "invalid_video"
    case timestamp = "invalid_timestamp"
    case destination = "invalid_destination"
    case metadata = "metadata_failed"
    case remux = "remux_failed"
    case deadline = "conversion_timeout"
    case size = "media_too_large"
    case livePhoto = "live_photo_validation_failed"
}

private struct Inspection: Codable {
    let image: String
    let video: String
    let timestamp_us: Int64
    let duration_us: Int64
    let asset_identifier: String?
    let is_live_photo: Bool
    let frame_count: Int
    let cover_frame: Int
}

private struct MovieInfo {
    let asset: AVURLAsset
    let duration: CMTime
    let identifier: String?
    let stillTime: CMTime?
    let frameTimes: [Int64]

    func coverFrame(at time: CMTime) -> Int {
        let target = microseconds(time)
        return frameTimes.indices.min { abs(frameTimes[$0] - target) < abs(frameTimes[$1] - target) } ?? 0
    }
}

private let contentKey = "com.apple.quicktime.content.identifier"
private let stillTimeKey = "com.apple.quicktime.still-image-time"

// PhotoKit may deliver both a degraded placeholder and the final result.
// The gate also resolves a timeout/callback race exactly once.
private actor LivePhotoValidationGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func setTimeout(_ task: Task<Void, Never>) {
        if continuation == nil { task.cancel() } else { timeout = task }
    }

    @discardableResult
    func finish(_ valid: Bool) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(returning: valid)
        return true
    }
}

private func validateLivePhoto(image: URL, video: URL) async -> Bool {
    await withCheckedContinuation { continuation in
        let gate = LivePhotoValidationGate(continuation)
        // Loading explicit resource URLs does not read or modify the Photos
        // library and requires no library authorization.
        let request = PHLivePhoto.request(withResourceFileURLs: [image, video], placeholderImage: nil,
                                          targetSize: .zero, contentMode: .aspectFit) { photo, info in
            guard !(info[PHLivePhotoInfoIsDegradedKey] as? Bool ?? false) else { return }
            let valid = photo != nil
            Task { await gate.finish(valid) }
        }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            if await gate.finish(false) { PHLivePhoto.cancelRequest(withRequestID: request) }
        }
        Task { await gate.setTimeout(timeout) }
    }
}

private func microseconds(_ time: CMTime) -> Int64 {
    CMTimeConvertScale(time, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
}

private func imageIdentifier(_ url: URL) throws -> String? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) > 0,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [String: Any] else {
        throw ConversionError.image
    }
    let identifier = (properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])?["17"] as? String
    return identifier?.isEmpty == false ? identifier : nil
}

private func movieInfo(_ url: URL) async throws -> MovieInfo {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0,
          let videoTrack = videoTracks.first else {
        throw ConversionError.video
    }
    let metadata = try await asset.load(.metadata)
    var identifier: String?
    for item in metadata where item.keySpace == .quickTimeMetadata && item.key as? String == contentKey {
        identifier = try await item.load(.stringValue)
    }
    var stillTime: CMTime?
    for track in try await asset.loadTracks(withMediaType: .metadata) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { continue }
        reader.add(output)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
        guard reader.startReading() else { throw ConversionError.video }
        while let group = adaptor.nextTimedMetadataGroup() {
            if group.items.contains(where: { $0.key as? String == stillTimeKey }) {
                let candidate = group.timeRange.start
                if candidate.isNumeric, candidate >= .zero, candidate < duration { stillTime = candidate }
                break
            }
        }
        reader.cancelReading()
        if stillTime != nil { break }
    }
    let frameReader = try AVAssetReader(asset: asset)
    defer { if frameReader.status == .reading { frameReader.cancelReading() } }
    // Compressed H.264 samples use the media timeline before edit-list mapping
    // (notably MP4 B-frame composition offsets). Decode for frame timing only;
    // remux below still copies the original compressed video and audio bytes.
    let frameOutput = AVAssetReaderTrackOutput(track: videoTrack,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    guard frameReader.canAdd(frameOutput) else { throw ConversionError.video }
    frameReader.add(frameOutput)
    guard frameReader.startReading() else { throw ConversionError.video }
    var frameTimes: [Int64] = []
    let frameDeadline = ContinuousClock.now.advanced(by: .seconds(120))
    while let sample = frameOutput.copyNextSampleBuffer() {
        guard ContinuousClock.now < frameDeadline, frameTimes.count < 1_000_000 else { throw ConversionError.deadline }
        guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric, time.seconds.isFinite else { throw ConversionError.video }
        frameTimes.append(microseconds(time))
    }
    guard frameReader.status == .completed, !frameTimes.isEmpty else { throw ConversionError.video }
    return MovieInfo(asset: asset, duration: duration, identifier: identifier, stillTime: stillTime, frameTimes: frameTimes.sorted())
}

// Replace only the EXIF APP1 segment. ImageIO supplies the MakerApple metadata,
// while the original JPEG's compressed pixels, XMP, ICC and auxiliary segments
// remain byte-for-byte intact. The temporary ImageIO encoding is discarded.
private func replacingEXIF(in original: Data, with encoded: Data) throws -> Data {
    func exifSegments(_ data: Data) throws -> [(Range<Int>, Data)] {
        guard data.count >= 4, data[0] == 0xff, data[1] == 0xd8 else { throw ConversionError.image }
        var offset = 2
        var result: [(Range<Int>, Data)] = []
        while offset + 4 <= data.count {
            let start = offset
            guard data[offset] == 0xff else { throw ConversionError.image }
            while offset < data.count, data[offset] == 0xff { offset += 1 }
            guard offset < data.count else { throw ConversionError.image }
            let marker = data[offset]
            offset += 1
            if marker == 0xda || marker == 0xd9 { break }
            if marker == 0x01 || (0xd0 ... 0xd7).contains(marker) { continue }
            guard offset + 2 <= data.count else { throw ConversionError.image }
            let length = Int(data[offset]) * 256 + Int(data[offset + 1])
            guard length >= 2, length <= data.count - offset else { throw ConversionError.image }
            let end = offset + length
            if marker == 0xe1, length >= 8,
               data.subdata(in: (offset + 2)..<(offset + 8)) == Data([69, 120, 105, 102, 0, 0]) {
                result.append((start..<end, data.subdata(in: start..<end)))
            }
            offset = end
        }
        return result
    }
    let existing = try exifSegments(original)
    guard let replacement = try exifSegments(encoded).first?.1 else { throw ConversionError.metadata }
    var result = original.prefix(2)
    result.append(replacement)
    var cursor = 2
    for (range, _) in existing {
        result.append(original[cursor..<range.lowerBound])
        cursor = range.upperBound
    }
    result.append(original[cursor...])
    return Data(result)
}

private func writeImage(_ sourceURL: URL, to destinationURL: URL, identifier: String?, userComment: String?) throws {
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          CGImageSourceGetCount(source) > 0 else { throw ConversionError.image }
    let primaryIndex = CGImageSourceGetPrimaryImageIndex(source)
    let isJPEG = CGImageSourceGetType(source) as String? == UTType.jpeg.identifier
    if isJPEG, identifier == nil, userComment == nil {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return
    }
    let buffer = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw ConversionError.destination
    }
    var properties = (CGImageSourceCopyPropertiesAtIndex(source, primaryIndex, nil) as? [String: Any]) ?? [:]
    if let identifier {
        var maker = (properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]) ?? [:]
        maker["17"] = identifier
        properties[kCGImagePropertyMakerAppleDictionary as String] = maker
    }
    if let userComment {
        var exif = (properties[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
        exif[kCGImagePropertyExifUserComment as String] = userComment
        properties[kCGImagePropertyExifDictionary as String] = exif
    }
    // HEIF's upright pixels and EXIF orientation are retained together, without
    // applying an orientation transform a second time.
    properties[kCGImageDestinationLossyCompressionQuality as String] = 0.98
    CGImageDestinationAddImageFromSource(destination, source, primaryIndex, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ConversionError.image }
    let encoded = buffer as Data
    let data = try isJPEG ? replacingEXIF(in: Data(contentsOf: sourceURL), with: encoded) : encoded
    try data.write(to: destinationURL, options: .withoutOverwriting)
}

private struct CopyTrack {
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
}

private func markerInput() throws -> (AVAssetWriterInput, AVAssetWriterInputMetadataAdaptor) {
    var description: CMMetadataFormatDescription?
    let specification: [String: Any] = [
        kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/" + stillTimeKey,
        kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String
    ]
    let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &description
    )
    guard status == noErr, let description else { throw ConversionError.metadata }
    let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = 1_000_000
    return (input, AVAssetWriterInputMetadataAdaptor(assetWriterInput: input))
}

private func remux(_ info: MovieInfo, to url: URL, identifier: String?, stillTime: CMTime) async throws {
    let reader = try AVAssetReader(asset: info.asset)
    let writer = try AVAssetWriter(outputURL: url, fileType: identifier == nil ? .mp4 : .mov)
    writer.movieTimeScale = 1_000_000
    defer {
        if reader.status == .reading { reader.cancelReading() }
        if writer.status == .writing { writer.cancelWriting() }
    }
    var copyTracks: [CopyTrack] = []
    for track in try await info.asset.load(.tracks) {
        let mediaType = track.mediaType
        guard mediaType == .video || mediaType == .audio || mediaType == .metadata else { continue }
        let descriptions = try await track.load(.formatDescriptions)
        // Replace the still-photo marker rather than duplicating an older one.
        if mediaType == .metadata, descriptions.contains(where: {
            (CMMetadataFormatDescriptionGetIdentifiers($0) as? [String])?.contains("mdta/" + stillTimeKey) == true
        }) { continue }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: nil, sourceFormatHint: descriptions.first)
        input.expectsMediaDataInRealTime = false
        if mediaType == .video { input.transform = try await track.load(.preferredTransform) }
        guard reader.canAdd(output), writer.canAdd(input) else { throw ConversionError.remux }
        reader.add(output)
        writer.add(input)
        copyTracks.append(CopyTrack(output: output, input: input))
    }
    var metadata = try await info.asset.load(.metadata)
    metadata.removeAll { $0.keySpace == .quickTimeMetadata && $0.key as? String == contentKey }
    var marker: (AVAssetWriterInput, AVAssetWriterInputMetadataAdaptor)?
    if let identifier {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = contentKey as NSString
        item.value = identifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        metadata.append(item)
        marker = try markerInput()
        guard let marker, writer.canAdd(marker.0) else { throw ConversionError.metadata }
        writer.add(marker.0)
    }
    writer.metadata = metadata
    guard writer.startWriting(), reader.startReading() else { throw ConversionError.remux }
    writer.startSession(atSourceTime: .zero)
    var finished = Set<Int>()
    var markerWritten = marker == nil
    let deadline = ContinuousClock.now.advanced(by: .seconds(120))
    while finished.count < copyTracks.count || !markerWritten {
        guard ContinuousClock.now < deadline else { throw ConversionError.deadline }
        guard writer.status == .writing, reader.status != .failed else { throw ConversionError.remux }
        var progressed = false
        for (index, track) in copyTracks.enumerated() where !finished.contains(index) && track.input.isReadyForMoreMediaData {
            if let sample = track.output.copyNextSampleBuffer() {
                if CMSampleBufferGetNumSamples(sample) > 0 {
                    guard track.input.append(sample) else { throw ConversionError.remux }
                }
            } else {
                track.input.markAsFinished()
                finished.insert(index)
            }
            progressed = true
        }
        if !markerWritten, let marker, marker.0.isReadyForMoreMediaData {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = stillTimeKey as NSString
            item.value = NSNumber(value: Int8(0))
            item.dataType = kCMMetadataBaseDataType_SInt8 as String
            let remaining = CMTimeSubtract(info.duration, stillTime)
            let interval = CMTimeMinimum(CMTime(value: 1, timescale: 30), remaining)
            let group = AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(start: stillTime, duration: interval))
            guard marker.1.append(group) else { throw ConversionError.metadata }
            marker.0.markAsFinished()
            markerWritten = true
            progressed = true
        }
        if !progressed { try await Task.sleep(for: .milliseconds(2)) }
    }
    guard reader.status == .completed else { throw ConversionError.remux }
    await writer.finishWriting()
    guard writer.status == .completed else { throw ConversionError.remux }
}

@main
private enum LivePhotoConverter {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 3, ["inspect", "apple", "android"].contains(args[0]),
                  args[0] == "inspect" ? args.count == 3 : (4...5).contains(args.count) else {
                throw ConversionError.arguments
            }
            let image = URL(fileURLWithPath: args[1]).standardizedFileURL
            let video = URL(fileURLWithPath: args[2]).standardizedFileURL
            let inputSizes = try [image, video].map { url -> Int64 in
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber else { throw ConversionError.arguments }
                return size.int64Value
            }
            guard inputSizes.allSatisfy({ $0 >= 0 && $0 <= 512 * 1024 * 1024 }),
                  inputSizes.reduce(0, +) <= 512 * 1024 * 1024 else { throw ConversionError.size }
            let imageID = try imageIdentifier(image)
            let info = try await movieInfo(video)
            let timestamp = info.stillTime ?? CMTimeMultiplyByFloat64(info.duration, multiplier: 0.5)
            var result = Inspection(image: image.path, video: video.path, timestamp_us: microseconds(timestamp),
                                    duration_us: microseconds(info.duration), asset_identifier: imageID,
                                    is_live_photo: imageID != nil && imageID == info.identifier && info.stillTime != nil,
                                    frame_count: info.frameTimes.count, cover_frame: info.coverFrame(at: timestamp))
            if args[0] != "inspect" {
                let target = URL(fileURLWithPath: args[3], isDirectory: true).standardizedFileURL
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let identifier = args[0] == "apple" ? UUID().uuidString : nil
                let stem = "anDrop-" + UUID().uuidString
                let outputImage = target.appendingPathComponent(stem + ".jpg")
                let outputVideo = target.appendingPathComponent(stem + (identifier == nil ? ".mp4" : ".mov"))
                var selectedTime = timestamp
                if args.count == 5 {
                    let value: Int64
                    if args[4].hasPrefix("frame:") {
                        guard let index = Int(args[4].dropFirst(6)), info.frameTimes.indices.contains(index) else {
                            throw ConversionError.timestamp
                        }
                        value = info.frameTimes[index]
                    } else {
                        guard let parsed = Int64(args[4]), parsed >= -1 else { throw ConversionError.timestamp }
                        value = parsed == -1 ? microseconds(timestamp) : parsed
                    }
                    selectedTime = CMTime(value: value, timescale: 1_000_000)
                }
                guard selectedTime >= .zero, selectedTime < info.duration else { throw ConversionError.timestamp }
                do {
                    try writeImage(image, to: outputImage, identifier: identifier,
                                   userComment: identifier == nil ? "Oplus_8388608" : nil)
                    try await remux(info, to: outputVideo, identifier: identifier, stillTime: selectedTime)
                    if identifier != nil, !(await validateLivePhoto(image: outputImage, video: outputVideo)) {
                        throw ConversionError.livePhoto
                    }
                } catch {
                    try? FileManager.default.removeItem(at: outputImage)
                    try? FileManager.default.removeItem(at: outputVideo)
                    throw error
                }
                result = Inspection(image: outputImage.path, video: outputVideo.path, timestamp_us: microseconds(selectedTime),
                                    duration_us: microseconds(info.duration), asset_identifier: identifier,
                                    is_live_photo: identifier != nil, frame_count: info.frameTimes.count,
                                    cover_frame: info.coverFrame(at: selectedTime))
            }
            let data = try JSONEncoder().encode(result)
            FileHandle.standardOutput.write(data + Data([10]))
        } catch {
            // Input filenames and media metadata may contain personal content.
            let token = (error as? ConversionError)?.rawValue ?? "conversion_failed"
            FileHandle.standardError.write(Data((token + "\n").utf8))
            exit(1)
        }
    }
}
