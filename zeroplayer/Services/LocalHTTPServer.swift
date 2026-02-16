import Foundation
import Network
import SystemConfiguration

protocol SegmentGenerator: AnyObject, Sendable {
    func generateSegment(index: Int) async throws -> URL
}

/// Local HTTP server for serving HLS content to AVPlayer
/// Uses Apple's built-in Network framework (no external dependencies)
///
/// IMPORTANT: This class is `nonisolated` (opted out of MainActor) because
/// NWConnection/NWListener callbacks fire on a background DispatchQueue.
/// If this were MainActor-isolated, those callbacks would need to hop to the
/// main actor to call any method, causing deadlocks when the main actor is
/// blocked in an await (e.g., selfTest or the start() continuation).
nonisolated final class LocalHTTPServer: @unchecked Sendable {
    
    enum ServerError: Error {
        case failedToStart
        case notRunning
        case invalidPlaylistPath
    }
    
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.zeroplayer.httpserver")
    
    private(set) var isRunning = false
    private(set) var serverURL: URL?
    private var sourceFileURL: URL?
    
    // Use protocol-based callback to avoid closure parameter corruption
    weak var segmentGenerator: SegmentGenerator?
    
    private let port: UInt16 = 8080
    private var hlsDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("video_output", isDirectory: true)
    }
    
    init() {}
    
    /// Returns the device's Wi-Fi IP address, or falls back to 127.0.0.1
    private func getWiFiIPAddress() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return address
        }
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            // IPv4 only
            guard addrFamily == UInt8(AF_INET) else { continue }
            
            let name = String(cString: interface.ifa_name)
            // en0 = Wi-Fi on iOS
            guard name == "en0" else { continue }
            
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                          &hostname, socklen_t(hostname.count),
                          nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                address = String(cString: hostname)
            }
        }
        
        return address
    }
    
    /// Starts the local HTTP server and waits until it's ready to accept connections
    func start() async throws {
        guard !isRunning else { return }
        
        // Ensure HLS directory exists
        try? FileManager.default.createDirectory(at: hlsDirectory, withIntermediateDirectories: true)
        
        // Use the device's Wi-Fi IP so AirPlay receivers (Apple TV) can reach us
        let ipAddress = getWiFiIPAddress()
        self.serverURL = URL(string: "http://\(ipAddress):\(port)")
        
        // Listen on all interfaces so both local and AirPlay devices can connect
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port)) else {
            throw ServerError.failedToStart
        }
        
        self.listener = listener
        
        // Handle new connections
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        
        // Wait for the listener to be fully ready before returning
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.isRunning = true
                    if !resumed {
                        resumed = true
                        continuation.resume()
                    }
                case .failed(let error):
                    self?.isRunning = false
                    self?.serverURL = nil
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    self?.isRunning = false
                    self?.serverURL = nil
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: ServerError.failedToStart)
                    }
                default:
                    break
                }
            }
            
            // Start listening
            listener.start(queue: self.queue)
        }
        
        // Log the actual listening port/endpoint
        if let listener = self.listener {
            print("🌐 HTTP server ready on port \(listener.port?.rawValue ?? 0)")
        }
    }
    
    /// Tests connectivity to the server from within this process
    func selfTest() async -> Bool {
        guard let url = serverURL?.appendingPathComponent("master.m3u8") else {
            return false
        }
        
        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            let session = URLSession(configuration: config)
            let (_, response) = try await session.data(from: url)
            let httpResponse = response as? HTTPURLResponse
            let passed = httpResponse?.statusCode == 200
            if !passed {
                print("⚠️ Server self-test failed: HTTP \(httpResponse?.statusCode ?? -1)")
            }
            return passed
        } catch {
            print("⚠️ Server self-test failed: \(error)")
            return false
        }
    }
    
    /// Stops the local HTTP server
    func stop() {
        guard isRunning else { return }
        
        // Cancel all active connections
        activeConnections.forEach { $0.cancel() }
        activeConnections.removeAll()
        
        // Stop listener
        listener?.cancel()
        listener = nil
        
        serverURL = nil
        isRunning = false
        
        print("HTTP Server stopped")
    }
    
    /// Returns the local URL for a given HLS playlist
    func playlistURL(for playlistName: String = "master.m3u8") -> URL? {
        guard let serverURL = serverURL else { return nil }
        return serverURL.appendingPathComponent(playlistName)
    }
    
    /// Sets the source video file URL for direct serving
    func setSourceFile(_ url: URL) {
        self.sourceFileURL = url
    }
    
    // MARK: - Connection Handling
    
    private func handleConnection(_ connection: NWConnection) {
        activeConnections.append(connection)
        
        // Wait for connection to become ready before reading
        // connection.start() is async — the connection is in .setup state initially
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequest(from: connection)
            case .failed(_):
                self?.activeConnections.removeAll { $0 === connection }
            case .cancelled:
                self?.activeConnections.removeAll { $0 === connection }
            default:
                break
            }
        }
        
        connection.start(queue: queue)
    }
    
    private func receiveRequest(from connection: NWConnection) {
        // Check connection state before trying to receive
        guard connection.state == .ready else {
            self.activeConnections.removeAll { $0 === connection }
            return
        }
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            
            // Check for errors (connection reset by peer is normal for HTTP clients)
            if let error = error {
                let nwError = error as NSError
                let isNormalClose = nwError.domain == "NSPOSIXErrorDomain" && (nwError.code == 54 || nwError.code == 57)
                if !isNormalClose {
                    print("⚠️ Connection error: \(error)")
                }
                connection.cancel()
                self.activeConnections.removeAll { $0 === connection }
                return
            }
            
            // Check if connection closed
            if isComplete {
                connection.cancel()
                self.activeConnections.removeAll { $0 === connection }
                return
            }
            
            // Check if we received data
            guard let data = data, !data.isEmpty,
                  let requestString = String(data: data, encoding: .utf8) else {
                // No data yet, keep listening
                self.receiveRequest(from: connection)
                return
            }
            
            // Parse and handle HTTP request
            self.handleHTTPRequest(requestString, connection: connection)
        }
    }
    
    private func handleHTTPRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(status: 400, body: "Bad Request", connection: connection)
            return
        }
        
        // Parse request line: "GET /path HTTP/1.1"
        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 3 else {
            sendResponse(status: 400, body: "Bad Request", connection: connection)
            return
        }

        let method = components[0]
        guard method == "GET" || method == "HEAD" else {
            sendResponse(status: 405, body: "Method Not Allowed", connection: connection)
            return
        }
        
        let path = components[1]
        
        // Log all requests for debugging
        print("🌐 HTTP \(method) \(path)")
        
        // Parse Range header if present
        let rangeHeader = lines.first { $0.lowercased().starts(with: "range:") }
        let range = parseRangeHeader(rangeHeader)
        if let rangeHeader {
            print("🌐 Range header: \(rangeHeader)")
        } else {
            print("🌐 Range header: <none>")
        }
        
        // Serve file
        if method == "HEAD" {
            serveHead(path: path, connection: connection)
        } else {
            serveFile(path: path, range: range, connection: connection)
        }
    }

    private func serveHead(path: String, connection: NWConnection) {
        var cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if let queryIndex = cleanPath.firstIndex(of: "?") {
            cleanPath = String(cleanPath[cleanPath.startIndex..<queryIndex])
        }
        cleanPath = cleanPath.removingPercentEncoding ?? cleanPath

        let filePath: URL
        if (cleanPath.hasSuffix(".mp4") || cleanPath.hasSuffix(".mov") || cleanPath.hasSuffix(".m4v") || cleanPath.hasSuffix(".mkv")),
           let sourceURL = sourceFileURL {
            filePath = sourceURL
        } else {
            filePath = hlsDirectory.appendingPathComponent(cleanPath)
        }

        guard FileManager.default.fileExists(atPath: filePath.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: filePath.path),
              let fileSize = attrs[.size] as? Int64 else {
            sendResponse(status: 404, body: "Not Found", connection: connection)
            return
        }

        sendResponse(
            status: 200,
            headers: [
                "Content-Type": mimeType(for: filePath.pathExtension),
                "Content-Length": "\(fileSize)",
                "Accept-Ranges": "bytes"
            ],
            body: Data(),
            connection: connection
        )
    }
    
    private func serveFile(path: String, range: Range<Int>?, connection: NWConnection) {
        // Clean path: remove leading slash and strip query parameters
        var cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if let queryIndex = cleanPath.firstIndex(of: "?") {
            cleanPath = String(cleanPath[cleanPath.startIndex..<queryIndex])
        }
        cleanPath = cleanPath.removingPercentEncoding ?? cleanPath
        
        // Log subtitle-related requests for debugging
        if cleanPath.hasSuffix(".vtt") || cleanPath.contains("sub_") {
            print("📝 HTTP: subtitle request -> \(cleanPath)")
            
            // Dump the content of VTT files for debugging (first non-empty one)
            if cleanPath.hasSuffix(".vtt") {
                let vttPath = hlsDirectory.appendingPathComponent(cleanPath)
                if let vttContent = try? String(contentsOf: vttPath, encoding: .utf8),
                   vttContent.count > 60 {  // More than just header = has cues
                    print("📝 VTT content (\(cleanPath)):\n\(vttContent.prefix(500))")
                }
            }
        }
        
        // Check if this is a segment request (.ts MPEG-TS segments)
        let isSegmentRequest = cleanPath.hasPrefix("segment_") && cleanPath.hasSuffix(".ts")
        if isSegmentRequest {
            // Extract segment index from filename (e.g., "segment_042.ts" -> 42)
            let segmentName = cleanPath
                .replacingOccurrences(of: ".ts", with: "")
            let indexString = segmentName.replacingOccurrences(of: "segment_", with: "")
            
            if let segmentIndex = Int(indexString) {
                // Check if segment already exists (cached)
                let segmentPath = hlsDirectory.appendingPathComponent(cleanPath)
                if FileManager.default.fileExists(atPath: segmentPath.path) {
                    serveExistingFile(at: segmentPath, range: range, connection: connection)
                    return
                }
                
                // Generate segment on-the-fly
                if let generator = segmentGenerator {
                    print("⚡ Generating segment \(segmentIndex)...")
                    
                    let indexToGenerate = Int(exactly: segmentIndex)!
                    
                    let capturedConnection = connection
                    let capturedRange = range
                    
                    Task { [weak self] in
                        guard let self = self else { return }
                        do {
                            let generatedSegmentPath = try await generator.generateSegment(index: indexToGenerate)
                            
                            // Serve the generated segment (check connection still alive)
                            if capturedConnection.state == .ready {
                                self.serveExistingFile(at: generatedSegmentPath, range: capturedRange, connection: capturedConnection)
                            }
                        } catch {
                            print("❌ Failed to generate segment \(indexToGenerate): \(error)")
                            if capturedConnection.state == .ready {
                                self.sendResponse(status: 500, body: "Segment Generation Failed", connection: capturedConnection)
                            }
                        }
                    }
                    return
                } else {
                    print("❌ No segment generation callback configured")
                    sendResponse(status: 500, body: "Server Not Configured", connection: connection)
                    return
                }
            }
        }
        
        // Determine which file to serve (playlist or other files)
        var fileToServe: URL?
        
        // HLS playlists, subtitles, and segments always come from the HLS
        // directory. Only serve the source file for requests that look like
        // the actual video filename.
        let isHLSSegment = cleanPath.hasPrefix("segment_") && cleanPath.hasSuffix(".ts")
        if cleanPath.hasSuffix(".m3u8") || cleanPath.hasSuffix(".vtt") || cleanPath.hasSuffix(".ts") || isHLSSegment {
            // Generated HLS content — always from HLS directory
            fileToServe = hlsDirectory.appendingPathComponent(cleanPath)
        } else if cleanPath.hasSuffix(".mp4") || cleanPath.hasSuffix(".mov") || cleanPath.hasSuffix(".m4v") || cleanPath.hasSuffix(".mkv") {
            // Video file request — serve from source file if available
            if let sourceURL = sourceFileURL {
                fileToServe = sourceURL
            } else {
                fileToServe = hlsDirectory.appendingPathComponent(cleanPath)
            }
        } else {
            // Everything else from HLS directory
            fileToServe = hlsDirectory.appendingPathComponent(cleanPath)
        }
        
        guard let filePath = fileToServe else {
            sendResponse(status: 404, body: "Not Found", connection: connection)
            return
        }
        
        serveExistingFile(at: filePath, range: range, connection: connection)
    }
    
    private func serveExistingFile(at filePath: URL, range: Range<Int>?, connection: NWConnection) {
        // Check if file exists
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            sendResponse(status: 404, body: "Not Found", connection: connection)
            return
        }
        
        // Verify we can read the file (important for security-scoped resources)
        guard FileManager.default.isReadableFile(atPath: filePath.path) else {
            sendResponse(status: 403, body: "Forbidden", connection: connection)
            return
        }
        
        // Get file size without loading into memory
        guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: filePath.path),
              let fileSize = fileAttributes[.size] as? Int64 else {
            sendResponse(status: 500, body: "Internal Server Error", connection: connection)
            return
        }
        
        // Determine content type
        let contentType = mimeType(for: filePath.pathExtension)
        
        // Playlist and subtitle files should not be cached by AVPlayer
        let isPlaylistOrSubtitle = ["m3u8", "vtt"].contains(filePath.pathExtension.lowercased())
        
        // HLS segments (.ts MPEG-TS files) should ALWAYS be loaded
        // into memory and sent immediately. They are small (typically 200KB-2MB) and
        // AVPlayer expects immediate full content.
        let isSegmentFile = filePath.pathExtension.lowercased() == "ts" &&
            filePath.lastPathComponent.hasPrefix("segment_")
        
        // For video files (but NOT .ts segments), ALWAYS use streaming (never load into memory)
        let isLargeVideoFile = ["mp4", "mov", "m4v", "mkv", "avi"].contains(filePath.pathExtension.lowercased())
        
        // For .ts segments OR small files (< 1MB) that aren't large video files, read into memory
        if isSegmentFile || (fileSize < 1_000_000 && !isLargeVideoFile) {
            guard let fileData = try? Data(contentsOf: filePath) else {
                sendResponse(status: 500, body: "Internal Server Error", connection: connection)
                return
            }
            
            // Handle range request
            if let range = range {
                let start = max(0, range.lowerBound)
                let endExclusive = min(fileData.count, range.upperBound)

                guard start < fileData.count, start < endExclusive else {
                    sendResponse(status: 416, body: "Range Not Satisfiable", connection: connection)
                    return
                }

                let rangeData = fileData[start..<endExclusive]
                sendResponse(
                    status: 206,
                    headers: [
                        "Content-Type": contentType,
                        "Content-Length": "\(rangeData.count)",
                        "Content-Range": "bytes \(start)-\(endExclusive - 1)/\(fileData.count)",
                        "Accept-Ranges": "bytes"
                    ],
                    body: Data(rangeData),
                    connection: connection
                )
            } else {
                // Full content
                var headers = [
                    "Content-Type": contentType,
                    "Content-Length": "\(fileData.count)",
                    "Accept-Ranges": "bytes"
                ]
                if isPlaylistOrSubtitle {
                    headers["Cache-Control"] = "no-cache, no-store"
                }
                sendResponse(
                    status: 200,
                    headers: headers,
                    body: fileData,
                    connection: connection
                )
            }
        } else {
            // Some AirPlay receivers require byte-range semantics even for initial request.
            // If no Range header is sent for a large video file, serve it as 206 from byte 0.
            let effectiveRange = range ?? (isLargeVideoFile ? (0..<Int(fileSize)) : nil)
            // For large files, use streaming with FileHandle
            serveFileStreaming(filePath: filePath, fileSize: Int(fileSize), contentType: contentType, range: effectiveRange, connection: connection)
        }
    }
    
    private func serveFileStreaming(filePath: URL, fileSize: Int, contentType: String, range: Range<Int>?, connection: NWConnection) {
        guard let fileHandle = try? FileHandle(forReadingFrom: filePath) else {
            sendResponse(status: 500, body: "Internal Server Error", connection: connection)
            return
        }
        
        defer {
            try? fileHandle.close()
        }
        
        // Handle range request
        if let range = range {
            let start = max(0, range.lowerBound)
            let end = min(fileSize, range.upperBound) // upperBound is exclusive
            
            guard start < fileSize, start < end else {
                sendResponse(status: 416, body: "Range Not Satisfiable", connection: connection)
                return
            }
            
            let length = end - start // Already correct since end is exclusive
            
            // Seek to start position
            try? fileHandle.seek(toOffset: UInt64(start))
            
            // For ranges > 512KB, always stream in chunks to minimize memory
            if length > 524_288 {
                // Do blocking send/wait work off the NWConnection callback queue
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    // Send headers first
                    let statusText = self?.httpStatusText(206) ?? "Partial Content"
                    var response = "HTTP/1.1 206 \(statusText)\r\n"
                    response += "Content-Type: \(contentType)\r\n"
                    response += "Content-Length: \(length)\r\n"
                    response += "Content-Range: bytes \(start)-\(end - 1)/\(fileSize)\r\n"
                    response += "Accept-Ranges: bytes\r\n"
                    response += "Connection: keep-alive\r\n"
                    response += "Access-Control-Allow-Origin: *\r\n"
                    response += "\r\n"

                    let headerData = Data(response.utf8)
                    let headerSemaphore = DispatchSemaphore(value: 0)
                    var headerFailed = false
                    connection.send(content: headerData, completion: .contentProcessed { error in
                        if error != nil { headerFailed = true }
                        headerSemaphore.signal()
                    })
                    _ = headerSemaphore.wait(timeout: .now() + 5.0)

                    guard !headerFailed else {
                        connection.cancel()
                        return
                    }

                    // Stream in 512KB chunks to minimize memory usage
                    let chunkSize = 65_536
                    var remaining = length
                    var shouldContinue = true

                    while remaining > 0 && shouldContinue {
                        autoreleasepool {
                            let readSize = min(chunkSize, remaining)
                            if let chunk = try? fileHandle.read(upToCount: readSize), !chunk.isEmpty {
                                let semaphore = DispatchSemaphore(value: 0)
                                var sendFailed = false

                                connection.send(content: chunk, completion: .contentProcessed { error in
                                    if error != nil { sendFailed = true }
                                    semaphore.signal()
                                })

                                let waitResult = semaphore.wait(timeout: .now() + 30.0)
                                if waitResult == .timedOut {
                                    sendFailed = true
                                }

                                if sendFailed {
                                    shouldContinue = false
                                } else {
                                    remaining -= chunk.count
                                }
                            } else {
                                shouldContinue = false
                            }
                        }
                    }

                    if shouldContinue {
                        self?.receiveRequest(from: connection)
                    } else {
                        connection.cancel()
                    }
                }
            } else {
                // For smaller ranges, read into memory
                guard let data = try? fileHandle.read(upToCount: length) else {
                    sendResponse(status: 500, body: "Internal Server Error", connection: connection)
                    return
                }
                
                sendResponse(
                    status: 206,
                    headers: [
                        "Content-Type": contentType,
                        "Content-Length": "\(data.count)",
                        "Content-Range": "bytes \(start)-\(end - 1)/\(fileSize)",
                        "Accept-Ranges": "bytes"
                    ],
                    body: data,
                    connection: connection
                )
            }
        } else {
            // No range header - stream full file body
            try? fileHandle.seek(toOffset: 0)

            let statusText = httpStatusText(200)
            var response = "HTTP/1.1 200 \(statusText)\r\n"
            response += "Content-Type: \(contentType)\r\n"
            response += "Content-Length: \(fileSize)\r\n"
            response += "Accept-Ranges: bytes\r\n"
            response += "Access-Control-Allow-Origin: *\r\n"
            response += "Connection: close\r\n"
            response += "\r\n"

            let headerData = Data(response.utf8)

            // Do blocking send/wait work off the NWConnection callback queue
            DispatchQueue.global(qos: .utility).async {
                let headerSemaphore = DispatchSemaphore(value: 0)
                var headerFailed = false
                connection.send(content: headerData, completion: .contentProcessed { error in
                    if error != nil {
                        headerFailed = true
                    }
                    headerSemaphore.signal()
                })
                _ = headerSemaphore.wait(timeout: .now() + 5.0)

                guard !headerFailed else {
                    connection.cancel()
                    return
                }

                // Stream in 512KB chunks
                let chunkSize = 65_536
                var remaining = fileSize

                while remaining > 0 {
                    autoreleasepool {
                        let readSize = min(chunkSize, remaining)
                        if let chunk = try? fileHandle.read(upToCount: readSize), !chunk.isEmpty {
                            let semaphore = DispatchSemaphore(value: 0)
                            var sendFailed = false

                            connection.send(content: chunk, completion: .contentProcessed { error in
                                if error != nil {
                                    sendFailed = true
                                }
                                semaphore.signal()
                            })

                            let waitResult = semaphore.wait(timeout: .now() + 30.0)
                            if waitResult == .timedOut {
                                sendFailed = true
                            }
                            if sendFailed {
                                remaining = 0
                            } else {
                                remaining -= chunk.count
                            }
                        } else {
                            remaining = 0
                        }
                    }
                }

                // Close after full-file response.
                connection.cancel()
            }
        }
    }
    
    private func sendResponse(status: Int, headers: [String: String] = [:], body: Data, connection: NWConnection) {
        // Check connection is still alive before sending
        guard connection.state == .ready else { return }
        
        let statusText = httpStatusText(status)
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        
        // Add headers
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        
        // Always support keep-alive for HTTP/1.1 (AVPlayer may reuse connections)
        if headers["Connection"] == nil {
            response += "Connection: keep-alive\r\n"
        }
        
        // CORS headers - AVPlayer's XPC process may need these for localhost
        response += "Access-Control-Allow-Origin: *\r\n"
        
        response += "\r\n"
        
        // Convert response to data and append body
        var responseData = Data(response.utf8)
        responseData.append(body)
        
        connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                let nwError = error as NSError
                let isNormalClose = nwError.domain == "NSPOSIXErrorDomain" && (nwError.code == 54 || nwError.code == 57)
                if !isNormalClose {
                    print("⚠️ Send error: \(error)")
                }
                return
            }
            // Listen for next request on this connection (HTTP keep-alive)
            self?.receiveRequest(from: connection)
        })
    }
    
    private func sendResponse(status: Int, body: String, connection: NWConnection) {
        let bodyData = Data(body.utf8)
        sendResponse(
            status: status,
            headers: [
                "Content-Type": "text/plain",
                "Content-Length": "\(bodyData.count)"
            ],
            body: bodyData,
            connection: connection
        )
    }
    
    // MARK: - Utilities
    
    private func parseRangeHeader(_ header: String?) -> Range<Int>? {
        guard let header = header else { return nil }
        
        // Format: "Range: bytes=start-end"
        let parts = header.components(separatedBy: "=")
        guard parts.count == 2 else { return nil }
        
        let range = parts[1].trimmingCharacters(in: .whitespaces)
        let rangeParts = range.components(separatedBy: "-")
        
        guard rangeParts.count == 2,
              let start = Int(rangeParts[0]) else { return nil }

        let endExclusive: Int
        if rangeParts[1].isEmpty {
            endExclusive = Int.max
        } else if let endInclusive = Int(rangeParts[1]) {
            let (value, overflow) = endInclusive.addingReportingOverflow(1)
            endExclusive = overflow ? Int.max : value
        } else {
            return nil
        }

        return start..<endExclusive
    }
    
    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "m3u8":
            return "application/vnd.apple.mpegurl"
        case "ts":
            return "video/mp2t"
        case "mp4", "m4v":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        case "vtt":
            return "text/vtt"
        default:
            return "application/octet-stream"
        }
    }
    
    private func httpStatusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
    
    deinit {
        stop()
    }
}
