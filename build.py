# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

from pathlib import Path
import os, platform, json, plistlib, shutil, subprocess, sys, tempfile
ROOT=Path(__file__).resolve().parent
FINAL=ROOT/'build/anDrop.app'
APP=Path(tempfile.mkdtemp(prefix='androp-build-'))/'anDrop.app'
IDENTITY=os.environ.get('ANDROP_SIGN_IDENTITY','-')
BUNDLE_ID=os.environ.get('ANDROP_BUNDLE_ID','org.androp.mac')
def run(*cmd):subprocess.run([str(x) for x in cmd],check=True)
for path in ['Contents/MacOS','Contents/Resources','Contents/PlugIns/anDropShare.appex/Contents/MacOS']:(APP/path).mkdir(parents=True,exist_ok=True)
info={'CFBundleExecutable':'anDrop','CFBundleIdentifier':BUNDLE_ID,'CFBundleName':'anDrop','CFBundleDisplayName':'anDrop','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.1','CFBundleVersion':'27','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','zh-Hans'],'LSMinimumSystemVersion':'14.0','NSBluetoothAlwaysUsageDescription':'Discover nearby devices for file sharing through the Mutual Transfer Alliance (互传联盟) ecosystem.','NSLocalNetworkUsageDescription':'Send and receive files with Android devices on the same Wi-Fi.','NSHighResolutionCapable':True,'LSUIElement':False,'CFBundleURLTypes':[{'CFBundleURLName':BUNDLE_ID+'.share','CFBundleURLSchemes':['androp']}],'CFBundleDocumentTypes':[{'CFBundleTypeName':'Files','CFBundleTypeRole':'Viewer','LSHandlerRank':'Alternate','LSItemContentTypes':['public.data']}],'CFBundleIconFile':'AppIcon'}
(APP/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
ext=APP/'Contents/PlugIns/anDropShare.appex'
extinfo={'CFBundleExecutable':'anDropShare','CFBundleIdentifier':BUNDLE_ID+'.Share','CFBundleName':'anDrop','CFBundleDisplayName':'anDrop','CFBundlePackageType':'XPC!','CFBundleShortVersionString':'0.1.1','CFBundleVersion':'27','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','zh-Hans'],'LSMinimumSystemVersion':'14.0','NSExtension':{'NSExtensionPointIdentifier':'com.apple.share-services','NSExtensionPrincipalClass':'ShareViewController','NSExtensionAttributes':{'NSExtensionActivationRule':{'NSExtensionActivationDictionaryVersion':2,'NSExtensionActivationSupportsFileWithMaxCount':1000,'NSExtensionActivationSupportsImageWithMaxCount':1000,'NSExtensionActivationSupportsMovieWithMaxCount':1000}}}}
(ext/'Contents/Info.plist').write_bytes(plistlib.dumps(extinfo))
cache=ROOT/'build/module-cache';cache.mkdir(parents=True,exist_ok=True)
protocols=Path(subprocess.check_output(['xcrun','--find','swiftc'],text=True).strip()).parents[1]/'share/swift/SwiftConstantValues/AppIntents.json'
protocol_data=json.loads(protocols.read_text())
protocol_list=ROOT/'build/control-protocols.json';protocol_list.write_text(json.dumps(protocol_data['constValueProtocols'] if isinstance(protocol_data,dict) else protocol_data))
host_sources=[ROOT/'Sources'/name for name in ['Localization.swift','Peer.swift','TransferProgress.swift','BrandLogos.swift','ControlIntents.swift','main.swift']]
host_const=ROOT/'build/host.swiftconstvalues';host_object=ROOT/'build/host.o'
run('swiftc','-c','-whole-module-optimization','-emit-const-values','-emit-const-values-path',host_const,'-Xfrontend','-const-gather-protocols-file','-Xfrontend',protocol_list,'-swift-version','6','-default-isolation','MainActor','-module-name','anDrop','-module-cache-path',cache,*host_sources,'-o',host_object)
run('swiftc',host_object,'-o',APP/'Contents/MacOS/anDrop')
run('swiftc','-swift-version','6','-default-isolation','MainActor','-module-cache-path',cache,'-parse-as-library','-emit-executable','-Xlinker','-e','-Xlinker','_NSExtensionMain',ROOT/'Sources/Localization.swift',ROOT/'Sources/ShareViewController.swift','-o',ext/'Contents/MacOS/anDropShare')
# macOS 26+ controls are isolated in a newer-deployment-target extension.
control=APP/'Contents/PlugIns/anDropControls.appex'
(control/'Contents/MacOS').mkdir(parents=True)
controlinfo={'CFBundleExecutable':'anDropControls','CFBundleIdentifier':BUNDLE_ID+'.Controls','CFBundleName':'anDrop','CFBundleDisplayName':'anDrop','CFBundlePackageType':'XPC!','CFBundleShortVersionString':'0.1.1','CFBundleVersion':info['CFBundleVersion'],'CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','zh-Hans'],'LSMinimumSystemVersion':'26.0','CFBundleSupportedPlatforms':['MacOSX'],'DTPlatformName':'macosx','NSExtension':{'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}}
(control/'Contents/Info.plist').write_bytes(plistlib.dumps(controlinfo))
const_values=ROOT/'build/controls.swiftconstvalues'
control_object=ROOT/'build/controls.o'
run('swiftc','-c','-emit-const-values','-Xfrontend','-const-gather-protocols-file','-Xfrontend',protocol_list,'-emit-const-values-path',const_values,'-swift-version','6','-target',platform.machine()+'-apple-macos26.0','-parse-as-library','-module-name','anDropControls','-module-cache-path',cache,ROOT/'Sources/ControlIntents.swift',ROOT/'Sources/ControlWidgets.swift','-whole-module-optimization','-o',control_object)
run('swiftc','-application-extension','-Xlinker','-e','-Xlinker','_NSExtensionMain','-target',platform.machine()+'-apple-macos26.0',control_object,'-o',control/'Contents/MacOS/anDropControls')
sources=ROOT/'build/control-sources.txt';sources.write_text(str(ROOT/'Sources/ControlIntents.swift')+'\n'+str(ROOT/'Sources/ControlWidgets.swift')+'\n')
constants=ROOT/'build/control-constants.txt';constants.write_text(str(const_values)+'\n')
run('xcrun','appintentsmetadataprocessor','--output',control/'Contents/Resources','--toolchain-dir',protocols.parents[4],'--module-name','anDropControls','--sdk-root',subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip(),'--xcode-version',subprocess.check_output(['xcodebuild','-version'],text=True).split('Build version ')[-1].strip(),'--platform-family','macOS','--deployment-target','26.0','--target-triple',platform.machine()+'-apple-macos26.0','--source-file-list',sources,'--swift-const-vals-list',constants)
sources.write_text('\n'.join(str(path) for path in host_sources)+'\n');constants.write_text(str(host_const)+'\n')
run('xcrun','appintentsmetadataprocessor','--output',APP/'Contents/Resources','--toolchain-dir',protocols.parents[4],'--module-name','anDrop','--sdk-root',subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip(),'--xcode-version',subprocess.check_output(['xcodebuild','-version'],text=True).split('Build version ')[-1].strip(),'--platform-family','macOS','--deployment-target','14.0','--target-triple',platform.machine()+'-apple-macos14.0','--source-file-list',sources,'--swift-const-vals-list',constants)
for locale,strings in {
 'en':{'Receive':'Receive','Manage anDrop receiving and trusted devices.':'Manage anDrop receiving and trusted devices.'},
 'zh-Hans':{'Receive':'接收','Manage anDrop receiving and trusted devices.':'管理 anDrop 接收范围与信任设备。'},
}.items():
 folder=control/'Contents/Resources'/f'{locale}.lproj';folder.mkdir(parents=True)
 (folder/'Localizable.strings').write_text('\n'.join(f'"{key}" = "{value}";' for key,value in strings.items()))
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
run('codesign','--force','--sign',IDENTITY,'--entitlements',entitlements,control)
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
