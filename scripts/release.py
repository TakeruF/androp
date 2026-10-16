#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Prepare, notarize and package anDrop. Publication is a separate explicit step."""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import platform
import plistlib
import re
import runpy
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'release.json').read_text())
VERSION = CONFIG['version']
DIST = ROOT / 'dist' / VERSION
PRIVATE = DIST / 'private'
PUBLIC = DIST / 'public'
ARCHIVE = PRIVATE / 'anDrop.xcarchive'
STATE = PRIVATE / 'state.json'


def run(*args, capture=False):
    result = subprocess.run([str(arg) for arg in args], check=True, text=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    return (result.stdout + result.stderr) if capture else ''


def signing_identity():
    value = os.environ.get('ANDROP_SIGN_IDENTITY', '')
    if not value.startswith('Developer ID Application: '):
        raise SystemExit('Set ANDROP_SIGN_IDENTITY to a configured Developer ID Application identity.')
    return value


def assert_release(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if (info['CFBundleShortVersionString'] != VERSION or
            info['CFBundleVersion'] != str(CONFIG['build']) or
            info['LSMinimumSystemVersion'] != CONFIG['minimum_macos']):
        raise SystemExit('The app version, build or minimum OS differs from release.json; rebuild it.')
    expected_key = (ROOT / 'Resources/UpdatePublicKey.txt').read_text().strip()
    for key, value in {'SUPublicEDKey': expected_key, 'SUFeedURL': CONFIG['feed_url'],
                       'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True}.items():
        if info.get(key) != value:
            raise SystemExit(f'Release updater configuration mismatch: {key}')
    run('codesign', '--verify', '--deep', '--strict', app)
    details = run('codesign', '-d', '--verbose=4', app, capture=True)
    team = re.search(r'^TeamIdentifier=(.+)$', details, re.M)
    if not team or 'Authority=Developer ID Application:' not in details or 'runtime' not in details:
        raise SystemExit('The app must use Developer ID and the hardened runtime.')
    return info, team.group(1)


def prepare(skip_build):
    identity = signing_identity()
    if STATE.exists():
        raise SystemExit('A release preparation already exists. Use submit or package; do not overwrite it.')
    if not skip_build:
        run(sys.executable, ROOT / 'build.py')
    app = ROOT / 'build/anDrop.app'
    info, team = assert_release(app)
    run(sys.executable, ROOT / 'scripts/check-runtime.py', app,
        '--minimum', CONFIG['minimum_macos'], '--arch', platform.machine())
    PRIVATE.mkdir(parents=True, exist_ok=True)
    target = ARCHIVE / 'Products/Applications/anDrop.app'
    target.parent.mkdir(parents=True)
    run('ditto', app, target)
    archive_info = {'ArchiveVersion': 2, 'CreationDate': datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
                    'Name': 'anDrop', 'SchemeName': 'anDrop', 'ApplicationProperties': {
                        'ApplicationPath': 'Applications/anDrop.app',
                        'CFBundleIdentifier': info['CFBundleIdentifier'],
                        'CFBundleShortVersionString': VERSION,
                        'CFBundleVersion': str(CONFIG['build']),
                        'SigningIdentity': identity, 'Team': team}}
    (ARCHIVE / 'Info.plist').write_bytes(plistlib.dumps(archive_info))
    options = {'method': 'developer-id', 'destination': 'upload', 'signingStyle': 'manual',
               'signingCertificate': identity, 'teamID': team}
    (PRIVATE / 'ExportOptions.plist').write_bytes(plistlib.dumps(options))
    STATE.write_text(json.dumps({'version': VERSION, 'build': CONFIG['build'],
                                'arch': platform.machine(), 'bundle_id': info['CFBundleIdentifier'],
                                'mode': 'notarytool' if os.environ.get('ANDROP_NOTARY_PROFILE') else 'xcode'}, indent=2) + '\n')
    print('Prepared release archive. Next: scripts/release.py submit')


def submit():
    state = json.loads(STATE.read_text())
    if state['mode'] == 'notarytool':
        profile = os.environ.get('ANDROP_NOTARY_PROFILE')
        if not profile:
            raise SystemExit('Set the same ANDROP_NOTARY_PROFILE used for prepare.')
        zip_path = PRIVATE / 'notarization.zip'
        if not zip_path.exists():
            run('ditto', '-c', '-k', '--keepParent', ARCHIVE / 'Products/Applications/anDrop.app', zip_path)
        result = run('xcrun', 'notarytool', 'submit', zip_path, '--keychain-profile', profile,
                     '--output-format', 'json', capture=True)
        (PRIVATE / 'notarization-submission.json').write_text(result)
        identifier = json.loads(result)['id']
        state['submission_id'] = identifier
        STATE.write_text(json.dumps(state, indent=2) + '\n')
        print('Submitted notarization. Wait for acceptance, then run package.')
    else:
        run('xcodebuild', '-exportArchive', '-archivePath', ARCHIVE,
            '-exportPath', PRIVATE / 'upload', '-exportOptionsPlist', PRIVATE / 'ExportOptions.plist',
            '-allowProvisioningUpdates')
        print('Xcode submitted the archive. Next: scripts/release.py package')


def package():
    identity = signing_identity()
    state = json.loads(STATE.read_text())
    if PUBLIC.exists():
        raise SystemExit('Public artifacts already exist; do not silently replace an issued release.')
    with tempfile.TemporaryDirectory(prefix='androp-release-') as temporary:
        temp = Path(temporary)
        app = temp / 'stage/anDrop.app'
        app.parent.mkdir()
        if state['mode'] == 'notarytool':
            profile = os.environ.get('ANDROP_NOTARY_PROFILE')
            if not profile:
                raise SystemExit('Set ANDROP_NOTARY_PROFILE.')
            result = run('xcrun', 'notarytool', 'info', state['submission_id'],
                         '--keychain-profile', profile, '--output-format', 'json', capture=True)
            (PRIVATE / 'notarization-status.json').write_text(result)
            if json.loads(result)['status'] != 'Accepted':
                raise SystemExit('Notarization has not been accepted; no public artifacts created.')
            run('ditto', ARCHIVE / 'Products/Applications/anDrop.app', app)
            run('xcrun', 'stapler', 'staple', app)
        else:
            exported = temp / 'notarized'
            result = subprocess.run(['xcodebuild', '-exportNotarizedApp', '-archivePath', str(ARCHIVE),
                                     '-exportPath', str(exported)], capture_output=True, text=True)
            diagnostic = result.stdout + result.stderr
            (PRIVATE / 'notarized-export.log').write_text(diagnostic)
            if result.returncode:
                if 'is processing and not ready for distribution' in diagnostic:
                    raise SystemExit('Apple is still processing the archive. Run package again later.')
                raise SystemExit('Notarized export failed. Inspect dist/<version>/private/notarized-export.log.')
            run('ditto', exported / 'anDrop.app', app)
        assert_release(app)
        run('xcrun', 'stapler', 'validate', app)
        run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
        run('ditto', app, PRIVATE / 'notarized/anDrop.app')
        (app.parent / 'Applications').symlink_to('/Applications', target_is_directory=True)
        artifacts = temp / 'artifacts'
        artifacts.mkdir()
        basename = f'anDrop-{VERSION}-{state["arch"]}'
        dmg = artifacts / (basename + '.dmg')
        run('hdiutil', 'create', '-quiet', '-volname', 'anDrop', '-srcfolder', app.parent,
            '-format', 'UDZO', dmg)
        run('codesign', '--force', '--sign', identity, '--timestamp', dmg)
        run('codesign', '--verify', '--strict', dmg)
        # A notarized, stapled app is inside the signed DMG. This does not claim
        # that the DMG container itself has been submitted or stapled.
        notes = ROOT / f'docs/releases/{VERSION}.md'
        shutil.copyfile(notes, artifacts / (basename + '.md'))
        sparkle = runpy.run_path(str(ROOT / 'scripts/fetch-sparkle.py'))['fetch_sparkle']()
        run(sparkle / 'bin/generate_appcast', '--account', CONFIG['update_key_account'],
            '--download-url-prefix', f'https://github.com/{CONFIG["repository"]}/releases/download/v{VERSION}/',
            '--embed-release-notes', '--maximum-deltas', '0', artifacts)
        feed = artifacts / 'appcast.xml'
        run(sparkle / 'bin/sign_update', '--account', CONFIG['update_key_account'], '--verify', feed)
        namespace = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
        item = ET.parse(feed).find('./channel/item')
        if (item is None or item.findtext('sparkle:version', namespaces=namespace) != str(CONFIG['build']) or
                item.findtext('sparkle:minimumSystemVersion', namespaces=namespace) != CONFIG['minimum_macos'] or
                item.findtext('sparkle:hardwareRequirements', namespaces=namespace) != state['arch']):
            raise SystemExit('Unexpected appcast version, OS or architecture requirement.')
        PUBLIC.mkdir()
        for path in [dmg, feed]:
            shutil.copyfile(path, PUBLIC / path.name)
        (PUBLIC / 'SHA256SUMS.txt').write_text(''.join(
            hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n'
            for path in sorted(PUBLIC.iterdir())))
        print('Prepared public assets: ' + ', '.join(path.name for path in sorted(PUBLIC.iterdir())))
        print('Notarization records and signer metadata remain in dist/<version>/private; never upload them.')
        print('Inspect the exact assets and signing identity before publishing a GitHub release.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'submit', 'package'])
    parser.add_argument('--skip-build', action='store_true', help='Use an already verified complete build.')
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.skip_build)
    elif args.action == 'submit':
        submit()
    else:
        package()
