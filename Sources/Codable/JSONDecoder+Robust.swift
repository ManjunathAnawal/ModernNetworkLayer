//
//  JSONDecoder+Robust.swift
//  NetworkLayer
//
//  Central decoder configuration so every response is decoded consistently
//  (date strategy, key strategy) without each Repository re-configuring
//  its own JSONDecoder — a common source of subtle bugs when one endpoint
//  forgets to set `.convertFromSnakeCase` and silently drops fields.
//
import Foundation

public extension JSONDecoder {
    static var robust: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // ISO8601 with fractional seconds is the most common API date
        // format; we fall back to a plain ISO8601 formatter for backends
        // that omit fractional seconds, rather than failing decode
        // entirely over a formatting difference.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]

        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            if let date = fractional.date(from: dateString) { return date }
            if let date = whole.date(from: dateString) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: \(dateString)"
            )
        }
        return decoder
    }
}
