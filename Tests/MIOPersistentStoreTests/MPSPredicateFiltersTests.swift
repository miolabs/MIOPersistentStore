//
//  MPSPredicateFiltersTests.swift
//
//  Created by MIO Research Labs on 2026.
//

import XCTest
import MIOCoreData
@testable import MIOPersistentStore

final class MPSPredicateFiltersTests: XCTestCase
{
    private func _filters(_ format: String, _ arguments: [Any] = [], identifierKeyPathAsRelationship: Bool = false, uuidConstantAsString: Bool = false, diacriticInsensitiveContains: Bool = false) throws -> [[String: Any?]]
    {
        try MPSPredicateFilters.filters(from: MIOPredicateWithFormat(format: format, arguments: arguments), identifierKeyPathAsRelationship: identifierKeyPathAsRelationship, uuidConstantAsString: uuidConstantAsString, diacriticInsensitiveContains: diacriticInsensitiveContains)
    }

    private func _string(_ item: [String: Any?], _ key: String) -> String?
    {
        (item[key] ?? nil) as? String
    }

    // MARK: - Items

    func testNoPredicateGivesNoFilters() throws
    {
        XCTAssertTrue(try MPSPredicateFilters.filters(from: nil).isEmpty)
    }

    func testAComparisonBecomesOneItem() throws
    {
        let filters = try _filters("name == %@", ["Cola"])

        XCTAssertEqual(filters.count, 1)
        XCTAssertEqual(_string(filters[0], "type"), "item")
        XCTAssertEqual(_string(filters[0], "key"), "name")
        XCTAssertEqual(_string(filters[0], "comparator"), "=")
        XCTAssertEqual(_string(filters[0], "value"), "Cola")
    }

    func testEachOperatorHasItsComparator() throws
    {
        XCTAssertEqual(_string(try _filters("price != %@", [1])[0], "comparator"), "!=")
        XCTAssertEqual(_string(try _filters("price > %@", [1])[0], "comparator"), ">")
        XCTAssertEqual(_string(try _filters("price >= %@", [1])[0], "comparator"), ">=")
        XCTAssertEqual(_string(try _filters("price < %@", [1])[0], "comparator"), "<")
        XCTAssertEqual(_string(try _filters("price <= %@", [1])[0], "comparator"), "<=")
        XCTAssertEqual(_string(try _filters("name CONTAINS %@", ["co"])[0], "comparator"), "CONTAINS")
    }

    func testAComparisonWithNilBecomesAnIsNullItem() throws
    {
        let equal = try _filters("deletedAt == nil")
        let not_equal = try _filters("deletedAt != nil")

        XCTAssertEqual(_string(equal[0], "key"), "deletedAt")
        XCTAssertEqual(_string(equal[0], "comparator"), "is null")
        XCTAssertEqual(_string(not_equal[0], "comparator"), "is not null")
    }

    // MARK: - Groups

    func testACompoundPredicateBecomesAGroupWithOperators() throws
    {
        let filters = try _filters("name == %@ AND price > %@", ["Cola", 1])

        XCTAssertEqual(filters.count, 1)
        XCTAssertEqual(_string(filters[0], "type"), "group")

        let values = try XCTUnwrap((filters[0]["values"] ?? nil) as? [[String: Any?]])
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(_string(values[0], "key"), "name")
        XCTAssertEqual(_string(values[1], "type"), "operator")
        XCTAssertEqual(_string(values[1], "value"), "and")
        XCTAssertEqual(_string(values[2], "key"), "price")
    }

    func testAnOrGroupUsesTheOrOperator() throws
    {
        let filters = try _filters("name == %@ OR name == %@", ["Cola", "Agua"])
        let values = try XCTUnwrap((filters[0]["values"] ?? nil) as? [[String: Any?]])

        XCTAssertEqual(_string(values[1], "value"), "or")
    }

    // MARK: - Options

    func testAnIdentifierKeyPathIsKeptByDefault() throws
    {
        XCTAssertEqual(_string(try _filters("category.identifier == %@", ["x"])[0], "key"), "category.identifier")
    }

    func testAnIdentifierKeyPathBecomesTheRelationshipWhenAsked() throws
    {
        let filters = try _filters("category.identifier == %@", ["x"], identifierKeyPathAsRelationship: true)

        XCTAssertEqual(_string(filters[0], "key"), "category")
    }

    func testAUUIDConstantIsKeptByDefault() throws
    {
        let uuid = UUID()
        let filters = try _filters("identifier == %@", [uuid])

        XCTAssertEqual((filters[0]["value"] ?? nil) as? UUID, uuid)
    }

    func testAUUIDConstantBecomesItsStringWhenAsked() throws
    {
        let uuid = UUID()
        let filters = try _filters("identifier == %@", [uuid], uuidConstantAsString: true)

        XCTAssertEqual(_string(filters[0], "value"), uuid.uuidString)
    }

    func testAccentInsensitiveContainsIsPlainByDefault() throws
    {
        XCTAssertEqual(_string(try _filters("name CONTAINS[d] %@", ["co"])[0], "comparator"), "CONTAINS")
    }

    func testAccentInsensitiveContainsIsKeptWhenAsked() throws
    {
        let filters = try _filters("name CONTAINS[d] %@", ["co"], diacriticInsensitiveContains: true)

        XCTAssertEqual(_string(filters[0], "comparator"), "CONTAINS[d]")
    }
}
