//
//  HostWire.swift
//  BuzzerHostProtocol
//
//  Shared encoding helpers for the host protocol (#103): names for core enums
//  and UUID-keyed maps as JSON objects.
//

import BuzzerCore
import Foundation

enum HostWire {

    static func modeName(_ mode: BuzzerMode) -> String {
        switch mode {
        case .disabled: "disabled"
        case .unavailable: "unavailable"
        case .armed: "armed"
        }
    }

    static func mode<K: CodingKey>(named name: String, in container: KeyedDecodingContainer<K>) throws -> BuzzerMode {
        switch name {
        case "disabled": return .disabled
        case "unavailable": return .unavailable
        case "armed": return .armed
        default: throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Unknown buzzer mode"))
        }
    }

    static func windowName(_ window: FinalAnswerWindow) -> String {
        switch window {
        case .closed: "closed"
        case .open: "open"
        case .locked: "locked"
        }
    }

    static func window<K: CodingKey>(named name: String, in container: KeyedDecodingContainer<K>) throws -> FinalAnswerWindow {
        switch name {
        case "closed": return .closed
        case "open": return .open
        case "locked": return .locked
        default: throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Unknown answer window"))
        }
    }

    static func stringKeyed<V>(_ map: [UUID: V]) -> [String: V] {
        Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) })
    }

    static func uuidKeyed<V, K: CodingKey>(_ map: [String: V], in container: KeyedDecodingContainer<K>) throws -> [UUID: V] {
        var result: [UUID: V] = [:]
        for (key, value) in map {
            guard let id = UUID(uuidString: key) else {
                throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Map key is not a team UUID"))
            }
            result[id] = value
        }
        return result
    }
}
