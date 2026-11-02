//
//  PiJSON.swift
//  Project-Auto
//
//  JSONValue 与 Foundation 容器之间的转换、工具参数严格解析。
//  Provider 适配器共用，避免各写一份。
//

import Foundation
import CoreFoundation

nonisolated enum PiJSON {
    static func anyValue(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let bool): return bool
        case .int(let int): return int
        case .double(let double): return double
        case .string(let string): return string
        case .array(let array): return array.map(anyValue)
        case .object(let object): return object.mapValues(anyValue)
        }
    }

    static func jsonValue(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull: return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let value = number.doubleValue
            if value.isFinite, value.rounded() == value, value >= Double(Int.min), value < Double(Int.max) {
                return .int(number.intValue)
            }
            return .double(value)
        case let string as String: return .string(string)
        case let array as [Any]: return .array(array.map(jsonValue))
        case let object as [String: Any]: return .object(object.mapValues(jsonValue))
        default: return .null
        }
    }

    static func int(_ any: Any?) -> Int? {
        if let int = any as? Int { return int }
        if let number = any as? NSNumber { return number.intValue }
        if let double = any as? Double { return Int(double) }
        return nil
    }

    /// 严格解析工具参数：必须是 JSON 对象。失败时返回空对象 + 原因（用于 argumentsError）。
    static func parseObject(_ text: String) -> (arguments: JSONValue, error: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (.object([:]), nil) }
        guard let data = trimmed.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data) else {
            return (.object([:]), "工具参数不是合法 JSON：\(trimmed.prefix(200))")
        }
        let value = jsonValue(any)
        if case .object = value { return (value, nil) }
        return (.object([:]), "工具参数不是 JSON 对象：\(trimmed.prefix(200))")
    }

    /// 工具参数对象 → JSON 字符串（发回 Chat Completions 的 function.arguments）。
    static func encodeString(_ value: JSONValue) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: anyValue(value)),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
