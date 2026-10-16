# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

import asyncio, io, os, stat, sys, tempfile, unittest, zipfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Sources'))
from engine import unpack, validate_archive, Keys, parse_wire
class FileSafety(unittest.IsolatedAsyncioTestCase):
 async def test_multiple_names_collision_and_bytes(self):
  with tempfile.TemporaryDirectory() as td:
   root=Path(td);dest=root/'dest';dest.mkdir();(dest/'日本語.txt').write_bytes(b'original')
   archive=root/'test.zip'
   with zipfile.ZipFile(archive,'w') as z:z.writestr('日本語.txt','日本語');z.writestr('empty.bin',b'')
   files=await unpack(archive,dest,2,9,lambda n,t:None)
   self.assertEqual((dest/'日本語.txt').read_bytes(),b'original');self.assertEqual((dest/'日本語 (1).txt').read_text(),'日本語');self.assertEqual(len(files),2)
 async def test_traversal_and_symlink_rejected(self):
  for name,mode in [('../outside',0),('/absolute',0),('link',stat.S_IFLNK|0o777)]:
   with tempfile.TemporaryDirectory() as td:
    root=Path(td);archive=root/'test.zip';dest=root/'dest';dest.mkdir()
    with zipfile.ZipFile(archive,'w') as z:
     info=zipfile.ZipInfo(name);info.external_attr=mode<<16;z.writestr(info,b'x')
    with self.assertRaises(ValueError):await unpack(archive,dest,1,1,lambda n,t:None)
    self.assertEqual(list(dest.iterdir()),[])
 async def test_mismatch_no_saved_files(self):
  with tempfile.TemporaryDirectory() as td:
   root=Path(td);archive=root/'test.zip';dest=root/'dest';dest.mkdir()
   with zipfile.ZipFile(archive,'w') as z:z.writestr('file',b'test')
   with self.assertRaises(ValueError):await unpack(archive,dest,1,3,lambda n,t:None)
   self.assertEqual(list(dest.iterdir()),[])
 def test_crypto_and_protocol(self):
  a,b=Keys(),Keys();a.derive(b.public);b.derive(a.public)
  self.assertEqual(b.decrypt(a.encrypt('日本語')), '日本語')
  self.assertEqual(parse_wire('ack:1:status?{"type":1}'),('ack',1,'status',{'type':1}))
  with self.assertRaises(ValueError):parse_wire('action:1:status?[]')
if __name__=='__main__':unittest.main()
