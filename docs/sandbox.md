# App Sandbox

简体中文 · [English](sandbox.en.md)

原生主程序和 Finder 共享扩展启用 App Sandbox；Python 通信引擎和实况照片转换工具
继承主程序的静态沙盒。文件访问限于应用容器、下载目录以及用户明确授权的文件和文件夹。
沙盒不能替代设备身份验证、接收确认和协议检查。

## 文件权限与进程边界

主程序声明蓝牙、网络收发、下载目录读写、用户选择文件读写及 app-scoped bookmark
权限。共享扩展仅声明沙盒和用户选择文件只读权限。两个继承沙盒的可执行程序仅声明
`com.apple.security.app-sandbox` 与 `com.apple.security.inherit`。
不使用临时文件系统例外、App Group 或照片图库权限。

共享扩展在提供方回调仍有效时复制文件，通过 `androp://share?bookmark=…` 传递
隐式安全作用域书签；不再接受仅含路径的共享链接。扩展明确打开其所属主程序，
不依赖该 URL scheme 的系统默认处理应用。主程序保留选择／重试所需的访问权，
通过现有私有 JSON-lines 管道给已启动的引擎传递新书签。每个发送操作独立持有并释放权限，
取消时也释放。转换工具通过标准输入获得自己的输入／输出目录书签；引擎获得的动态权限
不会自动传给转换工具。华为发送子进程使用应用容器内的文件快照。

自选保存目录使用持久 app-scoped bookmark，启动时恢复，过期时刷新，再将隐式书签传给
引擎。旧路径字符串、损坏或失效书签需要重新选择目录；授权恢复前停止接收。
默认下载目录直接使用主／子进程已有的静态权限，不在初次启动时请求多余书签。
默认保存位置仍为下载目录，传输中不可更改目录。

主程序向 Python 明确提供容器的 home 和临时目录。MIME 类型只使用 Python 内置映射，
不再读取系统 MIME 配置。生产 Bundle ID 的构建包含容器迁移清单，迁移
`Library/Application Support/anDrop`（包括华为身份密钥）；偏好设置由 macOS 单独迁移。
其他 Bundle ID 的测试构建不包含此清单，避免迁移已安装版本的数据。

华为接收的控制、预览和文件通道使用引擎直接持有的 TCP socket，以内核返回的连接来源
核对当前发现的设备，不再通过 `lsof` 检查 `nc` 子进程。保存时保留 macOS 自动添加的
隔离属性；仅在缺少时添加，无法标记则不发布文件，不清除或降低系统隔离标记。

## 更新与产物检查

直接分发版开启 Sparkle Installer XPC 服务，仅添加官方要求的两个 Bundle ID 专属
Mach 查询例外。已有网络客户端权限，无需开启 Downloader 服务。Store 构建移除 Sparkle
及这些例外；沙盒支持不等同于满足所有商店要求或通过审核。

构建及发行准备均对签名产物运行 `scripts/check-sandbox.py`，核对主程序、扩展、
继承权限和更新服务配置。签名验证和 macOS 14 运行库检查仍独立进行。

## 本地验证

使用兼容 macOS 14 的 Python 环境；新版系统的 Homebrew Python 可能要求更高系统版本。
测试构建使用独立 Bundle ID 和输出目录：

```sh
ANDROP_BUNDLE_ID=org.androp.mac.sandbox-validation \
ANDROP_OUTPUT="$PWD/build/sandbox/anDrop.app" python build.py
python scripts/check-sandbox.py build/sandbox/anDrop.app
python scripts/test-sandbox.py --app build/sandbox/anDrop.app
```

Developer ID 签名通过本地 `ANDROP_SIGN_IDENTITY` 配置。UI-only 构建可通过
`ANDROP_ENGINE_APP=/path/to/anDrop.app` 复用完整引擎；Python 修改必须完整重建。

`test-sandbox.py` 创建独立标识的测试应用，仅使用虚拟文件和合成视频。子进程先于动态
授权启动；检查主／子进程对未授权文件的实际访问拒绝、书签转授、生产 ZIP／华为保存及
隔离属性、TCP 来源及读写、构建后的转换工具及第二次启动的保存目录恢复。
测试不访问个人照片图库，不连接手机。
临时构建与素材会移除；由 macOS 管理的唯一测试容器保持原状。

OPPO／华为基本双向传输、内容哈希及 Finder 实际共享入口已通过，详见
[实机验证](testing.md#app-sandbox-分支验证2026-10-31)。
1.3.0另通过隔离的旧版迁移及完整签名沙盒间Sparkle安装／重启。
照片实际共享、系统授权撤销、全新安装登录项注册及macOS14实机仍待手动验证，详见testing.md。

参考：[Apple 文件访问](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)、
[沙盒继承](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)、
[容器迁移](https://developer.apple.com/documentation/security/migrating-your-app-s-files-to-its-app-sandbox-container)、
[自动隔离属性](https://developer.apple.com/forums/thread/811450)、
[Sparkle 沙盒配置](https://sparkle-project.github.io/documentation/sandboxing/)。
