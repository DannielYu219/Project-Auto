import Foundation

/// Coordinates are relative to the WKWebView content viewport's top-left, in CSS pixels.
/// Input actions synthesize DOM events; they never claim browser-trusted user activation.
public enum BrowserAction: Codable, Sendable {
    case navigate(url: String)
    case click(x: Double, y: Double)
    case scroll(deltaX: Double, deltaY: Double)
    case type(text: String)
    case key(key: String)
    case back, forward, reload

    private enum CodingKeys: String, CodingKey { case action, url, x, y, deltaX = "delta_x", deltaY = "delta_y", text, key }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .action) {
        case "navigate": self = .navigate(url: try values.decode(String.self, forKey: .url))
        case "click": self = .click(x: try values.decode(Double.self, forKey: .x), y: try values.decode(Double.self, forKey: .y))
        case "scroll": self = .scroll(deltaX: try Self.number(values, key: .deltaX), deltaY: try Self.number(values, key: .deltaY))
        case "type": self = .type(text: try values.decode(String.self, forKey: .text))
        case "key": self = .key(key: try values.decode(String.self, forKey: .key))
        case "back": self = .back
        case "forward": self = .forward
        case "reload": self = .reload
        default: throw DecodingError.dataCorruptedError(forKey: .action, in: values, debugDescription: "Unsupported browser action. Expected navigate, click, scroll, type, key, back, forward, or reload.")
        }
    }

    private static func number(_ values: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Double {
        try values.decodeIfPresent(Double.self, forKey: key) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .action)
        switch self {
        case .navigate(let url): try values.encode(url, forKey: .url)
        case .click(let x, let y): try values.encode(x, forKey: .x); try values.encode(y, forKey: .y)
        case .scroll(let x, let y): try values.encode(x, forKey: .deltaX); try values.encode(y, forKey: .deltaY)
        case .type(let text): try values.encode(text, forKey: .text)
        case .key(let key): try values.encode(key, forKey: .key)
        case .back, .forward, .reload: break
        }
    }

    public var name: String {
        switch self {
        case .navigate: "navigate"
        case .click: "click"
        case .scroll: "scroll"
        case .type: "type"
        case .key: "key"
        case .back: "back"
        case .forward: "forward"
        case .reload: "reload"
        }
    }
}

public struct BrowserFailure: Error, Codable, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

public struct BrowserTab: Identifiable, Codable, Sendable {
    public let id: UUID
    public internal(set) var url = "about:blank"
    public internal(set) var title = "New Tab"
    public internal(set) var loading = false
    public internal(set) var estimatedProgress = 0.0
    public internal(set) var canGoBack = false
    public internal(set) var canGoForward = false
    public internal(set) var error: BrowserFailure?
    public internal(set) var isAgentControlled = false
    public internal(set) var isBackground = false

    enum CodingKeys: String, CodingKey {
        case id, url, title, loading, error
        case estimatedProgress = "estimated_progress", canGoBack = "can_go_back", canGoForward = "can_go_forward"
        case isAgentControlled = "agent_controlled", isBackground = "background"
    }
}

public struct BrowserRect: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct BrowserViewport: Codable, Sendable {
    public let width: Double
    public let height: Double
    public let scrollX: Double
    public let scrollY: Double
    public let devicePixelRatio: Double
    public let coordinateSpace: String
    public let nativeBounds: BrowserRect
    /// AppKit screen coordinates (points, bottom-left origin); never pass these to click.
    public let screenFrame: BrowserRect?
    public let attachedToWindow: Bool

    enum CodingKeys: String, CodingKey {
        case width, height
        case scrollX = "scroll_x", scrollY = "scroll_y", devicePixelRatio = "device_pixel_ratio"
        case coordinateSpace = "coordinate_space", nativeBounds = "native_bounds"
        case screenFrame = "screen_frame", attachedToWindow = "attached_to_window"
    }
}

public struct BrowserSnapshot: Codable, Sendable {
    public let selectedTabID: UUID?
    public let url: String?
    public let title: String?
    public let loading: Bool
    public let tabs: [BrowserTab]
    public let viewport: BrowserViewport?
    public let inputEvents: String

    enum CodingKeys: String, CodingKey {
        case url, title, loading, tabs, viewport
        case selectedTabID = "selected_tab_id", inputEvents = "input_events"
    }
}

public struct BrowserActionResult: Codable, Sendable {
    public let ok: Bool
    public let action: String
    public let tabID: UUID?
    public let message: String
    public let error: BrowserFailure?
    /// JSON produced by the DOM command, including actual offsets and event cancellation.
    public let detailsJSON: String?
    public let snapshot: BrowserSnapshot?

    enum CodingKeys: String, CodingKey {
        case ok, action, message, error, snapshot
        case tabID = "tab_id", detailsJSON = "details_json"
    }
}
