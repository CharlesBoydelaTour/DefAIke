import Foundation
import Testing

@testable import DefAIkeModelBundle

/// The strict structural scan the manifest parser runs before decoding.
///
/// The scan exists for one reason a decoder cannot cover: `JSONDecoder` accepts an
/// object that repeats a key and silently keeps one value. The first test pins that
/// decoder behavior so the scan's purpose stays visible, and the rest check the scan
/// refuses everything a signed manifest must not be.
@Suite("Manifest structural scan")
struct CanonicalJSONScanTests {
    private func finding(_ json: String) -> JSONScanFault? {
        do {
            try CanonicalJSONScan.validate(Array(json.utf8))
            return nil
        } catch {
            return error
        }
    }

    @Test("A JSON decoder silently accepts a repeated key, which is why the scan exists")
    func decoderAcceptsDuplicateKeys() throws {
        struct Pair: Decodable {
            let key: String
        }
        let json = #"{"key":"first","key":"second"}"#
        // The decoder does not fail. It keeps one of the two values, and which one is
        // not something a signed manifest should depend on.
        let decoded = try JSONDecoder().decode(Pair.self, from: Data(json.utf8))
        #expect(["first", "second"].contains(decoded.key))

        #expect(finding(json) == .duplicateKey("key"))
    }

    @Test("A repeated key in a nested object is refused")
    func nestedDuplicateKey() {
        let json = #"{"outer":{"inner":1,"other":2,"inner":3}}"#
        #expect(finding(json) == .duplicateKey("inner"))
    }

    @Test("A repeated key inside an array element is refused")
    func duplicateKeyInArrayElement() {
        let json = #"{"items":[{"a":1},{"b":1,"b":2}]}"#
        #expect(finding(json) == .duplicateKey("b"))
    }

    @Test("An escaped spelling of an existing key is still a duplicate")
    func escapedDuplicateKey() {
        // "\u0061" is "a": comparing raw bytes would treat these as two keys.
        #expect(finding(#"{"a":1,"\u0061":2}"#) == .duplicateKey("a"))
    }

    @Test("The same key in sibling objects is not a duplicate")
    func siblingObjectsMayShareKeys() {
        #expect(finding(#"{"left":{"id":1},"right":{"id":2}}"#) == nil)
    }

    @Test("Structurally valid documents pass")
    func validDocumentsPass() {
        let documents = [
            "{}",
            "[]",
            #"{"a":null,"b":true,"c":false}"#,
            #"{"n":[0,-1,1.5,1e3,-2.25E-4]}"#,
            #"{"text":"line\nbreak \u00e9 \ud83d\ude00 \\ \" \/"}"#,
            #"  {  "spaced" :  [ 1 , 2 ]  }  "#,
        ]
        for document in documents {
            #expect(finding(document) == nil, "expected \(document) to pass")
        }
    }

    @Test("Malformed documents are refused")
    func malformedDocumentsAreRefused() {
        let documents = [
            "",
            "{",
            "}",
            #"{"a":}"#,
            #"{"a" 1}"#,
            #"{"a":1,}"#,
            #"{,"a":1}"#,
            #"{"a":01}"#,
            #"{"a":1.}"#,
            #"{"a":+1}"#,
            #"{"a":.5}"#,
            #"{"a":1e}"#,
            #"{"a":tru}"#,
            #"{"a":"unterminated}"#,
            #"{"a":"bad \x escape"}"#,
            #"{"a":"lone \ud83d surrogate"}"#,
            #"{"a":1} trailing"#,
            "[1,2",
        ]
        for document in documents {
            let observed = finding(document)
            guard case .malformed = observed else {
                Issue.record("expected \(document) to be malformed, found \(String(describing: observed))")
                continue
            }
        }
    }

    @Test("A raw control character inside a string is refused")
    func rawControlCharacterRefused() {
        var bytes = Array(#"{"a":"x"}"#.utf8)
        bytes[7] = 0x0A
        do {
            try CanonicalJSONScan.validate(bytes)
            Issue.record("expected a raw newline inside a string to be refused")
        } catch {
            guard case .malformed = error else {
                Issue.record("expected malformed, found \(error)")
                return
            }
        }
    }

    @Test("Bytes that are not valid UTF-8 are refused")
    func invalidUTF8Refused() {
        var bytes = Array(#"{"a":"x"}"#.utf8)
        bytes[6] = 0xFF
        do {
            try CanonicalJSONScan.validate(bytes)
            Issue.record("expected invalid UTF-8 to be refused")
        } catch {
            #expect(error == .notUTF8)
        }
    }

    @Test("Nesting at the ceiling passes and one level deeper is refused")
    func depthCeiling() {
        let depth = CanonicalJSONScan.maximumDepth
        let atCeiling = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        #expect(finding(atCeiling) == nil)

        let overCeiling =
            String(repeating: "[", count: depth + 1) + String(repeating: "]", count: depth + 1)
        #expect(finding(overCeiling) == .tooDeep(maximumDepth: depth))
    }
}
