import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.oldsalt.peek", category: "mcp")
private let auditLog = Logger(subsystem: "com.oldsalt.peek", category: "audit")

// HTTP-transport MCP (Model Context Protocol) server. Bound to 127.0.0.1
// only — no external traffic. Bearer-token auth on every request via the
// `Authorization: Bearer <token>` header.
//
// Why HTTP rather than stdio (the original MCP transport): under MAS App
// Sandbox a client-spawned stdio child runs in its own container and can't
// drive Peek's main app (where the captured screen-recording grant lives)
// without bridging back via IPC. That bridge would be HTTP-shaped anyway.
// Going HTTP-first lets every MCP client that supports HTTP/Streamable-HTTP
// (Claude Desktop, Claude Code, Cursor, …) just work.
//
// Implemented JSON-RPC methods:
//   initialize        → handshake + server capabilities
//   tools/list        → enumerate the tool surface (from the delegate)
//   tools/call        → dispatch to the delegate
//   ping              → liveness probe
//
// Tool surface is delegate-driven. Task #4 lands the scaffold with no
// delegate; task #5 plugs in a Peek-specific delegate that wraps
// `WindowCapture`. Bounded body size (256 KiB) and one-shot connections
// keep the attack surface small for a localhost service.

@MainActor
protocol MCPDelegate: AnyObject {
    /// JSON-RPC tool descriptors for `tools/list`. Return [] if no tools are exposed.
    func mcpToolDefinitions() -> [JSONValue]

    /// Optional server-level description returned in the `initialize` result's
    /// `instructions` field. Clients (Claude Desktop / Code) surface this to the
    /// model so it understands what the server is for and how its trust gates
    /// behave. Return nil to omit the field.
    func mcpInstructions() -> String?

    /// Invoke a tool by name. Throw `MCPToolError` for protocol-meaningful failures;
    /// any other thrown error is reported as `-32603 internal error`.
    func mcpCallTool(name: String, args: [String: JSONValue]) async throws -> JSONValue
}

enum MCPToolError: Error {
    case unknownTool(String)
    case invalidArguments(String)
    case internalError(String)

    var jsonRPCCode: Int {
        switch self {
        case .unknownTool, .invalidArguments: return -32602
        case .internalError: return -32603
        }
    }

    var message: String {
        switch self {
        case .unknownTool(let n):       return "unknown tool: \(n)"
        case .invalidArguments(let m):  return m
        case .internalError(let m):     return m
        }
    }
}

@MainActor
final class MCPServer {
    static let defaultPort: UInt16 = 11474
    // Try a small range so an existing collider on the default port doesn't
    // brick the feature — the chosen port surfaces in Settings for the user
    // to paste into their client config.
    private static let portRange: ClosedRange<UInt16> = 11474...11479

    private weak var delegate: MCPDelegate?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var actualPort: UInt16?

    init(delegate: MCPDelegate? = nil) {
        self.delegate = delegate
    }

    func setDelegate(_ delegate: MCPDelegate?) {
        self.delegate = delegate
    }

    var isRunning: Bool { listener != nil }

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredInterfaceType = .loopback

        var lastError: Error?
        for candidate in Self.portRange {
            do {
                let port = NWEndpoint.Port(rawValue: candidate)!
                let l = try NWListener(using: params, on: port)
                self.listener = l
                self.actualPort = candidate
                lastError = nil
                break
            } catch {
                lastError = error
            }
        }
        guard let listener else {
            throw lastError ?? NSError(
                domain: "com.oldsalt.peek.mcp",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No port in \(Self.portRange) available"]
            )
        }

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in self?.handleListenerState(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection: connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        log.info("mcp server listening on 127.0.0.1:\(self.actualPort ?? 0, privacy: .public)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        actualPort = nil
        for conn in connections.values { conn.cancel() }
        connections.removeAll()
        log.info("mcp server stopped")
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .failed(let err):
            log.error("mcp listener failed: \(err.localizedDescription, privacy: .public)")
            stop()
        case .cancelled:
            log.info("mcp listener cancelled")
        default:
            break
        }
    }

    // Hard ceiling on concurrent connections. A misbehaving (or malicious)
    // local process could otherwise hold thousands of slow-loris connections
    // open and exhaust file descriptors. 32 is well above the few any real
    // MCP workflow uses.
    private static let maxConcurrentConnections = 32

    // Per-request read deadline. Defends against slow-loris by guaranteeing
    // every connection terminates within a bounded window even if the peer
    // dribbles bytes one at a time.
    private static let requestTimeoutSeconds: Double = 10

    private func accept(connection: NWConnection) {
        guard connections.count < Self.maxConcurrentConnections else {
            log.warning("mcp: rejecting connection — at capacity (\(Self.maxConcurrentConnections, privacy: .public))")
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in self?.connections.removeValue(forKey: id) }
            default: break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        // Detach so we can `await` on the connection without blocking the
        // listener queue.
        Task.detached { [weak self] in
            do {
                let request = try await readHTTPRequestWithTimeout(
                    connection: connection,
                    timeout: Self.requestTimeoutSeconds
                )
                let response: HTTPResponse
                if let server = self {
                    response = await server.handle(request: request)
                } else {
                    response = httpPlain(status: 503, body: "server stopped")
                }
                try await writeHTTPResponse(response, to: connection)
            } catch {
                let response = httpPlain(status: 400, body: "bad request: \(error.localizedDescription)")
                try? await writeHTTPResponse(response, to: connection)
            }
            connection.cancel()
        }
    }

    // MARK: - Request handling (main-actor isolated — touches delegate)

    func handle(request: HTTPRequest) async -> HTTPResponse {
        // Host header pinning — defeats DNS rebinding. A site the user visits
        // can resolve `attacker.example` to `127.0.0.1` after the page loads
        // and have the browser issue requests with `Host: attacker.example`.
        // Loopback alone doesn't stop that; this does.
        let portString = actualPort.map(String.init) ?? ""
        let allowedHosts: Set<String> = [
            "127.0.0.1:\(portString)",
            "localhost:\(portString)",
        ]
        guard let host = request.headers["host"], allowedHosts.contains(host) else {
            log.warning("mcp: rejecting host=\(request.headers["host"] ?? "?", privacy: .public)")
            return authErrorResponse(
                httpStatus: 403,
                error: "forbidden",
                description: "Host header not allowed"
            )
        }

        guard let stored = (try? MCPTokenStore.currentToken()), !stored.isEmpty else {
            return authErrorResponse(
                httpStatus: 503,
                error: "server_not_configured",
                description: "MCP server has no bearer token configured"
            )
        }
        guard let auth = request.headers["authorization"],
              isBearer(auth, token: stored) else {
            log.warning("mcp auth failed for \(request.method) \(request.path)")
            return authErrorResponse(
                httpStatus: 401,
                error: "invalid_token",
                description: "Bearer token missing or invalid"
            )
        }

        guard request.method == "POST", request.path == "/" || request.path == "/mcp" else {
            return jsonRPCErrorResponse(httpStatus: 404, code: -32601, message: "endpoint not found")
        }

        let envelope: JSONRPCEnvelope
        do {
            envelope = try JSONDecoder().decode(JSONRPCEnvelope.self, from: request.body)
        } catch {
            return jsonRPCErrorResponse(httpStatus: 400, code: -32700, message: "parse error: \(error.localizedDescription)")
        }
        return await dispatch(envelope: envelope)
    }

    private func isBearer(_ header: String, token: String) -> Bool {
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        // Constant-time compare. Short-circuiting `==` would leak per-byte
        // timing on the localhost path; XOR-fold every byte then test once.
        let presented = Array(String(parts[1]).utf8)
        let expected = Array(token.utf8)
        guard presented.count == expected.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<presented.count {
            diff |= presented[i] ^ expected[i]
        }
        return diff == 0
    }

    private func dispatch(envelope: JSONRPCEnvelope) async -> HTTPResponse {
        let id = envelope.id
        switch envelope.method {
        case "initialize":
            var result: [String: JSONValue] = [
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("peek"),
                    "version": .string(appVersion()),
                ]),
            ]
            if let instructions = delegate?.mcpInstructions(), !instructions.isEmpty {
                result["instructions"] = .string(instructions)
            }
            return jsonRPCSuccess(id: id, result: .object(result))
        case "notifications/initialized", "ping":
            return jsonRPCSuccess(id: id, result: .object([:]))
        case "tools/list":
            let tools = delegate?.mcpToolDefinitions() ?? []
            return jsonRPCSuccess(id: id, result: .object(["tools": .array(tools)]))
        case "tools/call":
            return await invokeTool(id: id, params: envelope.params)
        default:
            return jsonRPCErrorBody(id: id, code: -32601, message: "method not found: \(envelope.method)")
        }
    }

    private func invokeTool(id: JSONRPCID?, params: JSONValue?) async -> HTTPResponse {
        guard case .object(let dict) = params,
              case .string(let name) = dict["name"] ?? .null else {
            return jsonRPCErrorBody(id: id, code: -32602, message: "missing tool name")
        }
        let args: [String: JSONValue]
        if case .object(let a) = dict["arguments"] ?? .object([:]) { args = a } else { args = [:] }

        guard let delegate else {
            return jsonRPCErrorBody(id: id, code: -32601, message: "no tools registered")
        }
        do {
            let result = try await delegate.mcpCallTool(name: name, args: args)
            auditLog.info("mcp tool ok: \(name, privacy: .public)")
            return jsonRPCSuccess(id: id, result: result)
        } catch let error as MCPToolError {
            auditLog.info("mcp tool err: \(name, privacy: .public) \(error.message, privacy: .public)")
            return jsonRPCErrorBody(id: id, code: error.jsonRPCCode, message: error.message)
        } catch {
            auditLog.error("mcp tool failure: \(name, privacy: .public) \(error.localizedDescription, privacy: .public)")
            return jsonRPCErrorBody(id: id, code: -32603, message: error.localizedDescription)
        }
    }

    // MARK: - Reply helpers

    private func jsonRPCSuccess(id: JSONRPCID?, result: JSONValue) -> HTTPResponse {
        let envelope = JSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
        return httpJSON(status: 200, body: envelope.encoded())
    }

    private func jsonRPCErrorBody(id: JSONRPCID?, code: Int, message: String) -> HTTPResponse {
        let err = JSONRPCError(code: code, message: message)
        let envelope = JSONRPCResponse(jsonrpc: "2.0", id: id, result: nil, error: err)
        return httpJSON(status: 200, body: envelope.encoded())
    }

    private func jsonRPCErrorResponse(httpStatus: Int, code: Int, message: String) -> HTTPResponse {
        let err = JSONRPCError(code: code, message: message)
        let envelope = JSONRPCResponse(jsonrpc: "2.0", id: nil, result: nil, error: err)
        return httpJSON(status: httpStatus, body: envelope.encoded())
    }

    // Auth-layer errors live outside JSON-RPC. Streamable-HTTP MCP clients
    // expect an OAuth-style body (RFC 6749 §5.2): `{"error":"…","error_description":"…"}`
    // with a flat string `error` field, not the JSON-RPC `{error: {code, message}}`
    // object — mcp-remote's Zod schema rejects the latter. 401 also carries
    // the Bearer challenge header per RFC 6750.
    private func authErrorResponse(httpStatus: Int, error: String, description: String) -> HTTPResponse {
        struct AuthErrorBody: Encodable {
            let error: String
            let error_description: String
        }
        let body = (try? JSONEncoder().encode(
            AuthErrorBody(error: error, error_description: description)
        )) ?? Data(#"{"error":"\#(error)"}"#.utf8)

        var headers: [(String, String)] = [("Content-Type", "application/json")]
        if httpStatus == 401 {
            // Header-splitting defence: strip CR/LF defensively even though
            // every current call site passes a static literal. If a future
            // caller threads user input through here, the splitting attack
            // is closed at the source.
            let sanitized = description
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            headers.append((
                "WWW-Authenticate",
                "Bearer realm=\"peek\", error=\"\(error)\", error_description=\"\(sanitized)\""
            ))
        }
        return HTTPResponse(status: httpStatus, headers: headers, body: body)
    }
}

// MARK: - Misc helpers

private func appVersion() -> String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
}

// MARK: - HTTP request / response value types (nonisolated, Sendable)

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]  // lowercased keys
    let body: Data
}

struct HTTPResponse: Sendable {
    let status: Int
    let headers: [(String, String)]
    let body: Data

    nonisolated fileprivate var rendered: Data {
        var out = "HTTP/1.1 \(status) \(statusReason(status))\r\n"
        out += "Content-Length: \(body.count)\r\n"
        out += "Connection: close\r\n"
        for (k, v) in headers {
            out += "\(k): \(v)\r\n"
        }
        out += "\r\n"
        var data = Data(out.utf8)
        data.append(body)
        return data
    }
}

nonisolated private func httpJSON(status: Int, body: Data) -> HTTPResponse {
    HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: body)
}

nonisolated private func httpPlain(status: Int, body: String) -> HTTPResponse {
    HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data(body.utf8))
}

nonisolated private func statusReason(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 404: return "Not Found"
    case 500: return "Internal Server Error"
    case 503: return "Service Unavailable"
    default:  return "Status"
    }
}

// MARK: - HTTP I/O (nonisolated free functions)

private enum HTTPParseError: Error, LocalizedError {
    case incomplete
    case malformedRequestLine
    case malformedContentLength
    case bodyTooLarge
    case connectionClosed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .incomplete:             return "incomplete request"
        case .malformedRequestLine:   return "malformed request line"
        case .malformedContentLength: return "malformed Content-Length"
        case .bodyTooLarge:           return "body too large"
        case .connectionClosed:       return "connection closed before request completed"
        case .timedOut:               return "request timed out"
        }
    }
}

nonisolated private let maxBodyBytes = 256 * 1024

// Race the read against a wall-clock deadline. Either one finishing cancels
// the other, so a slow-loris peer can't tie up a connection past `timeout`.
nonisolated private func readHTTPRequestWithTimeout(
    connection: NWConnection,
    timeout: Double
) async throws -> HTTPRequest {
    try await withThrowingTaskGroup(of: HTTPRequest.self) { group in
        group.addTask {
            try await readHTTPRequest(connection: connection)
        }
        group.addTask {
            try await Task.sleep(for: .seconds(timeout))
            throw HTTPParseError.timedOut
        }
        guard let result = try await group.next() else {
            throw HTTPParseError.connectionClosed
        }
        group.cancelAll()
        return result
    }
}

nonisolated private func readHTTPRequest(connection: NWConnection) async throws -> HTTPRequest {
    var buffer = Data()
    let headerTerminator = Data("\r\n\r\n".utf8)
    while buffer.range(of: headerTerminator) == nil {
        let chunk = try await nwReceive(connection: connection, max: 16 * 1024)
        if chunk.isEmpty { throw HTTPParseError.connectionClosed }
        buffer.append(chunk)
        if buffer.count > maxBodyBytes { throw HTTPParseError.bodyTooLarge }
    }
    guard let split = buffer.range(of: headerTerminator) else {
        throw HTTPParseError.incomplete
    }
    let headerData = buffer.prefix(upTo: split.lowerBound)
    var bodyBuffer = Data(buffer.suffix(from: split.upperBound))

    guard let headerString = String(data: headerData, encoding: .utf8) else {
        throw HTTPParseError.malformedRequestLine
    }
    let lines = headerString.components(separatedBy: "\r\n")
    guard let firstLine = lines.first else { throw HTTPParseError.malformedRequestLine }
    let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count >= 2 else { throw HTTPParseError.malformedRequestLine }
    let method = String(parts[0]).uppercased()
    let path = String(parts[1])

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        if let colon = line.firstIndex(of: ":") {
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
    }

    // Content-Length must be ASCII decimal digits only — `Int(raw)` accepts
    // "+5", Unicode digits like "१२३", and leading-zero forms that some
    // intermediaries reject. Be strict, since we use this value to size a
    // buffer read.
    let contentLength: Int
    if let raw = headers["content-length"] {
        guard !raw.isEmpty,
              raw.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let parsed = Int(raw) else {
            throw HTTPParseError.malformedContentLength
        }
        contentLength = parsed
    } else {
        contentLength = 0
    }
    if contentLength > maxBodyBytes { throw HTTPParseError.bodyTooLarge }

    while bodyBuffer.count < contentLength {
        let chunk = try await nwReceive(connection: connection, max: 16 * 1024)
        if chunk.isEmpty { throw HTTPParseError.connectionClosed }
        bodyBuffer.append(chunk)
        if bodyBuffer.count > maxBodyBytes { throw HTTPParseError.bodyTooLarge }
    }

    return HTTPRequest(
        method: method,
        path: path,
        headers: headers,
        body: Data(bodyBuffer.prefix(contentLength))
    )
}

nonisolated private func writeHTTPResponse(_ response: HTTPResponse, to connection: NWConnection) async throws {
    let data = response.rendered
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { cont.resume(throwing: error) }
            else { cont.resume(returning: ()) }
        })
    }
}

nonisolated private func nwReceive(connection: NWConnection, max: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: max) { content, _, isComplete, error in
            if let error { cont.resume(throwing: error); return }
            if let content { cont.resume(returning: content); return }
            if isComplete { cont.resume(returning: Data()); return }
            cont.resume(returning: Data())
        }
    }
}

// MARK: - JSON-RPC value model (nonisolated — pure data)

enum JSONRPCID: Codable, Sendable {
    case integer(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .integer(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(
            JSONRPCID.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "JSON-RPC id must be int or string")
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .integer(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

struct JSONRPCEnvelope: Decodable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String
    let params: JSONValue?
}

struct JSONRPCError: Encodable, Sendable {
    let code: Int
    let message: String
}

struct JSONRPCResponse: Encodable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID?
    let result: JSONValue?
    let error: JSONRPCError?

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
    }
}

// Codable JSON value, just enough for arg passthrough and result construction.
enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrecognized JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let b):   try c.encode(b)
        case .int(let i):    try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
