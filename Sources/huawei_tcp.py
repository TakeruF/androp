# SPDX-License-Identifier: GPL-3.0-only
"""Owned Huawei receive sockets with kernel-supplied peer addresses.

The protocol decoders use selectable file descriptors and a Popen-like lifetime.
Keep that interface without subprocess inspection, which App Sandbox restricts.
"""
import socket
import threading


class TCPListener:
    pid = None

    def __init__(self, source):
        self._lock = threading.Lock()
        self._connection = None
        self._closed = False
        self._listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            self._listener.bind((source, 0))
            self._listener.listen(1)
            self._listener.setblocking(False)
            self.port = self._listener.getsockname()[1]
        except BaseException:
            self._listener.close()
            raise
        self.stdin = self.stdout = self

    def fileno(self):
        return (self._connection or self._listener).fileno()

    def peer_address(self):
        # Called only after select signals an incoming connection. Never accept
        # an address asserted in discovery, metadata or the encrypted payload.
        with self._lock:
            if self._connection is None:
                self._connection, _ = self._listener.accept()
                self._connection.setblocking(True)
                self._listener.close()
            return self._connection.getpeername()[0]

    def write(self, data):
        self._connection.sendall(data)
        return len(data)

    def flush(self):
        pass

    def poll(self):
        return 0 if self._closed else None

    def close(self):
        with self._lock:
            self._closed = True
            if self._connection is not None:
                try:
                    self._connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                self._connection.close()
            self._listener.close()

    terminate = kill = close

    def wait(self, timeout=None):
        return 0  # No child process or accept worker to reap.
