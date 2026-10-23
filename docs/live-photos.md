# 实况照片与动态照片

简体中文 · [English](live-photos.en.md)

此实现增加了 Apple 实况照片、Android／OPPO 动态照片与华为动态照片之间的本地转换。合成媒体与 PhotoKit 验证已通过，实际华为与 OPPO 图库能否识别仍需真机测试。独立的 OPPO 连接问题也仍需真机确认。

## 从 Mac 发送

- 选择 Apple `.pvt` 实况照片包，或一起选择原始 JPEG／HEIC 及其配对 MOV。只有照片与视频的 Apple 资源标识匹配、视频包含静态照片时间标记时，才会合为一张动态照片。不相关的照片与视频仍按独立文件发送。
- 当“照片”提供完整实况照片包时，共享扩展可读取该表示。如果来源应用只提供静态图，请先从“照片”导出未修改的照片和视频，再在 anDrop 中一起选择。
- Apple 配对文件会按接收端转换为单张动态 JPEG：互传联盟设备使用 Android／OPPO 元数据，华为分享使用华为动态照片尾部结构。内嵌视频的 Android／华为动态照片也可直接转换后发给另一类接收端。
- 同一格式的既有动态照片保持原样发送，不覆盖源文件。

## 在 Mac 接收

原始文件保存到所选文件夹。识别到的动态照片还会在旁边生成独立的 `.pvt` 包，内含 JPEG、配对 MOV 与包元数据。照片和视频写入一致的 Apple 标识及静态照片时间标记；PhotoKit 必须成功载入这对资源，才会放入目标文件夹。

OShare 向 Mac 发送实况照片时，也可能使用 `<UUID>@olive.zip`（含同名冲突后的数字后缀）。anDrop 会识别其中同名的照片／视频配对及可选的同名 `_gainmap.jpg`，先验证有界、无子目录的成员，再提取到私有临时文件进行转换。完整 `.pvt` 保存成功后删除传输 ZIP，完成事件与历史路径中只保留生成的包。转换失败时保留 ZIP；清理失败时保留两者并记录 `live_photo_cleanup_failed`。普通 ZIP 仍按普通文件接收。独立增益图不会应用到生成的 Apple 静态图，HDR 保留尚未验证；视频没有内嵌静态照片时刻时使用中点。

收到的实况照片以 `.pvt` 文件保存在所选接收文件夹，默认为“下载”。可手动打开，或再次选择并通过 anDrop 发送。接收时不导入或打开“照片”，不请求图库权限。PhotoKit 验证只载入指定的媒体配对，不读取或写入照片图库。

## 保留范围与限制

修改 EXIF／XMP 时保留 JPEG 压缩图像数据。HEIC 输入会在生成的 Apple／Android 资源中转成 JPEG；接收到的原始 HEIC 不变。视频与音频通过 AVFoundation 直接重新封装。测试比较了压缩数据、呈现时间戳、旋转信息，并核对往返后的静态照片时刻。这些检查使用短的合成 H.264／AAC 素材，不代表已验证全部编码、HDR／增益图或厂商编辑变体。

每张照片的转换输入上限为照片和视频合计 512 MiB；既有传输限制（包括华为接收上限）仍独立适用。对于增益图、多图 MPF、扩展 XMP 或不支持的厂商／微动结构，若转换无法保留其结构，则保留原始文件。转换使用应用自带的原生辅助程序，不需要额外安装 ffmpeg。

共享扩展将完整实况照片复制到其私有 `Caches/anDrop/SharedFiles`，以免来源提供的临时网址失效而中断交接。发送工作目录与失败的转换产物在使用后移除；接收原件及完整 `.pvt` 包会保留。

## 格式依据与验证

- [Android 动态照片规范](https://developer.android.com/media/platform/motion-photo-format)：XMP 容器目录与内嵌视频结构。
- [Apple 实况照片载入](https://developer.apple.com/documentation/photos/phlivephoto/request(withresourcefileurls:placeholderimage:targetsize:contentmode:resulthandler:))：验证生成的照片／视频配对。
- [OpenHarmony 动态照片实现](https://github.com/openharmony/multimedia_media_library/blob/master/frameworks/innerkitsimpl/media_library_helper/src/moving_photo_file_utils.cpp)：华为版本／帧号、播放区间与视频长度尾部字段。
- [OPPO 格式实现参考](https://github.com/Young-Spark/oppo-live-photo-maker)：Oplus XMP、EXIF 标记与 MPF 布局。实际机型识别仍需独立验证。
- [实况照片包参考](https://github.com/RhetTbull/makelive)：`.pvt` 资源布局与 `metadata.plist`。

在 macOS 运行 `python3 scripts/test-live-photo-native.py` 可生成合成素材，验证 PhotoKit 载入及产品 Python 发送／接收转换流程。运行 `python3 -m unittest discover -s tests -p 'test_motion_photo*.py'` 可验证容器检查、原件保留、隔离属性及文件选择回归。
