# 构建与发行 anDrop

简体中文 · [English](building.en.md)

## 环境与完整构建

- Xcode26+、Swift6.2+（`-default-isolation MainActor`）。记录发行环境为Apple Silicon/macOS27.0.1/Swift6.4。
- Python3.14与requirements.txt固定依赖；1.0.0使用python.org3.14.7及binary wheels。
- 构建机CPU需匹配目标，已发1.0.0仅arm64，Intel未测。
- 常规构建按release.json下载官方Sparkle2.10.0、验证固定SHA256并同捆，首次需网络。

部署目标macOS14.0。不能只改Info.plist让要求macOS26的Homebrew Python变兼容；用面向最低OS的Python／native wheels，如官方安装包。构建拒绝最低OS过高或load command引用构建机库的Mach-O。这是打包检查，不是macOS14实机测试。

```sh
python3.14 -m venv .venv
.venv/bin/python -m pip install --only-binary=:all: -r requirements.txt
.venv/bin/python build.py
```

输出 `build/anDrop.app`：编译Swift host/Finder扩展、PyInstaller冻结engine、同捆Sparkle/许可证、由内到外签名并验证；临时staging避免扩展属性破坏签名。完整构建后 `build.py --ui-only`可复用engine，改engine/Python/依赖必须完整重建；UI-only仍检查运行库兼容。

release.json保存版本、单调build、最低OS和公开feed。ANDROP_VERSION/ANDROP_BUILD可本地覆盖；正式打包拒绝与配置不符。

## 签名与更新

默认ad-hoc，本地配置ANDROP_SIGN_IDENTITY用于Developer ID发行，启hardened runtime/安全时间戳。证书、identity、team ID、私钥不进tracked文件。默认bundle `org.androp.mac`，ANDROP_BUNDLE_ID可本地覆盖；升级保留发行ID，否则可能重置权限／设置／登录项／扩展注册。Developer ID证书标识签名者，匿名Git不能隐藏，上传前检查实际产物。

Ed25519公钥在Resources/UpdatePublicKey.txt，私钥存release.json账号对应login Keychain，不提交／导出。fork自行生成：

```sh
build/dependencies/Sparkle-2.10.0/bin/generate_keys --account org.example.your-app
```

Sparkle官方工具签更新包及appcast，要求feed签名与解包前验证。feed为公开GitHub latest资产appcast.xml。自动检查／安装默认开，保留既有选择；验证下载后无传输即安装重启，有传输则结束后，前后通知。关闭自动安装时定期检查用gentle reminder通知，点击开更新对话框。界面跟应用语言。`build.py --app-store`排除Sparkle/feed/更新UI，仅未来商店构建开关，不代表审核／合规完成。

## 公证与DMG

helper不会发布，public资产与private签名／公证记录分离。先本地设ANDROP_SIGN_IDENTITY：

```sh
.venv/bin/python scripts/release.py prepare
.venv/bin/python scripts/release.py submit
.venv/bin/python scripts/release.py package
```

prepare --skip-build验证后复用已构建版。默认submit用Xcode既有账号、xcodebuild -exportArchive/-allowProvisioningUpdates；package用-exportNotarizedApp，签名/stapling/Gatekeeper未通过即拒绝，处理中稍后重跑。也可prepare前设既有ANDROP_NOTARY_PROFILE，submit改notarytool，package检查Accepted后staple。凭据留Keychain/Xcode，不放命令参数／源码，导出诊断私有。

helper将stapled app与Applications链接打DMG、签DMG、生成含中文说明的签名appcast与校验。**应用已公证并staple，DMG为Developer ID签名，不声称DMG单独公证。** 仅以下 `dist/<version>/public/`是资产：

- `anDrop-<version>-arm64.dmg`
- `appcast.xml`
- `SHA256SUMS.txt`

GitHub release正文用 `docs/releases/<version>.md`，英语见同名.en.md。不上传private目录/archives/raw日志/ExportOptions/公证记录；单独明确发布前检查资产／隐私，仓库公开才可匿名下载更新。

## 安装与验证

退出旧版后替换整个Applications bundle，不能合并以免旧控制中心扩展残留。按正常OS流程授权蓝牙/本地网络/通知/目录，不关保护。

```sh
.venv/bin/python -m unittest discover -s tests -v
swift test
python3 scripts/check-runtime.py build/anDrop.app --minimum 14.0 --arch arm64
codesign --verify --deep --strict build/anDrop.app
```

在实际构建环境用collect-licenses.py刷新声明，核对native来源。见[许可证](licensing.md)、[发布隐私](publication.md)、[测试](testing.md)。正常构建排除原型，不创建控制中心扩展/App Intents metadata/control-state App Group。

## Huawei Share LAN适配器

完整engine含1.2.0正式Huawei支持的有界协议模块和显式GCM/RSA imports，打包前无网络执行 `anDropEngine --huawei-check`。UI-only必须用这些修改之后的engine。实机／发现／认证／恢复边界见[调查](huawei-share-research.md)。可本地单独ANDROP_BUNDLE_ID隔离验证以保留安装版设置。
