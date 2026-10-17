// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Native UDP transport. Protocol and peer validation live in the engine.
@MainActor final class HuaweiLANDiscovery {
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var address: UInt32 = 0
    private var mask: UInt32 = 0
    private let receive: (String, Int, String, Data) -> Void
    /// Reports a fixed transport phase and a bounded errno. Addresses, device
    /// names, datagrams, keys and OS message strings are never passed on.
    private let report: @MainActor (String, Int?) -> Void
    private var reported: [String: Date] = [:]
    private static let throttle: TimeInterval = 60
    init(receive: @escaping (String, Int, String, Data) -> Void,
         report: @escaping @MainActor (String, Int?) -> Void) {
        self.receive = receive; self.report = report
    }

    /// Collapses repeated identical failures so a per-second retry loop cannot
    /// flood the diagnostics log.
    private func fail(_ phase: String, _ code: Int32 = 0) {
        let number = (1..<4096).contains(Int(code)) ? Int(code) : nil
        let key = "\(phase)/\(number ?? -1)"
        let now = Date()
        if let previous = reported[key], now.timeIntervalSince(previous) < Self.throttle { return }
        if reported.count >= 64 { reported.removeAll() }
        reported[key] = now
        report(phase, number)
    }

    func stop() {
        source?.cancel(); source = nil
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }
    func start() {
        guard descriptor < 0 else { return }
        address = 0; mask = 0
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { fail("transport_enumerate", Darwin.errno); return }
        defer { freeifaddrs(list) }
        var item = list
        while let current = item {
            defer { item = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == "en0",
                  let raw = current.pointee.ifa_addr, raw.pointee.sa_family == UInt8(AF_INET),
                  let rawMask = current.pointee.ifa_netmask else { continue }
            address = UnsafeRawPointer(raw).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            mask = UnsafeRawPointer(rawMask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            break
        }
        guard address != 0 else { fail("transport_interface"); return }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { fail("transport_socket", Darwin.errno); return }
        // Close only after the errno of the failing call has been captured.
        func abandon(_ phase: String) { let code = Darwin.errno; Darwin.close(fd); fail(phase, code) }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { abandon("transport_broadcast"); return }
        var interface = if_nametoindex("en0")
        guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &interface, socklen_t(MemoryLayout.size(ofValue: interface))) == 0 else { abandon("transport_interface_bind"); return }
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); local.sin_family = UInt8(AF_INET)
        local.sin_port = UInt16(5684).bigEndian; local.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        // The port stays single-owner on purpose: no SO_REUSEADDR, no SO_REUSEPORT.
        guard bound == 0 else { abandon("transport_bind"); return }
        var membership = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr("224.0.0.1")), imr_interface: in_addr(s_addr: address))
        if setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout.size(ofValue: membership))) != 0 {
            // Unicast discovery still works, so keep the socket and only report.
            fail("transport_multicast_join", Darwin.errno)
        }
        var outgoing = in_addr(s_addr: address)
        if setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &outgoing, socklen_t(MemoryLayout.size(ofValue: outgoing))) != 0 {
            fail("transport_multicast_interface", Darwin.errno)
        }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { abandon("transport_nonblocking"); return }
        descriptor = fd
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        reader.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } }
        source = reader; reader.resume()
    }
    private func string(_ address: UInt32) -> String {
        var value = in_addr(s_addr: address)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    private func readAvailable() {
        guard descriptor >= 0 else { return }
        // Bound work on the main queue even when the LAN is busy.
        for _ in 0..<32 {
            var remote = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            var bytes = [UInt8](repeating: 0, count: 8193)
            let count = withUnsafeMutablePointer(to: &remote) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, &bytes, bytes.count, 0, $0, &length)
                }
            }
            guard count >= 0 else {
                let code = Darwin.errno
                // EAGAIN/EWOULDBLOCK is the normal end of the ready datagrams.
                if code != EAGAIN, code != EWOULDBLOCK, code != EINTR { fail("transport_receive", code) }
                return
            }
            guard count <= 8192, remote.sin_family == UInt8(AF_INET), remote.sin_addr.s_addr != address,
                  remote.sin_addr.s_addr & mask == address & mask else { continue }
            receive(string(remote.sin_addr.s_addr), Int(UInt16(bigEndian: remote.sin_port)), string(address), Data(bytes.prefix(count)))
        }
    }
    func send(host: String, encoded: String) {
        guard descriptor >= 0 else { fail("transport_unavailable"); return }
        guard let data = Data(base64Encoded: encoded), data.count <= 8192 else { fail("transport_payload"); return }
        var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = UInt8(AF_INET); target.sin_port = UInt16(5684).bigEndian
        if host == "broadcast" { target.sin_addr.s_addr = address | ~mask }
        else if host == "multicast" { target.sin_addr.s_addr = inet_addr("224.0.0.1") }
        else {
            guard inet_pton(AF_INET, host, &target.sin_addr) == 1,
                  target.sin_addr.s_addr != address, target.sin_addr.s_addr & mask == address & mask else {
                // The rejected host itself stays out of the diagnostics log.
                fail("transport_target"); return
            }
        }
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { fail("transport_send", Darwin.errno) }
        else if sent != data.count { fail("transport_send_partial") }
    }
}
