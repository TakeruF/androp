# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

from pathlib import Path
import os, plistlib, shutil, subprocess, sys, tempfile
ROOT=Path(__file__).resolve().parent
FINAL=ROOT/'build/anDrop.app'
APP=Path(tempfile.mkdtemp(prefix='androp-build-'))/'anDrop.app'
IDENTITY=os.environ.get('ANDROP_SIGN_IDENTITY','-')
BUNDLE_ID=os.environ.get('ANDROP_BUNDLE_ID','org.androp.mac')
def run(*cmd):subprocess.run([str(x) for x in cmd],check=True)
for path in ['Contents/MacOS','Contents/Resources','Contents/PlugIns/anDropShare.appex/Contents/MacOS']:(APP/path).mkdir(parents=True,exist_ok=True)
info={'CFBundleExecutable':'anDrop','CFBundleIdentifier':BUNDLE_ID,'CFBundleName':'anDrop','CFBundleDisplayName':'anDrop','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.1','CFBundleVersion':'3','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','zh-Hans'],'LSMinimumSystemVersion':'14.0','NSBluetoothAlwaysUsageDescription':'Discover nearby devices for file sharing through the Mutual Transfer Alliance (互传联盟) ecosystem.','NSLocalNetworkUsageDescription':'Send and receive files with Android devices on the same Wi-Fi.','NSHighResolutionCapable':True,'LSUIElement':False,'CFBundleURLTypes':[{'CFBundleURLName':BUNDLE_ID+'.share','CFBundleURLSchemes':['androp']}],'CFBundleDocumentTypes':[{'CFBundleTypeName':'Files','CFBundleTypeRole':'Viewer','LSHandlerRank':'Alternate','LSItemContentTypes':['public.data']}],'CFBundleIconFile':'AppIcon'}
(APP/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
ext=APP/'Contents/PlugIns/anDropShare.appex'
extinfo={'CFBundleExecutable':'anDropShare','CFBundleIdentifier':BUNDLE_ID+'.Share','CFBundleName':'anDrop','CFBundleDisplayName':'anDrop','CFBundlePackageType':'XPC!','CFBundleShortVersionString':'0.1.1','CFBundleVersion':'3','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','zh-Hans'],'LSMinimumSystemVersion':'14.0','NSExtension':{'NSExtensionPointIdentifier':'com.apple.share-services','NSExtensionPrincipalClass':'ShareViewController','NSExtensionAttributes':{'NSExtensionActivationRule':{'NSExtensionActivationDictionaryVersion':2,'NSExtensionActivationSupportsFileWithMaxCount':1000,'NSExtensionActivationSupportsImageWithMaxCount':1000,'NSExtensionActivationSupportsMovieWithMaxCount':1000}}}}
(ext/'Contents/Info.plist').write_bytes(plistlib.dumps(extinfo))
cache=ROOT/'build/module-cache'
run('swiftc','-swift-version','6','-default-isolation','MainActor','-module-cache-path',cache,ROOT/'Sources/Localization.swift',ROOT/'Sources/Peer.swift',ROOT/'Sources/BrandLogos.swift',ROOT/'Sources/main.swift','-o',APP/'Contents/MacOS/anDrop')
run('swiftc','-swift-version','6','-default-isolation','MainActor','-module-cache-path',cache,'-parse-as-library','-emit-executable','-Xlinker','-e','-Xlinker','_NSExtensionMain',ROOT/'Sources/Localization.swift',ROOT/'Sources/ShareViewController.swift','-o',ext/'Contents/MacOS/anDropShare')
if '--ui-only' not in sys.argv:
 run(sys.executable,'-m','PyInstaller','--noconfirm','--clean','--onedir','--name','anDropEngine','--distpath',ROOT/'build/engine-dist','--workpath',ROOT/'build/engine-work','--specpath',ROOT/'build','--exclude-module','mtapy','--exclude-module','pytest',ROOT/'Sources/engine.py')
 if (APP/'Contents/Resources/Engine').exists():shutil.rmtree(APP/'Contents/Resources/Engine')
 shutil.copytree(ROOT/'build/engine-dist/anDropEngine',APP/'Contents/Resources/Engine',symlinks=True)
if '--ui-only' in sys.argv:
 shutil.copytree(FINAL/'Contents/Resources/Engine',APP/'Contents/Resources/Engine',symlinks=True)
shutil.copytree(ROOT/'Resources/BrandLogos',APP/'Contents/Resources/BrandLogos')
for name in ['LICENSE','NOTICE.md']:
 shutil.copyfile(ROOT/name,APP/'Contents/Resources'/name)
if (ROOT/'ThirdPartyNotices').exists():shutil.copytree(ROOT/'ThirdPartyNotices',APP/'Contents/Resources/ThirdPartyNotices')
if (ROOT/'AppIcon.icns').exists():shutil.copyfile(ROOT/'AppIcon.icns',APP/'Contents/Resources/AppIcon.icns')
run('xattr','-cr',APP)
entitlements=ROOT/'build/share-entitlements.plist';entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-only':True}))
run('codesign','--force','--sign',IDENTITY,'--entitlements',entitlements,ext)
# Sign nested engine Mach-O objects first. No entitlement disables platform protections.
if IDENTITY!='-' and '--ui-only' not in sys.argv:
 engine=APP/'Contents/Resources/Engine'
 for p in engine.rglob('*'):
  if p.is_file() and not p.is_symlink():
   if p.read_bytes()[:4] in [b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xfe\xed\xfa\xcf']:run('codesign','--force','--sign',IDENTITY,p)
framework=APP/'Contents/Resources/Engine/_internal/Python.framework'
if framework.exists() and '--ui-only' not in sys.argv:run('codesign','--force','--sign',IDENTITY,framework)
run('xattr','-cr',APP)
run('codesign','--force','--sign',IDENTITY,APP)
run('codesign','--verify','--deep','--strict',APP)
if FINAL.exists():shutil.rmtree(FINAL)
shutil.copytree(APP,FINAL,symlinks=True)
print(FINAL)
