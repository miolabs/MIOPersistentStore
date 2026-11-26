//
//  MPSPredicateFilters.swift
//
//  Created by MIO Research Labs on 2026.
//

import Foundation
import MIOCore
import MIOCoreData

/// Turns an `NSPredicate` into the list of filters a server receives in the
/// `where` of a fetch.
///
/// A predicate cannot travel to a server as it is, so it is flattened into
/// plain dictionaries that can be sent as JSON. There are three kinds:
///
/// - an item, one comparison: `["type": "item", "key": "name", "comparator": "=", "value": "Cola"]`
/// - an operator between two entries of a group: `["type": "operator", "value": "and"]`
/// - a group, a compound predicate: `["type": "group", "values": [...]]`
///
/// ```swift
/// let filters = try MPSPredicateFilters.filters(from: fetchRequest.predicate)
/// ```
public enum MPSPredicateFilters
{
    // MARK: - Predicate types

    #if APPLE_CORE_DATA
    /// The predicate type of the Core Data in use: Foundation's `NSPredicate`
    /// with Apple's Core Data, `MIOPredicate` with MIOCoreData's own.
    public typealias Predicate = NSPredicate
    private typealias Comparison = NSComparisonPredicate
    private typealias Compound = NSCompoundPredicate
    private typealias Expression = NSExpression
    #else
    /// The predicate type of the Core Data in use: Foundation's `NSPredicate`
    /// with Apple's Core Data, `MIOPredicate` with MIOCoreData's own.
    public typealias Predicate = MIOPredicate
    private typealias Comparison = MIOComparisonPredicate
    private typealias Compound = MIOCompoundPredicate
    private typealias Expression = MIOExpression
    #endif

    // MARK: - Rules

    /// The rules that not every caller wants, as asked for in `filters`.
    private struct Rules
    {
        let identifierKeyPathAsRelationship: Bool
        let uuidConstantAsString: Bool
        let diacriticInsensitiveContains: Bool
    }

    // MARK: - Translation

    /// The filters of a predicate, or none for `nil`.
    ///
    /// The three rules are the ones not every caller wants. With all of them
    /// off, a predicate is translated as written.
    ///
    /// - Parameters:
    ///   - predicate: The predicate to translate.
    ///   - identifierKeyPathAsRelationship: Sends `category.identifier` as
    ///     `category`, for servers that filter a relationship by its own name.
    ///   - uuidConstantAsString: Sends a `UUID` constant as its string, for
    ///     filters that are encoded as JSON, which has no UUID type.
    ///   - diacriticInsensitiveContains: Sends an accent-insensitive
    ///     `CONTAINS[d]` as `CONTAINS[d]` instead of a plain `CONTAINS`, for
    ///     servers that tell them apart.
    /// - Throws: `MIOPersistentStoreError.invalidRequest` when a value of an
    ///   `IN` list written as text is not a string, an integer or a UUID.
    public static func filters(from predicate: Predicate?, identifierKeyPathAsRelationship: Bool = false, uuidConstantAsString: Bool = false, diacriticInsensitiveContains: Bool = false) throws -> [[String: Any?]]
    {
        let rules = Rules(identifierKeyPathAsRelationship: identifierKeyPathAsRelationship, uuidConstantAsString: uuidConstantAsString, diacriticInsensitiveContains: diacriticInsensitiveContains)

        var filters: [[String: Any?]] = []
        try _append_filters(of: predicate, to: &filters, rules)
        return filters
    }

    /// Adds the filters of one predicate, calling itself for the parts of a
    /// compound predicate.
    private static func _append_filters(of predicate: Predicate?, to filters: inout [[String: Any?]], _ rules: Rules) throws
    {
        if let comparison = predicate as? Comparison {
            try filters.append(_item(of: comparison, rules))
        }
        else if let compound = predicate as? Compound {
            let subpredicates = (compound.subpredicates as [Any]).compactMap { $0 as? Predicate }

            if subpredicates.count == 1 {
                try _append_filters(of: subpredicates[0], to: &filters, rules)
                return
            }

            var values: [[String: Any?]] = []

            for (index, subpredicate) in subpredicates.enumerated() {
                if index > 0 {
                    values.append(["type": "operator", "value": _logical_operator(compound.compoundPredicateType)])
                }

                try _append_filters(of: subpredicate, to: &values, rules)
            }

            filters.append(["type": "group", "values": values])
        }
    }

    /// The item of one comparison.
    ///
    /// A comparison with no value becomes `is null` or `is not null`. An `IN`
    /// whose list arrives as text, such as `"(1, 2, 3)"`, is split into its values.
    private static func _item(of comparison: Comparison, _ rules: Rules) throws -> [String: Any?]
    {
        var (key, value) = _key_and_value(left: comparison.leftExpression, right: comparison.rightExpression, rules)
        let comparator = _comparator(comparison.predicateOperatorType, comparison.options, rules)

        if comparison.predicateOperatorType == .in, let list = value as? String {
            value = try String(list.dropFirst().dropLast())
                .components(separatedBy: ",")
                .map { try _inferred_value(String($0.trimmingCharacters(in: .whitespaces))) }
        }

        var item: [String: Any?] = [:]
        item["type"] = "item"
        item["key"] = key
        item["comparator"] = value == nil ? (comparator == "=" ? "is null" : "is not null") : comparator
        item["value"] = value
        return item
    }

    // MARK: - Keys and values

    /// The key and the value of a comparison, whichever side each one is on.
    private static func _key_and_value(left: Expression, right: Expression, _ rules: Rules) -> (String, Any?)
    {
        var key = ""
        var value: Any?

        for expression in [left, right] {
            if let expression_key = _key(of: expression, rules) {
                key = expression_key
            }
            else if expression.expressionType == .constantValue {
                value = _constant(expression.constantValue, rules)
            }
        }

        return (key, value)
    }

    /// The key path of an expression, or `nil` when it is not a key.
    ///
    /// A `#Predicate` that reads through an optional wraps the key path in a
    /// conditional expression, so the key is looked for there as well.
    private static func _key(of expression: Expression, _ rules: Rules) -> String?
    {
        var key_path: String?

        if expression.expressionType == .keyPath {
            key_path = expression.keyPath
        }
        #if APPLE_CORE_DATA
        if expression.expressionType == .conditional && expression.true.expressionType == .keyPath {
            key_path = expression.true.keyPath
        }
        #endif

        guard let key_path else { return nil }

        let identifier_suffix = ".identifier"
        if rules.identifierKeyPathAsRelationship && key_path.hasSuffix(identifier_suffix) {
            return String(key_path.dropLast(identifier_suffix.count))
        }

        return key_path
    }

    /// The constant of an expression, as the rules ask to send it.
    private static func _constant(_ value: Any?, _ rules: Rules) -> Any?
    {
        if rules.uuidConstantAsString, let uuid = value as? UUID { return uuid.uuidString }
        return value
    }

    /// The typed value of one entry of an `IN` list written as text: a quoted
    /// string, a UUID or an integer.
    private static func _inferred_value(_ text: String) throws -> Any
    {
        if text.starts(with: "\"") { return text.replacingOccurrences(of: "\"", with: "") }
        if text.starts(with: "'") { return text.replacingOccurrences(of: "'", with: "") }
        if let uuid = UUID(uuidString: text) { return uuid }
        if let number = MIOCoreInt32Value(text) { return number }

        throw MIOPersistentStoreError.invalidRequest("\(text) not supported. Not string, not int32, not uuid")
    }

    // MARK: - Operators

    /// The comparator of a filter item for a comparison operator.
    private static func _comparator(_ type: Comparison.Operator, _ comparison_options: Comparison.Options, _ rules: Rules) -> String
    {
        switch type {
        case .equalTo:              return "="
        case .notEqualTo:           return "!="
        case .greaterThan:          return ">"
        case .greaterThanOrEqualTo: return ">="
        case .lessThan:             return "<"
        case .lessThanOrEqualTo:    return "<="
        case .in:                   return "IN"
        case .contains:
            let is_diacritic_insensitive = rules.diacriticInsensitiveContains && comparison_options.contains(.diacriticInsensitive)
            return is_diacritic_insensitive ? "CONTAINS[d]" : "CONTAINS"
        default:                    return " [MISSING OP] "
        }
    }

    /// The value of an operator entry for a compound predicate.
    private static func _logical_operator(_ type: Compound.LogicalType) -> String
    {
        switch type {
        case .and: return "and"
        case .or:  return "or"
        default:   return ""
        }
    }
}
