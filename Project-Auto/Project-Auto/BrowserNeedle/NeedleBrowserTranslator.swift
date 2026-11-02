import Foundation

/// Browser operations use viewport CSS pixels; scrolling is positive right/down.
/// This type intentionally carries no selector or page-inspection capability.
nonisolated enum NeedleBrowserAction: Codable, Equatable, Sendable {
    case navigate(url: String)
    case click(x: Int, y: Int)
    case scroll(deltaX: Int, deltaY: Int)
    case type(text: String)
    case key(key: String)
    case back, forward, reload

    private enum CodingKeys: String, CodingKey {
        case action, url, x, y, deltaX = "delta_x", deltaY = "delta_y", text, key
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .action) {
        case "navigate": self = .navigate(url: try values.decode(String.self, forKey: .url))
        case "click": self = .click(x: try values.decode(Int.self, forKey: .x), y: try values.decode(Int.self, forKey: .y))
        case "scroll": self = .scroll(deltaX: try values.decode(Int.self, forKey: .deltaX), deltaY: try values.decode(Int.self, forKey: .deltaY))
        case "type": self = .type(text: try values.decode(String.self, forKey: .text))
        case "key": self = .key(key: try values.decode(String.self, forKey: .key))
        case "back": self = .back
        case "forward": self = .forward
        case "reload": self = .reload
        default: throw NeedleBrowserTranslatorError.invalidResponse("Unknown browser action")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .navigate(let url): try values.encode("navigate", forKey: .action); try values.encode(url, forKey: .url)
        case .click(let x, let y): try values.encode("click", forKey: .action); try values.encode(x, forKey: .x); try values.encode(y, forKey: .y)
        case .scroll(let x, let y): try values.encode("scroll", forKey: .action); try values.encode(x, forKey: .deltaX); try values.encode(y, forKey: .deltaY)
        case .type(let text): try values.encode("type", forKey: .action); try values.encode(text, forKey: .text)
        case .key(let key): try values.encode("key", forKey: .action); try values.encode(key, forKey: .key)
        case .back: try values.encode("back", forKey: .action)
        case .forward: try values.encode("forward", forKey: .action)
        case .reload: try values.encode("reload", forKey: .action)
        }
    }
}

nonisolated struct NeedleBrowserTranslation: Codable, Sendable {
    let actions: [NeedleBrowserAction]
    let confidence: Double?
    let reasoning: String
    /// Engine-withheld calls are never converted into executable actions.
    let suppressedCallCount: Int

    var json: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }
}

nonisolated enum NeedleBrowserTranslatorError: LocalizedError, Sendable {
    case missingRuntime, invalidInput, launchFailed(String), engineFailed(Int32, String)
    case timedOut, cancelled, invalidResponse(String), ungroundedOutput

    var errorDescription: String? {
        switch self {
        case .missingRuntime: return "Needle runtime is missing. Bundle NeedleRuntime or supply its directory explicitly."
        case .invalidInput: return "Enter an English browser command of at most 2,000 UTF-8 bytes."
        case .launchFailed(let message): return "Could not launch Needle: \(message)"
        case .engineFailed(let code, let message): return "Needle exited with code \(code): \(message)"
        case .timedOut: return "Needle translation exceeded its time limit."
        case .cancelled: return "Needle translation was cancelled."
        case .invalidResponse(let message): return "Invalid Needle response: \(message)"
        case .ungroundedOutput: return "Needle reported browser arguments that were not grounded in the command."
        }
    }
}

/// Invokes the official macOS arm64 CLI without a shell, server, Python, or fallback.
/// Each request gets a fresh process and conversation. Translate first, then let the
/// browser UI review/execute the returned actions according to its confidence policy.
actor NeedleBrowserTranslator {
    nonisolated struct Configuration: Sendable {
        let runtimeDirectory: URL
        var timeout: TimeInterval = 20
        var maxNewTokens: Int = 512
        /// A conservative product gate above the engine's built-in 0.1 floor.
        /// Below this confidence the full request is withheld, never partially run.
        var minimumConfidence: Double = 0.7

        init(runtimeDirectory: URL) { self.runtimeDirectory = runtimeDirectory }

        /// Production layout: Contents/Resources/NeedleRuntime/{needle,needle3.cact,browser-tools.json}.
        /// Development may explicitly set VELUM_NEEDLE_RUNTIME to Runtime/needle.
        static func bundled(in bundle: Bundle = .main) throws -> Configuration {
            if let path = ProcessInfo.processInfo.environment["VELUM_NEEDLE_RUNTIME"], !path.isEmpty {
                return Configuration(runtimeDirectory: URL(fileURLWithPath: path, isDirectory: true))
            }
            if let resources = bundle.resourceURL {
                let directory = resources.appendingPathComponent("NeedleRuntime", isDirectory: true)
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("needle3.cact").path) {
                    return Configuration(runtimeDirectory: directory)
                }
            }
            throw NeedleBrowserTranslatorError.missingRuntime
        }
    }

    private let configuration: Configuration

    init(configuration: Configuration) { self.configuration = configuration }

    func translate(_ command: String) async throws -> NeedleBrowserTranslation {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= 2_000 else { throw NeedleBrowserTranslatorError.invalidInput }
        let operation = NeedleProcessOperation(configuration: configuration, command: command)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try operation.run() })
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

/// Process work and pipe draining stay off the main actor. The lock serializes
/// cancellation, timeout, launch and teardown so no callback terminates a reused PID.
private nonisolated final class NeedleProcessOperation: @unchecked Sendable {
    private let configuration: NeedleBrowserTranslator.Configuration
    private let command: String
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false
    private var timeoutReached = false

    init(configuration: NeedleBrowserTranslator.Configuration, command: String) {
        self.configuration = configuration
        self.command = command
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancellationRequested = true
        if let process, process.isRunning { process.terminate() }
    }

    private func expire() {
        lock.lock(); defer { lock.unlock() }
        guard let process, process.isRunning else { return }
        timeoutReached = true
        process.terminate()
    }

    func run() throws -> NeedleBrowserTranslation {
        let directory = configuration.runtimeDirectory
        let fileManager = FileManager.default
        let flatExecutable = directory.appendingPathComponent("needle")
        let executable = fileManager.isExecutableFile(atPath: flatExecutable.path)
            ? flatExecutable : directory.appendingPathComponent("macos-arm64/needle")
        let model = directory.appendingPathComponent("needle3.cact")
        let tools = directory.appendingPathComponent("browser-tools.json")
        guard fileManager.isExecutableFile(atPath: executable.path),
              fileManager.fileExists(atPath: model.path), fileManager.fileExists(atPath: tools.path)
        else { throw NeedleBrowserTranslatorError.missingRuntime }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--model", model.path, "--tools", tools.path,
                           "--max", String(min(max(configuration.maxNewTokens, 128), 512)),
                           "--fail-input-overflow", "--prompt", command]
        // Deliberately do not inherit application credentials or proxy settings.
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                             "NEEDLE_TELEMETRY": "0", "DO_NOT_TRACK": "1", "HF_HUB_OFFLINE": "1"]
        child.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        child.standardOutput = output
        child.standardError = errors
        lock.lock()
        if cancellationRequested { lock.unlock(); throw NeedleBrowserTranslatorError.cancelled }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw NeedleBrowserTranslatorError.launchFailed(error.localizedDescription) }
        let timer = DispatchWorkItem { [weak self] in self?.expire() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.01, configuration.timeout), execute: timer)
        // Drain stderr concurrently: a full diagnostic pipe must not deadlock stdout.
        let diagnostics = NeedleDataBuffer()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            diagnostics.set(errors.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        group.wait()
        timer.cancel()
        lock.lock()
        process = nil
        let cancelled = cancellationRequested, expired = timeoutReached
        lock.unlock()
        if cancelled { throw NeedleBrowserTranslatorError.cancelled }
        if expired { throw NeedleBrowserTranslatorError.timedOut }
        guard child.terminationStatus == 0 else {
            let message = String(decoding: diagnostics.get().prefix(2_000), as: UTF8.self)
            throw NeedleBrowserTranslatorError.engineFailed(child.terminationStatus, message)
        }
        return try Self.decode(data, minimumConfidence: configuration.minimumConfidence)
    }

    static func decode(_ data: Data, minimumConfidence: Double) throws -> NeedleBrowserTranslation {
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["success"] as? Bool == true,
              let calls = root["function_calls"] as? [[String: Any]], calls.count <= 16
        else { throw NeedleBrowserTranslatorError.invalidResponse("Missing successful function_calls envelope") }
        let confidence = (root["confidence"] as? NSNumber)?.doubleValue
        if let confidence, !confidence.isFinite || !(0...1).contains(confidence) {
            throw NeedleBrowserTranslatorError.invalidResponse("Confidence is outside 0...1")
        }
        let suppressed = (root["suppressed_calls"] as? [Any])?.count ?? 0
        let reasoning = root["reasoning"] as? String ?? ""
        if suppressed > 0 || (!calls.isEmpty && (confidence ?? 0) < minimumConfidence) {
            return NeedleBrowserTranslation(actions: [], confidence: confidence,
                reasoning: reasoning, suppressedCallCount: suppressed + calls.count)
        }
        if let validation = root["validation"] as? [String: Any],
           let ungrounded = validation["ungrounded"] as? [String], !ungrounded.isEmpty, !calls.isEmpty {
            throw NeedleBrowserTranslatorError.ungroundedOutput
        }
        let allowed: [String: Set<String>] = ["navigate": ["url"], "click": ["x", "y"],
            "scroll": ["direction", "pixels"], "type": ["text"], "press_keyboard_key": ["key"],
            "go_back": [], "go_forward": [], "reload": []]
        let actions = try calls.map { call -> NeedleBrowserAction in
            guard Set(call.keys) == ["name", "arguments"], let name = call["name"] as? String,
                  let arguments = call["arguments"] as? [String: Any],
                  let keys = allowed[name], Set(arguments.keys) == keys
            else { throw NeedleBrowserTranslatorError.invalidResponse("Unexpected tool or argument fields") }
            var object = arguments
            switch name {
            case "go_back": object["action"] = "back"
            case "go_forward": object["action"] = "forward"
            case "press_keyboard_key": object["action"] = "key"
            case "scroll":
                // Decode the model's typed enum and amount; never inspect English input.
                struct ScrollArguments: Decodable {
                    enum Direction: String, Decodable { case down, up, left, right }
                    let direction: Direction
                    let pixels: Int
                }
                let scroll = try JSONDecoder().decode(ScrollArguments.self,
                    from: JSONSerialization.data(withJSONObject: arguments))
                guard (1...10_000).contains(scroll.pixels) else {
                    throw NeedleBrowserTranslatorError.invalidResponse("Scroll distance out of range")
                }
                var x = 0, y = 0
                switch scroll.direction {
                case .down: y = scroll.pixels
                case .up: y = -scroll.pixels
                case .left: x = -scroll.pixels
                case .right: x = scroll.pixels
                }
                object = ["action": "scroll", "delta_x": x, "delta_y": y]
            default: object["action"] = name
            }
            let action = try JSONDecoder().decode(NeedleBrowserAction.self, from: JSONSerialization.data(withJSONObject: object))
            switch action {
            case .navigate(let address):
                guard address.utf8.count <= 8_192, let url = URL(string: address),
                      ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                      url.host?.isEmpty == false, url.user == nil, url.password == nil else {
                    throw NeedleBrowserTranslatorError.invalidResponse("Only absolute HTTP(S) URLs without credentials are accepted")
                }
            case .click(let x, let y):
                guard (0...16_384).contains(x), (0...16_384).contains(y) else { throw NeedleBrowserTranslatorError.invalidResponse("Click coordinates out of range") }
            case .scroll(let x, let y):
                guard (-10_000...10_000).contains(x), (-10_000...10_000).contains(y) else { throw NeedleBrowserTranslatorError.invalidResponse("Scroll distance out of range") }
            case .type(let text):
                guard text.utf8.count <= 8_192 else { throw NeedleBrowserTranslatorError.invalidResponse("Text too long") }
            case .key(let key):
                let keys: Set<String> = ["Enter", "Escape", "Tab", "Backspace", "Delete", "ArrowUp", "ArrowDown",
                    "ArrowLeft", "ArrowRight", "Space", "Meta+l", "Meta+a", "Meta+c", "Meta+v", "Meta+r"]
                guard keys.contains(key) else { throw NeedleBrowserTranslatorError.invalidResponse("Unsupported key") }
            case .back, .forward, .reload: break
            }
            return action
        }
        return NeedleBrowserTranslation(actions: actions, confidence: confidence,
            reasoning: root["reasoning"] as? String ?? "",
            suppressedCallCount: (root["suppressed_calls"] as? [Any])?.count ?? 0)
    }
}

private nonisolated final class NeedleDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
