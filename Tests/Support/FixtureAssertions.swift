import Foundation

public enum FixtureAssertionError: Error { case incomplete, failed }
public enum FixtureAssertions {
    public static func decode(_ data: Data, required: [String]) throws -> [String: Bool] {
        let checks = try JSONDecoder().decode([String: Bool].self, from: data)
        guard !required.isEmpty, !checks.isEmpty, Set(required).isSubset(of: checks.keys) else { throw FixtureAssertionError.incomplete }
        guard checks.values.allSatisfy({ $0 }) else { throw FixtureAssertionError.failed }
        return checks
    }
}
