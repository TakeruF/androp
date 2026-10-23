# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

from pathlib import Path
import json, os, platform, plistlib, re, runpy, shutil, subprocess, sys, tempfile
ROOT=Path(__file__).resolve().parent
FINAL=ROOT/'build/anDrop.app'
APP=Path(tempfile.mkdtemp(prefix='androp-build-'))/'anDrop.app'
IDENTITY=os.environ.get('ANDROP_SIGN_IDENTITY','-')
BUNDLE_ID=os.environ.get('ANDROP_BUNDLE_ID','org.androp.mac')
CONFIG=json.loads((ROOT/'release.json').read_text())
VERSION=os.environ.get('ANDROP_VERSION',CONFIG['version'])
BUILD=os.environ.get('ANDROP_BUILD',str(CONFIG['build']))
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',VERSION) or not BUILD.isdigit():raise SystemExit('Invalid version/build number')
APP_STORE='--app-store' in sys.argv
MIN_OS=CONFIG['minimum_macos']
TARGET=platform.machine()+'-apple-macos'+MIN_OS
SPARKLE=None
if not APP_STORE:
 SPARKLE=runpy.run_path(str(ROOT/'scripts/fetch-sparkle.py'))['fetch_sparkle']()
SIGN_OPTIONS=['--options','runtime','--timestamp'] if IDENTITY!='-' else []

def run(*cmd):subprocess.run([str(x) for x in cmd],check=True)
for path in ['Contents/MacOS','Contents/Resources','Contents/PlugIns/anDropShare.appex/Contents/MacOS']:(APP/path).mkdir(parents=True,exist_ok=True)
# Declare a menu-bar app so URL launches do not promote it to regular and
# trigger an asynchronous deactivation when the runtime restores accessory.
# Petal coexistence still opts into regular activation explicitly at runtime.
info={'CFBundleExecutable':'anDrop','CFBundleIdentifier':BUNDLE_ID,'CFBundleName':'anDrop','CFBundleDisplayName':'anDrop','CFBundlePackageType':'APPL','CFBundleShortVersionString':VERSION,'CFBundleVersion':BUILD,'CFBundleDevelopmentRegion':'zh-Hans','CFBundleLocalizations':['en','zh-Hans'],'LSMinimumSystemVersion':MIN_OS,'NSBluetoothAlwaysUsageDescription':'Discover nearby devices for file sharing through the Mutual Transfer Alliance (互传联盟) ecosystem.','NSLocalNetworkUsageDescription':'Send and receive files with Android devices on the same Wi-Fi.','NSHighResolutionCapable':True,'LSUIElement':True,'CFBundleURLTypes':[{'CFBundleURLName':BUNDLE_ID+'.share','CFBundleURLSchemes':['androp']}],'CFBundleDocumentTypes':[{'CFBundleTypeName':'Files','CFBundleTypeRole':'Viewer','LSHandlerRank':'Alternate','LSItemContentTypes':['public.data','com.apple.live-photo-bundle','com.apple.private.live-photo-bundle']}],'CFBundleIconFile':'AppIconPaperplane','CFBundleIconName':'AppIconPaperplane'}
if not APP_STORE:
 info.update({'SUFeedURL':os.environ.get('ANDROP_FEED_URL',CONFIG['feed_url']),'SUPublicEDKey':(ROOT/'Resources/UpdatePublicKey.txt').read_text().strip(),'SUEnableAutomaticChecks':True,'SUAutomaticallyUpdate':True,'SUEnableSystemProfiling':False,'SUVerifyUpdateBeforeExtraction':True,'SURequireSignedFeed':True,'SUScheduledCheckInterval':86400})
(APP/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
ext=APP/'Contents/PlugIns/anDropShare.appex'
extinfo={'CFBundleIconFile':'ShareIcon','CFBundleIconName':'AppIconPaperplane','CFBundleExecutable':'anDropShare','CFBundleIdentifier':BUNDLE_ID+'.Share','CFBundleName':'anDrop','CFBundleDisplayName':'anDrop','CFBundlePackageType':'XPC!','CFBundleShortVersionString':VERSION,'CFBundleVersion':BUILD,'CFBundleDevelopmentRegion':'zh-Hans','CFBundleLocalizations':['en','zh-Hans'],'LSMinimumSystemVersion':MIN_OS,'NSExtension':{'NSExtensionPointIdentifier':'com.apple.share-services','NSExtensionPrincipalClass':'ShareViewController','NSExtensionAttributes':{'NSExtensionActivationRule':{'NSExtensionActivationDictionaryVersion':2,'NSExtensionActivationSupportsFileWithMaxCount':1000,'NSExtensionActivationSupportsImageWithMaxCount':1000,'NSExtensionActivationSupportsMovieWithMaxCount':1000}}}}
(ext/'Contents/Info.plist').write_bytes(plistlib.dumps(extinfo))
cache=ROOT/'build/module-cache';cache.mkdir(parents=True,exist_ok=True)
host_sources=[ROOT/'Sources'/name for name in ['AppUpdates.swift','Localization.swift','Peer.swift','ReceiveAccessPolicy.swift','TransferProgress.swift','Diagnostics.swift','BrandLogos.swift','HuaweiLANDiscovery.swift','main.swift']]
framework_flags=[]
if not APP_STORE:
 (APP/'Contents/Frameworks').mkdir()
 shutil.copytree(SPARKLE/'Sparkle.framework',APP/'Contents/Frameworks/Sparkle.framework',symlinks=True)
 framework_flags=['-F',SPARKLE,'-framework','Sparkle','-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks']
run('swiftc','-swift-version','6','-default-isolation','MainActor','-target',TARGET,*(['-D','APP_STORE'] if APP_STORE else []),'-module-name','anDrop','-module-cache-path',cache,*framework_flags,*host_sources,'-o',APP/'Contents/MacOS/anDrop')
run('swiftc','-swift-version','6','-target',TARGET,'-module-cache-path',cache,'-parse-as-library',ROOT/'Sources/LivePhotoConverter.swift','-o',APP/'Contents/MacOS/anDropLivePhoto')
run('swiftc','-swift-version','6','-default-isolation','MainActor','-target',TARGET,'-module-cache-path',cache,'-parse-as-library','-emit-executable','-Xlinker','-e','-Xlinker','_NSExtensionMain',ROOT/'Sources/Localization.swift',ROOT/'Sources/SharedFileStaging.swift',ROOT/'Sources/ShareViewController.swift','-o',ext/'Contents/MacOS/anDropShare')
if '--ui-only' not in sys.argv:
 huawei_data=[]
 for name in ['huawei-auth-probe.py','huawei-transfer-probe.py','huawei-receive-probe.py','huawei-receive-channels.py','huawei-file-batch.py']:
  huawei_data+=['--add-data',str(ROOT/'scripts'/name)+':huawei']
 run(sys.executable,'-m','PyInstaller','--noconfirm','--clean','--onedir','--name','anDropEngine','--distpath',ROOT/'build/engine-dist','--workpath',ROOT/'build/engine-work','--specpath',ROOT/'build','--exclude-module','mtapy','--exclude-module','pytest','--hidden-import','cryptography.hazmat.primitives.ciphers.aead','--hidden-import','cryptography.hazmat.primitives.asymmetric.rsa','--hidden-import','cryptography.hazmat.primitives.asymmetric.padding',*huawei_data,ROOT/'Sources/engine.py')
 run(ROOT/'build/engine-dist/anDropEngine/anDropEngine','--huawei-check')
 if (APP/'Contents/Resources/Engine').exists():shutil.rmtree(APP/'Contents/Resources/Engine')
 shutil.copytree(ROOT/'build/engine-dist/anDropEngine',APP/'Contents/Resources/Engine',symlinks=True)
if '--ui-only' in sys.argv:
 shutil.copytree(FINAL/'Contents/Resources/Engine',APP/'Contents/Resources/Engine',symlinks=True)
live_probe=subprocess.run([str(APP/'Contents/Resources/Engine/anDropEngine'),'--live-photo-check'],
 stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
if live_probe.returncode or live_probe.stdout!=b'Live Photo helper packaging check passed\n':
 raise SystemExit('Live Photo helper packaging check failed; rebuild the complete engine.')
shutil.copytree(ROOT/'Resources/BrandLogos',APP/'Contents/Resources/BrandLogos')
for name in ['LICENSE','NOTICE.md']:
 shutil.copyfile(ROOT/name,APP/'Contents/Resources'/name)
if (ROOT/'ThirdPartyNotices').exists():shutil.copytree(ROOT/'ThirdPartyNotices',APP/'Contents/Resources/ThirdPartyNotices')
# Share extensions have their own bundle/icon lookup; do not rely on a host fallback.
icon=ROOT/'AppIcon.icns'
shutil.copyfile(icon,APP/'Contents/Resources/AppIcon.icns')
shutil.copyfile(icon,APP/'Contents/Resources/AppIconPaperplane.icns')
(ext/'Contents/Resources').mkdir(parents=True,exist_ok=True)
shutil.copyfile(icon,ext/'Contents/Resources/ShareIcon.icns')
# Modern system surfaces can resolve named icon assets rather than legacy ICNS.
assets=APP.parent/'Assets.xcassets';assets.mkdir()
(assets/'Contents.json').write_text(json.dumps({'info':{'author':'anDrop','version':1}}))
iconset=APP.parent/'Paperplane.iconset'
run('iconutil','-c','iconset',icon,'-o',iconset)
appicon=assets/'AppIconPaperplane.appiconset';shutil.copytree(iconset,appicon)
images=[]
for size in [16,32,128,256,512]:
 for scale in [1,2]:
  filename=f'icon_{size}x{size}'+('@2x' if scale==2 else '')+'.png'
  images.append({'idiom':'mac','size':f'{size}x{size}','scale':f'{scale}x','filename':filename})
(appicon/'Contents.json').write_text(json.dumps({'images':images,'info':{'author':'anDrop','version':1}}))
run('xcrun','actool','--compile',APP/'Contents/Resources','--platform','macosx','--minimum-deployment-target',MIN_OS,'--app-icon','AppIconPaperplane','--output-partial-info-plist',APP.parent/'IconInfo.plist',assets)
shutil.copyfile(APP/'Contents/Resources/Assets.car',ext/'Contents/Resources/Assets.car')

run(sys.executable, ROOT/'scripts/check-runtime.py', APP, '--minimum', MIN_OS, '--arch', platform.machine())
run('xattr','-cr',APP)
entitlements=ROOT/'build/share-entitlements.plist';entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-only':True}))
def sign(path, entitlement=None, preserve=False):
 args=['codesign','--force','--sign',IDENTITY,*SIGN_OPTIONS]
 if entitlement:args+=['--entitlements',entitlement]
 elif preserve:args+=['--preserve-metadata=entitlements']
 run(*args,path)
sign(ext,entitlements)
sign(APP/'Contents/MacOS/anDropLivePhoto')
# Sign leaves before containing framework/app bundles, preserving Sparkle helpers' entitlements.
mach_magic={b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbf'}
leaves=[]
for parent in [APP/'Contents/Resources/Engine',APP/'Contents/Frameworks']:
 if not parent.exists():continue
 for p in parent.rglob('*'):
  if p.is_file() and not p.is_symlink():
   with p.open('rb') as handle:magic=handle.read(4)
   if magic in mach_magic:leaves.append(p)
# codesign can treat a framework's main Mach-O as the containing framework.
# Finish nested helpers first; parallel mutation leaves transient .cstemp files
# inside that container and can invalidate the outer signing operation.
for p in sorted(leaves,key=lambda p:(-len(p.parts),str(p))):sign(p,preserve=True)
containers=[p for p in APP.rglob('*') if p.is_dir() and not p.is_symlink() and p.suffix in ('.app','.xpc','.framework')]
for p in sorted(containers,key=lambda p:len(p.parts),reverse=True):sign(p,preserve=True)
run('xattr','-cr',APP)
sign(APP)
run('codesign','--verify','--deep','--strict',APP)
if FINAL.exists():shutil.rmtree(FINAL)
shutil.copytree(APP,FINAL,symlinks=True)
# Source-mode engine tests use the same helper as the verified app bundle.
shutil.copy2(FINAL/'Contents/MacOS/anDropLivePhoto',ROOT/'build/anDropLivePhoto')
print(FINAL)
