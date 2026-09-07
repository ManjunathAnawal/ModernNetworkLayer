//
//  CodableResilienceTests.swift
//  NetworkLayerTests
//
import Testing
@testable import NetworkLayer
import Foundation

@Suite("Robust Codable")
struct CodableResilienceTests {

    private struct Item: Decodable, Equatable {
        let id: Int
        let name: String
    }

    private struct Wrapper: Decodable {
        @LossyArray var items: [Item]
    }

    @Test("LossyArray decodes valid elements and drops malformed ones instead of failing entirely")
    func lossyArrayDropsOnlyBadElements() throws {
        let json = """
        {
            "items": [
                {"id": 1, "name": "Alice"},
                {"id": "not-a-number", "name": "Malformed"},
                {"id": 2, "name": "Bob"},
                {"missing": "everything"},
                {"id": 3, "name": "Carol"}
            ]
        }
        """.data(using: .utf8)!

        let wrapper = try JSONDecoder().decode(Wrapper.self, from: json)
        #expect(wrapper.items.count == 3)
        #expect(wrapper.items.map(\.name) == ["Alice", "Bob", "Carol"])
        #expect(wrapper.$items.droppedCount == 2)
    }

    @Test("LossyArray on an all-valid array behaves identically to normal array decoding")
    func lossyArrayAllValidMatchesNormalDecoding() throws {
        let json = """
        {"items": [{"id": 1, "name": "A"}, {"id": 2, "name": "B"}]}
        """.data(using: .utf8)!

        let wrapper = try JSONDecoder().decode(Wrapper.self, from: json)
        #expect(wrapper.items.count == 2)
        #expect(wrapper.$items.droppedCount == 0)
    }

    @Test("LossyArray handles an empty array")
    func lossyArrayHandlesEmptyArray() throws {
        let json = """{"items": []}""".data(using: .utf8)!
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: json)
        #expect(wrapper.items.isEmpty)
    }

    // MARK: - Unknown enum case fallback

    private enum Status: String, UnknownCaseRepresentable {
        case active, inactive
        case unknownStatus = "unknown"
        static var unknownCase: Status { .unknownStatus }
    }

    private struct Record: Decodable {
        let status: Status
    }

    @Test("A known enum raw value decodes to its case")
    func knownEnumCaseDecodesNormally() throws {
        let json = """{"status": "active"}""".data(using: .utf8)!
        let record = try JSONDecoder().decode(Record.self, from: json)
        #expect(record.status == .active)
    }

    @Test("An unrecognized enum raw value falls back to the unknown case instead of throwing")
    func unrecognizedEnumCaseFallsBackToUnknown() throws {
        let json = """{"status": "archived_v2_totally_new"}""".data(using: .utf8)!
        let record = try JSONDecoder().decode(Record.self, from: json)
        #expect(record.status == .unknownStatus)
    }

    // MARK: - Domain model end-to-end (User) demonstrating both patterns together

    @Test("UserListResponse with one malformed user still decodes the rest, with an unknown status preserved")
    func userListResponseIsResilientEndToEnd() throws {
        let json = """
        {
            "users": [
                {"id": "1", "display_name": "Ann", "email": "ann@x.com", "status": "active", "created_at": "2024-01-01T00:00:00Z"},
                {"id": "2", "display_name": "Bo", "email": "bo@x.com", "status": "newly_added_status", "created_at": "2024-01-02T00:00:00Z"},
                {"broken": true}
            ],
            "next_page_token": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder.robust.decode(UserListResponse.self, from: json)
        #expect(response.users.count == 2, "The malformed third record should be dropped, not fail the whole response")
        #expect(response.users[0].status == .active)
        #expect(response.users[1].status == .unknownStatus, "Unrecognized status should fall back gracefully")
    }
}
