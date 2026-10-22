import Foundation

/// Locates the TCP port the device's RemotePairing service is listening on.
///
/// iOS picks this port dynamically when `remoted` starts and advertises it
/// over mDNS as `_remotepairing._tcp`, so it is not reliably the classic
/// first-ephemeral port (49152). Browsing for the real port makes tunnel
/// creation work regardless of which port the device happened to choose.
enum RemotePairingPortResolver {
    static let fallbackPort: UInt16 = 49152

    /// Optional manual override, e.g. TunnelRemotePairingPort = "62078"
    private static let overrideDefaultsKey = "TunnelRemotePairingPort"

    /// Returns the discovered port, or the 49152 fallback.
    /// Blocks for up to `timeout` seconds — call from a background queue
    /// (LocationEngine's serial queue).
    static func resolve(timeout: TimeInterval = 3) -> UInt16 {
        if let raw = UserDefaults.standard.string(forKey: overrideDefaultsKey),
           let port = UInt16(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           port > 0 {
            return port
        }

        let browse = MdnsBrowse()
        let semaphore = DispatchSemaphore(value: 0)
        var discovered: UInt16?
        DispatchQueue.global(qos: .userInitiated).async {
            discovered = browse.run(timeout: timeout)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout + 2) == .success,
           let port = discovered {
            return port
        }
        return fallbackPort
    }

    /// Minimal Bonjour browser for a single service type, pumped by hand so it
    /// works on a plain background queue without a permanently running loop.
    private final class MdnsBrowse: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
        private let browser = NetServiceBrowser()
        private var services: [NetService] = []
        private(set) var port: UInt16?

        func run(timeout: TimeInterval) -> UInt16? {
            browser.delegate = self
            browser.schedule(in: .current, forMode: .default)
            browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")

            let deadline = Date().addingTimeInterval(timeout)
            while port == nil && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }

            browser.stop()
            services.forEach { $0.stop() }
            return port
        }

        func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
            services.append(service)
            service.delegate = self
            service.resolve(withTimeout: 2)
        }

        func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {}

        func netServiceDidResolveAddress(_ sender: NetService) {
            guard port == nil, sender.port > 0 else { return }
            port = UInt16(sender.port)
        }

        func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {}
    }
}
