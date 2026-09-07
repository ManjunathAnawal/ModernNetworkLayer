//
//  LossyCodable.swift
//  NetworkLayer
//
//  Backends inevitably ship one malformed element in an otherwise-fine
//  array response (a null where a string was expected, a missing required
//  field on one item, etc). Standard `Decodable` array decoding is
//  all-or-nothing: ONE bad element fails the ENTIRE array, taking down an
//  entire screen because of one bad record. `LossyArray` decodes what it
//  can and silently skips what it can't.
//
//  TRADE-OFF NOTE — lossy decoding vs. failing fast:
//  Silently dropping malformed elements trades correctness-visibility for
//  resilience: the user sees 19 of 20 list items instead of a blank error
//  screen, but a backend regression that corrupts every element could go
//  unnoticed by end users. We mitigate this by having `LossyArray` report
//  its drop count via `Mirror`-free logging (see `droppedCount`) so you
//  can pipe that into analytics/crash reporting instead of losing the
//  signal entirely. Use PLAIN `[Element]` decoding instead of `LossyArray`
//  for payloads where partial data is worse than no data at all — e.g. a
//  financial ledger where a missing transaction must never silently
//  disappear; there, let the whole request fail loudly instead.
//
import Foundation

@propertyWrapper
public struct LossyArray<Element: Decodable>: Decodable {
    public var wrappedValue: [Element]
    /// Number of elements that failed to decode and were dropped. Exposed
    /// so callers can log/report silent data loss rather than it being
    /// truly invisible.
    public private(set) var droppedCount: Int = 0

    public init(wrappedValue: [Element]) {
        self.wrappedValue = wrappedValue
    }

    /// Exposes the wrapper itself via `$propertyName` so callers can read
    /// `droppedCount` (e.g. `response.$users.droppedCount`) without needing
    /// a second, separately-named property just for diagnostics.
    public var projectedValue: LossyArray<Element> { self }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var dropped = 0

        // We can't just do `try? container.decode(Element.self)` in a loop
        // naively, because a THROWING decode of a single element does NOT
        // advance the unkeyed container's internal cursor — the failed
        // element would be decoded again forever, causing an infinite
        // loop. The standard workaround is to decode into a throwaway
        // `AnyDecodableBox`-style single-value container first to force
        // the cursor forward regardless of whether the *typed* decode
        // below succeeds.
        while !container.isAtEnd {
            do {
                let element = try container.decode(Element.self)
                elements.append(element)
            } catch {
                dropped += 1
                // Force the cursor past the malformed element. We decode
                // into `AnyDecodableSkip` (below), which accepts any JSON
                // value shape and discards it, guaranteeing forward
                // progress even for a completely unexpected type.
                _ = try? container.decode(AnyDecodableSkip.self)
            }
        }

        self.wrappedValue = elements
        self.droppedCount = dropped
    }
}

extension LossyArray: Encodable where Element: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for element in wrappedValue {
            try container.encode(element)
        }
    }
}

/// A `Decodable` that matches (and discards) any JSON value — object,
/// array, string, number, bool, or null — purely to advance an
/// `UnkeyedDecodingContainer`'s cursor past an element we're skipping.
private struct AnyDecodableSkip: Decodable {
    init(from decoder: Decoder) throws {
        // Try each container kind; at least one must succeed for
        // syntactically valid JSON, so this never itself throws in
        // practice for well-formed (if semantically wrong) payloads.
        if var container = try? decoder.unkeyedContainer() {
            while !container.isAtEnd {
                _ = try? container.decode(AnyDecodableSkip.self)
            }
        } else if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            for key in container.allKeys {
                _ = try? container.decode(AnyDecodableSkip.self, forKey: key)
            }
        } else {
            _ = try? decoder.singleValueContainer()
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}
