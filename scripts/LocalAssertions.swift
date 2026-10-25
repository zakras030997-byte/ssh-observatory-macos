// Fallback assertion runner for Command Line Tools without XCTest. It executes
// the same CoreTests methods; it is not shipped in the application.
import Foundation
class XCTestCase {}
var assertionFailures = 0
func recordFailure(_ text: String, file: StaticString, line: UInt) {
    assertionFailures += 1; print("FAIL \(file):\(line) \(text)")
}
func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) {
    do { if try !expression() { recordFailure("expected true", file: file, line: line) } }
    catch { recordFailure("unexpected error", file: file, line: line) }
}
func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) {
    do { if try expression() { recordFailure("expected false", file: file, line: line) } }
    catch { recordFailure("unexpected error", file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { if try left() != right() { recordFailure("values differ", file: file, line: line) } }
    catch { recordFailure("unexpected error", file: file, line: line) }
}
func XCTAssertNotEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { if try left() == right() { recordFailure("values unexpectedly equal", file: file, line: line) } }
    catch { recordFailure("unexpected error", file: file, line: line) }
}
func XCTAssertNil<T>(_ expression: @autoclosure () throws -> T?, file: StaticString = #file, line: UInt = #line) {
    do { if try expression() != nil { recordFailure("expected nil", file: file, line: line) } }
    catch { recordFailure("unexpected error", file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression(); recordFailure("expected error", file: file, line: line) } catch {}
}
