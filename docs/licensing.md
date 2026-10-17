# 许可证

简体中文 · [English](licensing.en.md)

## 项目与开发沿革

原创代码／文档／应用图标采用GPL-3.0-only，版权标签anDrop contributors，全文[LICENSE](../LICENSE)，源码SPDX；按许可不担保。早期原型导入GPL-3.0 mtapy，当前engine不导入／同捆；项目选GPL为与开发沿革一致，不声称仅阅读协议文档就决定许可义务。

参考mtapy revision的README、license字段、LICENSE均GPL-3.0，尽管metadata一个classifier误列MIT。保留原文；CatShare MIT声明作为参考保留，见[NOTICE](../NOTICE.md)。

## 第三方与分发

ThirdPartyNotices/README.txt记录检查版本和许可，其旁原文只适用各组件，不适用全应用。保留上游版权姓名。Python/native库有各自许可；PyObjC用系统libffi，所查构建不另带libffi。PyInstaller bootloader exception/Apache runtime见[官方许可](https://pyinstaller.org/en/stable/license.html)与pyinstaller-COPYING.txt；community hooks区分构建hook与embedded runtime hook。

再分发保留LICENSE/NOTICE/依赖许可。分发binary须按GPL提供该精确版对应源码／构建说明并核对实际同捆依赖，不能拿移动分支当旧binary对应源码，见[GPL全文](https://www.gnu.org/licenses/gpl-3.0.html)。

不含vendor APK/反编译源码/签名材料。官方logo隔离于Resources/BrandLogos并记URL/hash，不改为GPL。可下载不等于再分发许可，发布源码／binary前看权利人条款；产品名/logo仅表互通目标，无商标许可／官方认证暗示。

应用图标为icon.swift原创折纸。paperplane等SF Symbols向macOS运行时请求，不嵌入应用图标；见[Apple指引](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)。
