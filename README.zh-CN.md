# anDrop

[English](README.md)

anDrop 是面向 **互传联盟** 生态的 macOS 菜单栏常驻文件共享应用。仓库名为 **cn-android-share**，应用名为 **anDrop**。

使用手机或平板自带的兼容互传功能，无需提前连接厂商电脑端应用。两台设备需要开启蓝牙并连接同一局域网 Wi-Fi；运行时无需额外手机应用、账号、云服务或 USB。

互传联盟是小米、荣耀、OPPO、vivo 等中国设备厂商采用的跨品牌共享体系，并非 Android 通用标准，也不同于 Google Quick Share。[荣耀官方说明](https://www.honor.com/cn/support/content/zh-cn15883773/)介绍了这一生态。

## 使用

- 在 Finder 选择文件，点击“共享 → anDrop”，选择接收设备，再在对方设备上确认。
- 发送列表显示圆形官方品牌标识、手机／平板角标及共享名称；可通过铅笔或右键菜单设置仅在此 Mac 保存的别名。
- 手机向 Mac 发送时，通过手机的互传功能选择此 Mac，然后在 macOS 通知或菜单栏中确认。
- 文件默认直接保存到“下载”文件夹；同名文件会添加序号，保留已有文件。
- 菜单栏提供开关、进度、取消、最近传输和设置，不设主面板。
- 界面支持 English、简体中文和跟随系统。设备名默认跟随 macOS 电脑名称。

## 兼容性与当前状态

当前为 **0.1.1 开发版本**。**实机验证：OPPO Find X9 Pro 双向传输。其他品牌和机型：未验证。** 另有一台 OPPO 平板验证了发现、设备类型显示和一次平板向 Mac 的文件发送；Mac 向该平板发送尚未验证。 OPPO 是目前的测试设备，并非唯一目标品牌；加入互传联盟也不代表已经通过本应用的兼容性测试。

与 Petal Interconnect 共存属于**实验性支持**：两者同时运行时曾完成双向传输，但更新或重启后仍可能出现发现冲突，手动修复不保证每次有效。目前实现同一 Wi-Fi 下的传输；未实现 Wi-Fi Direct 和 Huawei Share。

详细说明：[兼容性](docs/compatibility.md)、[测试记录](docs/testing.md)、[使用与排查](docs/usage.md)。

## 构建

需要 macOS、Python 3.14 和 Swift 6.2+ 编译器。已验证的构建环境为 Apple Silicon、macOS 27.0.1、Swift 6.4、Python 3.14.7。

```sh
python3.14 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python build.py
.venv/bin/python -m unittest discover -s tests -v
swift test
```

输出为 `build/anDrop.app`，默认使用临时签名。[构建说明](docs/building.md)提供签名和安装步骤。

## 许可证

本项目原创源代码、文档和图标使用 **GPL-3.0-only**；第三方组件保留各自许可证。[官方品牌图片](Resources/BrandLogos/README.md) 的权利另行说明，不属于本项目的 GPL 许可授权范围。参见 [LICENSE](LICENSE)、[NOTICE.md](NOTICE.md) 和[许可证说明](docs/licensing.md)。

本项目未获设备厂商或 Apple 官方认证或背书。仓库不包含设备日志、截图、厂商 APK、逆向源码、凭据或签名材料。
