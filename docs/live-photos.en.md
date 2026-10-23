# Live Photos and moving pictures

[简体中文](live-photos.md) · English

This implementation adds local conversion between Apple Live Photos, Android/OPPO Motion Photos and Huawei moving pictures. It has passed synthetic media and PhotoKit validation; recognition in the actual Huawei and OPPO galleries still needs device testing. The separate OPPO connection issue must also be verified on a device.

## Sending from a Mac

- Select an Apple `.pvt` Live Photo package, or select its original JPEG/HEIC and matching MOV together. Same-name image/video resources are combined only when their Apple asset identifiers match and the movie contains a still-image-time marker. An unrelated image and movie remain separate files.
- The Share extension accepts a full Live Photo bundle when Photos provides that representation. If the source application shares only a static image, export the unmodified image and movie from Photos and choose both in anDrop.
- Apple pairs become one moving-picture JPEG for the selected receiver: Android/OPPO metadata for Alliance receivers, or Huawei's moving-picture trailer for Huawei Share. An embedded Android/Huawei moving picture can also be converted directly for the other receiver.
- Existing moving pictures for the same format are sent unchanged. Source files are never replaced.

## Receiving on a Mac

The original incoming file is saved in the selected folder. A recognized moving picture also gets a separate `.pvt` package beside it, containing a JPEG, a paired MOV and package metadata. The two media resources carry matching Apple identifiers and a timed still-photo marker. PhotoKit must successfully load the pair before the package is published.

OShare can send Live Photos to a Mac as `<UUID>@olive.zip`, including numeric filename-collision suffixes. anDrop recognizes that vendor format with one matching image/video pair and an optional matching `_gainmap.jpg`; it validates and extracts bounded, flat entries to private temporary files before conversion. After a complete `.pvt` package is saved, the transport ZIP is removed and only the package is included in completion/history paths. Failed conversion keeps the ZIP; a cleanup failure keeps both files and records `live_photo_cleanup_failed`. Ordinary ZIPs remain ordinary received files. Separate gainmaps are not applied to the generated Apple still, and HDR preservation is unverified. If the movie has no embedded still-photo time, the generated pair uses its midpoint.

Received Live Photos are saved as `.pvt` files in the selected receive folder, Downloads by default. Open them manually or select them for another anDrop transfer. Reception does not import into or open Photos, and requests no Photos-library permission. PhotoKit validation loads only the explicit media pair; it does not read or write the Photos library.

## Preservation and limits

JPEG compressed image data is preserved while EXIF/XMP metadata changes. HEIC input is converted to JPEG for the generated Apple/Android resources; the original received HEIC remains intact. Video and audio use AVFoundation passthrough remuxing. Tests compare their compressed data, presentation timestamps and rotation, and verify the still-photo time across a round trip. These checks use a short synthetic H.264/AAC clip and do not establish every codec, HDR/gainmap or vendor editing variant.

Conversion accepts up to 512 MiB of image and movie data per photo. Existing transfer limits, including Huawei's receive limit, still apply independently. Gainmaps, multi-image MPF, extended XMP and unsupported vendor/cinemagraph structures are retained as originals when conversion cannot preserve their framing. Conversion uses the bundled native helper and needs no external ffmpeg installation.

Share-extension copies live in its private `Caches/anDrop/SharedFiles` folder so the original provider's temporary URL can expire without breaking the handoff. Normal send workspaces and failed conversion outputs are removed after use. Received originals and completed `.pvt` packages are retained.

## Format references and checks

- [Android Motion Photo specification](https://developer.android.com/media/platform/motion-photo-format): XMP container directory and embedded movie framing.
- [Apple Live Photo loading](https://developer.apple.com/documentation/photos/phlivephoto/request(withresourcefileurls:placeholderimage:targetsize:contentmode:resulthandler:)): validation of the generated image/movie pair.
- [OpenHarmony moving-photo implementation](https://github.com/openharmony/multimedia_media_library/blob/master/frameworks/innerkitsimpl/media_library_helper/src/moving_photo_file_utils.cpp): Huawei version/frame, playback interval and video-length trailer fields.
- [OPPO format implementation reference](https://github.com/Young-Spark/oppo-live-photo-maker): Oplus XMP, EXIF marker and MPF layout. Actual model support remains a separate device check.
- [Live Photo package reference](https://github.com/RhetTbull/makelive): `.pvt` resource layout and `metadata.plist`.

Run `python3 scripts/test-live-photo-native.py` on macOS for synthetic media generation, PhotoKit loading and the production Python send/receive conversion hooks. Run `python3 -m unittest discover -s tests -p 'test_motion_photo*.py'` for container validation, original preservation, quarantine and file-selection regressions.
