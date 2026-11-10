# Android sharing: incremental receipt and bounded disk I/O

These changes are included in anDrop 1.3.2 (13200). See the [release notes](releases/1.3.2.en.md).

Android sharing receives a single ZIP over HTTPS. The new receive path parses that ZIP while it arrives and saves each completed regular file after checking its ZIP CRC, decoded size, SHA-256 readback, safe filename and download quarantine. Files become visible in the selected destination before the remaining archive has downloaded. Existing names are preserved by choosing a numbered alternative. Cancelling or failing a later file retains files already saved; incomplete files remain private and are removed.

ZIP parsing, hashing, disk writes and outgoing ZIP creation run on disk workers so discovery and network control messages can continue. A queue of at most two 1 MiB input chunks applies backpressure instead of buffering the download in memory. Outgoing preparation opens one source file at a time and copies in 1 MiB chunks without compression, preserving the existing STORED/ZIP64 transport. Cancellation joins the worker before deleting its temporary directory.

The received ZIP is also spooled to disk. Its final central directory, local headers, entry types, declared count and total size are checked before acknowledging overall success. Attributes found only in the central directory cannot be checked before that directory arrives; streamed entries are always created as regular files, never as links. Final validation failure does not remove previously published files.

Some ZIPs cannot be decoded incrementally, notably STORED entries whose local headers omit their lengths. For those, the receiver finishes downloading to disk and then extracts the remaining files with the existing ZIP validations. Files saved before this fallback are not duplicated. This compatibility path cannot show those remaining files before the download finishes. See the upstream [stream-unzip limitations](https://stream-unzip.docs.trade.gov.uk/limitations/).

Local checks cover 200 files totaling about 247 MiB, SHA-256 equality, bounded Python memory, early visibility during a gated real HTTPS download, cancellation, CRC failure, filename collisions, path rejection, a truncated central directory and the compatibility fallback. These checks do not measure real Android phone throughput or prove behavior on an 8 GB Mac.

Huawei source changes use the same one-source-at-a-time preparation policy. Owned Huawei receive sockets now read ahead by at most 64 KiB and consume buffered DFile frames before waiting for more socket data. Wire framing, encryption and deadlines remain unchanged. A local framing-only check reduced reads for 20,000 frames from 40,000 to 565; this is not a phone transfer-speed measurement.
