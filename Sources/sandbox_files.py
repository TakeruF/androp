# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Transfer native file grants; never infer permission from a path string."""
import base64
from contextlib import AbstractContextManager
from pathlib import Path
import sys


class BookmarkAccess(AbstractContextManager):
    def __init__(self, bookmarks, paths):
        self.urls = []
        try:
            if not isinstance(bookmarks, list) or len(bookmarks) != len(paths) or len(paths) > 10000:
                raise ValueError('Invalid file access')
            from Foundation import NSData, NSURL, NSURLBookmarkResolutionWithoutUI, NSURLBookmarkResolutionWithoutMounting
            for encoded, path in zip(bookmarks, paths):
                if not isinstance(encoded, str) or len(encoded) > 131072:
                    raise ValueError('Invalid file access')
                raw = base64.b64decode(encoded, validate=True)
                data = NSData.dataWithBytes_length_(raw, len(raw))
                url, _, error = NSURL.URLByResolvingBookmarkData_options_relativeToURL_bookmarkDataIsStale_error_(
                    data, NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithoutMounting, None, None, None)
                if error or url is None: raise ValueError('File access is unavailable')
                self.urls.append(url)  # Resolution starts implicit access.
                if not url.isFileURL() or Path(str(url.path())).resolve() != Path(path).resolve():
                    raise ValueError('File access does not match the request')
        except BaseException:
            self.close()
            raise

    def close(self):
        for url in self.urls: url.stopAccessingSecurityScopedResource()
        self.urls.clear()

    def __exit__(self, *_):
        self.close()


def bookmarks_for(paths):
    """Create implicit grants for the converter, including user-selected files."""
    if sys.platform != 'darwin': return []
    from Foundation import NSURL
    result = []
    for path in paths:
        url = NSURL.fileURLWithPath_(str(Path(path).absolute()))
        data, error = url.bookmarkDataWithOptions_includingResourceValuesForKeys_relativeToURL_error_(0, None, None, None)
        if error or data is None: raise ValueError('File access is unavailable')
        result.append(base64.b64encode(bytes(data)).decode('ascii'))
    return result
