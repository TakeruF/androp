# 文档画面

简体中文 · [English](README.en.md)

PNG由实际候选／进度／设置／信任SwiftUI视图加虚构数据渲染，**不是实机兼容或真实传输证据**。

| 文件 | 场景 |
| --- | --- |
| `recipients-zh.png`、`recipients-en.png` | 6个虚构手机／平板／电脑，含Huawei及品牌类型角标 |
| `sending-zh.png`、`sending-en.png` | 向OPPO/Huawei发Project.pdf的独立42%／68%合成进度 |
| `trusted-zh.png`、`trusted-en.png` | 虚构历史离线OPPO手机平板及Huawei手机、信任控件 |
| `settings-zh.png`、`settings-en.png` | Studio Mac、~/Downloads、语言、通知、自动更新、底部链接 |

macOS仓库根目录按[构建](../building.md)备Swift工具链后执行：

```sh
python3 scripts/render-docs.py
```

脚本编译生产UI临时副本并追加scripts/DocumentationPreview.swift，独立bundle ID/volatile设置，临时替换Computer Name为固定值。不装delegate、不显窗口、不启蓝牙/通知/engine/登录项，不读真历史／连设备／改安装版。演示viewport扩大显示全部控件，真实窗口有上限和滚动；版本来自release.json。直接渲染2×PNG，移除EXIF/文本/时间元数据。

UI/本地化后复查8张。SwiftUI抓图不含系统阴影/菜单栏/许可dialog/通知banner，不在此模拟。运行日志放目录外。项目文档GPL-3.0-only，厂商素材独立权利见[来源](../../Resources/BrandLogos/README.md)，SF Symbols仅作为Mac UI渲染。旧接收面板截图归[独立原型](../../Prototypes/ReceivePanel/README.md)，不是现功能。
