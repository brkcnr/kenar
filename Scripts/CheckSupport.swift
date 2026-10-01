// Tiny standalone assertion adapter for Macs with Command Line Tools only.
// The same scenario source uses XCTest when full Xcode is available.
import Foundation
enum CheckSupport {
    static var failures = 0
    static func fail(_ message: String) { failures += 1; print("FAIL: \(message)") }
}
class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
func XCTAssertTrue(_ value: Bool,_ message: String = "",file: StaticString = #filePath,line: UInt = #line) { if !value { CheckSupport.fail("\(file):\(line) expected true \(message)") } }
func XCTAssertFalse(_ value: Bool,file: StaticString = #filePath,line: UInt = #line) { if value { CheckSupport.fail("\(file):\(line) expected false") } }
func XCTAssertEqual<T: Equatable>(_ lhs: T,_ rhs: T,file: StaticString = #filePath,line: UInt = #line) { if lhs != rhs { CheckSupport.fail("\(file):\(line) \(lhs) != \(rhs)") } }
func XCTAssertEqual(_ lhs: Double,_ rhs: Double,accuracy: Double,file: StaticString = #filePath,line: UInt = #line) { if abs(lhs-rhs) > accuracy { CheckSupport.fail("\(file):\(line) \(lhs) differs from \(rhs)") } }
func XCTAssertNotEqual<T: Equatable>(_ lhs: T,_ rhs: T,file: StaticString = #filePath,line: UInt = #line) { if lhs == rhs { CheckSupport.fail("\(file):\(line) expected different values") } }
func XCTAssertNil<T>(_ value: T?,file: StaticString = #filePath,line: UInt = #line) { if value != nil { CheckSupport.fail("\(file):\(line) expected nil") } }
func XCTAssertNotNil<T>(_ value: T?,file: StaticString = #filePath,line: UInt = #line) { if value == nil { CheckSupport.fail("\(file):\(line) expected non-nil") } }
func XCTAssertGreaterThan<T: Comparable>(_ lhs: T,_ rhs: T,file: StaticString = #filePath,line: UInt = #line) { if lhs <= rhs { CheckSupport.fail("\(file):\(line) expected greater value") } }
enum CheckFailure: Error { case unwrap }
func XCTUnwrap<T>(_ value: T?) throws -> T { guard let value else { throw CheckFailure.unwrap }; return value }
