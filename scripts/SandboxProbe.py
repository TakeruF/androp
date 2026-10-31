# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic sandbox checks; frozen only by test-sandbox.py, never shipped."""
import asyncio
import json
import os
from pathlib import Path
import sys
import zipfile
from unittest.mock import patch
import engine
import motion_photos
import socket
import select
from huawei_tcp import TCPListener
from received_files import quarantine_value
from huawei_runtime import publish_files


async def main():
    request = json.load(sys.stdin)
    checks = {'child_container': '/Library/Containers/' in str(Path.home())}
    listener = TCPListener('127.0.0.1')
    with socket.create_connection(('127.0.0.1', listener.port), timeout=2) as client:
        client.sendall(b'owned socket')
        ready = bool(select.select([listener.stdout], [], [], 2)[0])
        checks['child_tcp_peer'] = ready and listener.peer_address() == '127.0.0.1'
        checks['child_tcp_read'] = os.read(listener.stdout.fileno(), 12) == b'owned socket'
        listener.stdin.write(b'ack')
        checks['child_tcp_write'] = client.recv(3) == b'ack'
    listener.close()
    try:
        Path(request['denied']).read_bytes()
        checks['child_denied'] = False
    except PermissionError:
        checks['child_denied'] = True
    service = engine.Engine()
    with patch.object(engine, 'emit') as emit:
        await service.command({'command': 'configure', 'destination': request['destination'],
                               'destination_bookmark': request['destination_bookmark']})
        checks['engine_configured'] = not any(c.args == ('error',) for c in emit.call_args_list)
    target = Path(request['destination'])
    if request.get('restore'):
        path = target / 'restored.txt'
        path.write_text('restored')
        checks['child_restored_write'] = path.read_text() == 'restored'
    else:
        paths = request['paths']
        with engine.BookmarkAccess(request['bookmarks'], paths):
            checks['child_selected_read'] = Path(paths[0]).read_text() == 'sandbox fixture'
            # Exercise production ZIP publication into the granted custom folder.
            saved = await engine.unpack(paths[1], target, 1, len(b'received fixture'), lambda *_: None)
            checks['engine_receive_saved'] = Path(saved[0]['path']).read_bytes() == b'received fixture'
            checks['engine_receive_quarantined'] = bool(int(quarantine_value(saved[0]['path']).split(b';')[0], 16) & 3)
            staging = target / 'huawei-staging'; staging.mkdir()
            (staging / 'huawei.txt').write_bytes(b'Huawei receive fixture')
            huawei_saved = publish_files(staging, target)
            checks['huawei_receive_saved'] = Path(huawei_saved[0]['path']).read_bytes() == b'Huawei receive fixture'
            checks['huawei_receive_quarantined'] = bool(int(quarantine_value(huawei_saved[0]['path']).split(b';')[0], 16) & 3)
            with patch.object(motion_photos, 'helper_path', return_value=Path(request['helper'])):
                inspection = await motion_photos.native('inspect', paths[2], paths[3])
            checks['converter_read'] = inspection['frame_count'] > 0
    service.destination_access.close()
    print(json.dumps(checks))


asyncio.run(main())
