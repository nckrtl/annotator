import AnnotatorCore
import Darwin
import Foundation

/// Reads the real DOM element from apps that expose a Chrome DevTools port: Electron apps and Chrome
/// started with `--remote-debugging-port`. Nothing to configure: the port is found from the window's process.
/// Apps without a port keep the accessibility result.
actor DevTools {
    /// Per process: its DevTools port, or nil when it has none, and when that was checked.
    private var ports: [pid_t: (port: UInt16?, checked: Date)] = [:]
    /// Per process: its page targets and when they were fetched.
    private var pages: [pid_t: (list: [DevToolsTargets.Target], fetched: Date)] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        return URLSession(configuration: configuration)
    }()

    /// `target` with its DOM element and exact frame, when the app has a DevTools port and one page matches.
    /// `scale` is the display's pixels per point at `point`.
    func inspect(_ target: Target, at point: CGPoint, scale: Double) async -> Target {
        guard target.mode != .region, let area = target.webArea, area.contains(point),
            let port = await port(for: target.app.pid),
            let page = await page(pid: target.app.pid, port: port, url: target.webUrl, title: target.window.title),
            let socket = page.webSocketDebuggerUrl.flatMap(URL.init(string:))
        else { return target }

        let expression = DOMInfo.probe(x: point.x - area.minX, y: point.y - area.minY, scale: scale)
        guard let json = await evaluate(expression, on: socket), let dom = try? DOMInfo.decode(json) else { return target }
        var result = target
        result.dom = dom
        result.mode = .element
        let frame = dom.screenFrame(viewport: area).intersection(area)
        if Geometry.isUsable(frame) { result.frame = frame }
        return result
    }

    // MARK: - Finding the port

    private func port(for pid: pid_t) async -> UInt16? {
        if let cached = ports[pid] {
            // A found port stays valid until a request to it fails; a missing one is checked again after 5 s.
            if cached.port != nil || Date().timeIntervalSince(cached.checked) < 5 { return cached.port }
        }
        var found: UInt16?
        for port in DevTools.listeningPorts(pid: pid) where await isDevTools(port) {
            found = port
            break
        }
        ports[pid] = (found, Date())
        if found != nil { log.info("DevTools port \(found ?? 0) for pid \(pid)") }
        return found
    }

    /// Only a DevTools endpoint answers `/json/version` with a browser debugger URL.
    private func isDevTools(_ port: UInt16) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/version"),
            let (data, response) = try? await session.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return body["webSocketDebuggerUrl"] is String
    }

    /// TCP ports the process listens on, read from the kernel's file descriptor table.
    static func listeningPorts(pid: pid_t) -> [UInt16] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, size) }
        var ports: [UInt16] = []
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let length = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, length) == length,
                info.psi.soi_kind == SOCKINFO_TCP
            else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    // MARK: - Pages

    private func page(pid: pid_t, port: UInt16, url: String?, title: String?) async -> DevToolsTargets.Target? {
        if let cached = pages[pid], Date().timeIntervalSince(cached.fetched) < 3,
            let page = DevToolsTargets.pick(cached.list, url: url, title: title)
        {
            return page
        }
        guard let listURL = URL(string: "http://127.0.0.1:\(port)/json/list"),
            let (data, _) = try? await session.data(from: listURL),
            let list = try? JSONDecoder().decode([DevToolsTargets.Target].self, from: data)
        else {
            // The app quit or closed the port: look again next time.
            ports[pid] = nil
            return nil
        }
        pages[pid] = (list, Date())
        return DevToolsTargets.pick(list, url: url, title: title)
    }

    // MARK: - Evaluating

    /// Runs `expression` in the page and returns its string result. One short-lived socket per call,
    /// so overlapping calls never mix up their replies. Gives up after one second.
    private func evaluate(_ expression: String, on url: URL) async -> String? {
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let message = ["id": 1, "method": "Runtime.evaluate",
                       "params": ["expression": expression, "returnByValue": true]] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: message),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        do {
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask { try await DevTools.roundTrip(socket, text) }
                group.addTask {
                    try await Task.sleep(for: .seconds(1))
                    socket.cancel(with: .goingAway, reason: nil)
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
        } catch {
            log.info("DevTools evaluate failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func roundTrip(_ socket: URLSessionWebSocketTask, _ message: String) async throws -> String? {
        try await socket.send(.string(message))
        while true {
            guard case .string(let reply) = try await socket.receive(),
                let body = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
                body["id"] as? Int == 1
            else { continue }
            let result = (body["result"] as? [String: Any])?["result"] as? [String: Any]
            return result?["value"] as? String
        }
    }
}
