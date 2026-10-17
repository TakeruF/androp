# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources'))
from file_types import offer_mime_type


class OfferFileTypes(unittest.TestCase):
    def test_specific_types(self):
        cases = {
            '写真.JPG': 'image/jpeg', 'photo.png': 'image/png',
            'photo.HEIC': 'image/heic', 'movie.mp4': 'video/mp4',
            'sound.mp3': 'audio/mpeg', '書類.PDF': 'application/pdf',
            'note.txt': 'text/plain', 'archive.zip': 'application/zip',
            'word.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'sheet.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            'slides.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
            'archive.tar.gz': 'application/gzip', 'notes.txt.bz2': 'application/x-bzip2',
            'file?#.pdf': 'application/pdf', 'notes.pdf.unknown-extension': 'file/*',
            'README': 'file/*', '.pdf': 'file/*', 'empty.bin': 'file/*',
        }
        for filename, expected in cases.items():
            with self.subTest(filename=filename):
                self.assertEqual(offer_mime_type([Path(filename)]), expected)

    def test_batches_describe_every_file(self):
        cases = [
            (['a.pdf', 'b.PDF'], 'application/pdf'),
            (['a.jpg', 'b.png'], 'image/*'),
            (['a.mp3', 'b.wav'], 'audio/*'),
            (['a.mp4', 'b.mov'], 'video/*'),
            (['a.jpg', 'b.pdf'], 'file/*'),
            (['a.pdf', 'b.jpg'], 'file/*'),
            (['a.jpg', 'b.unknown-extension'], 'file/*'),
            (['a.pdf', 'b.docx'], 'file/*'),
            ([], 'file/*'),
        ]
        for names, expected in cases:
            with self.subTest(names=names):
                self.assertEqual(offer_mime_type(names), expected)
