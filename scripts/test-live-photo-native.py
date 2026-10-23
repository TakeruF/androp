#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify native Live Photo conversion with generated, non-personal media.

Runs on macOS with Xcode command line tools. All media and binaries live in a
temporary directory and are removed after verification. No Photos library is
read or modified: PhotoKit loads only the two explicit synthetic resource URLs.
"""
import hashlib
import asyncio
import argparse
import json
from pathlib import Path
import platform
import subprocess
import tempfile
import sys
import uuid
import zipfile
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Sources'))
import motion_photos


def run(*args, check=True):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, timeout=45)
    if check and result.returncode:
        raise AssertionError(f"Command failed: {Path(str(args[0])).name}: {result.stderr.decode(errors='replace')}")
    return result


def invoke(*args):
    return json.loads(run(*args).stdout)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def jpeg_scan(path):
    """Compressed JPEG scan, excluding the metadata segments being rewritten."""
    data = Path(path).read_bytes()
    assert data[:2] == b"\xff\xd8"
    offset = 2
    while offset < len(data):
        assert data[offset] == 0xFF
        while data[offset] == 0xFF:
            offset += 1
        marker = data[offset]
        offset += 1
        if marker == 0xDA:
            return data[offset - 2:]
        if marker == 0x01 or 0xD0 <= marker <= 0xD7:
            continue
        length = int.from_bytes(data[offset:offset + 2], "big")
        assert length >= 2
        offset += length
    raise AssertionError("JPEG has no scan")


async def application_roundtrip(helper, fixture, work, apple, source_tracks):
    """Exercise the same Python hooks used by the real send/receive sessions."""
    selected = [Path(apple['image']), Path(apple['video'])]
    with patch.object(motion_photos, 'helper_path', return_value=helper):
        for target in ('android', 'huawei'):
            originals = {path: sha(path) for path in selected}
            sent = await motion_photos.prepare_send(selected, work / ('send-' + target), target)
            assert len(sent) == 1, 'Apple image/video was not treated as one photo'
            info = motion_photos.motion_photo(sent[0])
            assert info is not None and info.format == target
            expected = sent[0].read_bytes()
            # The original received bytes and the derived Apple package coexist.
            saved = [{'path': str(sent[0]), 'bytes': len(expected), 'sha256': sha(sent[0])}]
            motion_photos._set_quarantine(sent[0], b'0083;fixture;anDrop;')
            received = await motion_photos.materialize_received(saved)
            assert len(received) == 2, 'Receive hook did not create an Apple Live Photo'
            assert sent[0].read_bytes() == expected
            package = Path(received[1]['path'])
            assert received[1].get('kind') == 'live_photo'
            assert invoke(fixture, 'plan-import', package, received[1]['kind']) == {
                'asset_count': 1, 'resources': ['photo', 'pairedVideo']}
            assert invoke(fixture, 'plan-import', sent[0], 'ordinary') == {
                'asset_count': 0, 'resources': []}
            image = next(package.glob('*.jpg'))
            video = next(package.glob('*.mov'))
            assert invoke(fixture, 'validate', image, video)['valid']
            assert invoke(helper, 'inspect', image, video)['timestamp_us'] == 1_000_000
            assert invoke(fixture, 'snapshot', video) == source_tracks
            assert all(motion_photos._quarantine(path) == b'0083;fixture;anDrop;' for path in [package, *package.iterdir()])
            # A received .pvt can be sent back through the ordinary file picker.
            resent = await motion_photos.prepare_send([package], work / ('resend-' + target), target)
            assert len(resent) == 1 and motion_photos.motion_photo(resent[0]) is not None
            assert originals == {path: sha(path) for path in selected}
        # The original Android container is also directly sendable to Huawei.
        cross = await motion_photos.prepare_send([work / 'send-android' / (selected[0].stem + '.MP.jpg')], work / 'cross', 'huawei')
        assert len(cross) == 1 and motion_photos.motion_photo(cross[0]).format == 'huawei'

        # OShare's Apple receiver route sends a flat, separately encoded pair.
        archive = work / (str(uuid.uuid4()) + '@olive.zip')
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=0) as bundle:
            bundle.write(work / 'source.jpg', 'camera.jpg')
            bundle.write(work / 'source.mov', 'camera.mp4')
        motion_photos._set_quarantine(archive, b'0083;fixture;anDrop;')
        received = await motion_photos.materialize_received([{'path': str(archive), 'bytes': archive.stat().st_size}])
        assert len(received) == 1 and received[0]['kind'] == 'live_photo'
        package = Path(received[0]['path'])
        image, video = next(package.glob('*.jpg')), next(package.glob('*.mov'))
        assert invoke(fixture, 'validate', image, video)['valid']
        assert invoke(fixture, 'plan-import', package, received[0]['kind']) == {
            'asset_count': 1, 'resources': ['photo', 'pairedVideo']}
        assert invoke(helper, 'inspect', image, video)['timestamp_us'] == 1_500_000
        assert invoke(fixture, 'snapshot', video) == source_tracks
        assert all(motion_photos._quarantine(path) == b'0083;fixture;anDrop;' for path in [package, *package.iterdir()])
        assert not archive.exists(), 'Converted transport ZIP remained in the receive folder'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, help='Test the native helper inside this built app')
    options = parser.parse_args()
    assert platform.system() == "Darwin", "The native conversion test requires macOS"
    with tempfile.TemporaryDirectory(prefix="androp-live-photo-") as folder:
        work = Path(folder)
        helper = options.app.resolve() / 'Contents/MacOS/anDropLivePhoto' if options.app else work / "anDropLivePhoto"
        fixture = work / "fixture"
        flags = ["-parse-as-library", "-swift-version", "6", "-strict-concurrency=complete",
                 "-target", f"{platform.machine()}-apple-macos14.0", "-suppress-warnings"]
        if options.app:
            assert helper.is_file(), 'The app does not contain the Live Photo helper'
        else:
            run("xcrun", "swiftc", *flags, ROOT / "Sources/LivePhotoConverter.swift", "-o", helper)
        run("xcrun", "swiftc", *flags, ROOT / "Sources/Localization.swift", ROOT / "Sources/LivePhotoImporter.swift",
            ROOT / "scripts/LivePhotoFixture.swift", "-o", fixture)
        invoke(fixture, "generate", work)
        source_image = work / "source.jpg"
        source_video = work / "source.mov"
        source_heic = work / "source.heic"
        before = {path: sha(path) for path in [source_image, source_heic, source_video]}
        source_tracks = invoke(fixture, "snapshot", source_video)
        assert {track["type"] for track in source_tracks} == {"vide", "soun"}
        assert next(track for track in source_tracks if track["type"] == "vide")["transform"] == [0, 1, -1, 0, 240, 0]

        ordinary = invoke(helper, "inspect", source_image, source_video)
        assert not ordinary["is_live_photo"]
        assert ordinary["frame_count"] == 90 and ordinary["duration_us"] == 3_000_000

        apple = invoke(helper, "apple", source_image, source_video, work / "apple", "frame:30")
        assert apple["timestamp_us"] == 1_000_000 and apple["cover_frame"] == 30
        assert invoke(fixture, "validate", apple["image"], apple["video"])["valid"]
        inspection = invoke(helper, "inspect", apple["image"], apple["video"])
        assert inspection["is_live_photo"] and inspection["asset_identifier"] == apple["asset_identifier"]
        assert inspection["timestamp_us"] == 1_000_000
        assert jpeg_scan(apple["image"]) == jpeg_scan(source_image), "JPEG compressed pixels changed"
        assert invoke(fixture, "snapshot", apple["video"]) == source_tracks, "Encoded media, transform, or sample PTS changed"

        other = invoke(helper, "apple", source_image, source_video, work / "other", "1500000")
        assert not invoke(helper, "inspect", apple["image"], other["video"])["is_live_photo"], "Mismatched pairs accepted"
        precise = invoke(helper, "apple", source_image, source_video, work / "precise", "1013579")
        assert invoke(helper, "inspect", precise["image"], precise["video"])["timestamp_us"] == 1_013_579

        android = invoke(helper, "android", apple["image"], apple["video"], work / "android", "-1")
        assert android["timestamp_us"] == 1_000_000, "Apple still-image-time was lost"
        assert android["cover_frame"] == 30 and android["frame_count"] == 90
        assert b"ASCII\0\0\0Oplus_8388608" in Path(android["image"]).read_bytes()
        assert jpeg_scan(android["image"]) == jpeg_scan(source_image)
        assert invoke(fixture, "snapshot", android["video"]) == source_tracks

        roundtrip = invoke(helper, "apple", android["image"], android["video"], work / "roundtrip", android["timestamp_us"])
        assert invoke(fixture, "validate", roundtrip["image"], roundtrip["video"])["valid"]
        assert invoke(helper, "inspect", roundtrip["image"], roundtrip["video"])["timestamp_us"] == 1_000_000
        assert invoke(fixture, "snapshot", roundtrip["video"]) == source_tracks
        asyncio.run(application_roundtrip(helper, fixture, work, apple, source_tracks))

        heic = invoke(helper, "apple", source_heic, source_video, work / "heic", "1000000")
        assert invoke(fixture, "validate", heic["image"], heic["video"])["valid"]
        assert invoke(fixture, "snapshot", heic["video"]) == source_tracks
        for bad in ["-2", "3000000", "invalid", "frame:-1", "frame:90"]:
            failure = run(helper, "apple", source_image, source_video, work / "invalid", bad, check=False)
            assert failure.returncode != 0 and failure.stderr == b"invalid_timestamp\n"
            assert not failure.stdout
        assert not list((work / "invalid").glob("*")), "Invalid inputs left partial files"
        assert before == {path: sha(path) for path in before}, "Source media changed"
    print("PASS: PhotoKit load, Apple identity and timed marker, HEIC conversion, lossless JPEG pixels,")
    print("      AAC/video bytes and timestamps, orientation, Android marker, frame index, round trip, source preservation")
    print("      production send/receive hooks, Huawei + Android containers, .pvt resend, quarantine, original preservation")
    print("      OShare @olive.zip → .pvt only, validated Apple pair, transport ZIP removed")
    print("      generated packages remain compatible with a manual Photos import; no library is modified")


if __name__ == "__main__":
    main()
