import XCTest
@testable import MattermostKit

final class JSONValueTests: XCTestCase {
    func testDecodesAllKinds() throws {
        let json = #"{"n":null,"b":true,"i":42,"big":1700000000000,"d":1.5,"s":"x","a":[1,"two"],"o":{"k":false}}"#
        let value = try JSONValue.parse(Data(json.utf8))
        XCTAssertEqual(value["n"], .null)
        XCTAssertEqual(value["b"], .bool(true))
        XCTAssertEqual(value["i"], .int(42))
        XCTAssertEqual(value["big"]?.int64Value, 1_700_000_000_000)
        XCTAssertEqual(value["d"], .double(1.5))
        XCTAssertEqual(value["s"], .string("x"))
        XCTAssertEqual(value["a"]?[1], .string("two"))
        XCTAssertNil(value["a"]?[5])
        XCTAssertEqual(value["o"]?["k"]?.boolValue, false)
        XCTAssertTrue(value["n"]?.isNull == true)
    }

    func testLenientAccessors() {
        XCTAssertEqual(JSONValue.string("12").int64Value, 12)
        XCTAssertEqual(JSONValue.string("12.0").int64Value, 12)
        XCTAssertEqual(JSONValue.double(3.0).intValue, 3)
        XCTAssertEqual(JSONValue.string("true").boolValue, true)
        XCTAssertEqual(JSONValue.int(0).boolValue, false)
        XCTAssertNil(JSONValue.int(2).boolValue)
        XCTAssertEqual(JSONValue.int(7).scalarString, "7")
        XCTAssertEqual(JSONValue.double(2.5).scalarString, "2.5")
        XCTAssertNil(JSONValue.array([]).scalarString)
        XCTAssertNil(JSONValue.string("x").int64Value)
    }

    func testEncodingRoundTrip() throws {
        let value: JSONValue = ["a": [1, 2.5, "s", true, nil], "b": ["c": "d"]]
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONValue.parse(data), value)
    }

    func testDecodeEmbeddedString() throws {
        let embedded = JSONValue.string(#"{"id":"p1","message":"hi"}"#)
        XCTAssertEqual(try embedded.decodeEmbedded(Post.self).message, "hi")
        let structured: JSONValue = ["id": "p2"]
        XCTAssertEqual(try structured.decodeEmbedded(Post.self).id, "p2")
        XCTAssertThrowsError(try JSONValue.string("not json").decodeEmbedded(Post.self))
    }
}
