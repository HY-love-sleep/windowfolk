import Foundation
import Testing
@testable import WindowfolkArtIO
import WindowfolkArtKit

@Suite struct ImageServiceURLTests {
    @Test func serviceURLHandlesVersionSuffixAndRejectsUnsafeValues() {
        #expect(URLSessionTransport.baseURL(from: [:])?.absoluteString == "https://api.openai.com")
        for input in ["https://example.test/v1", "https://example.test/v1/"] {
            let base = URLSessionTransport.baseURL(from: ["WINDOWFOLK_IMAGE_BASE_URL": input])
            #expect(base?.absoluteString == "https://example.test/")
        }
        for input in ["http://example.test", "https://user:pass@example.test", "https://example.test/?token=secret"] {
            #expect(URLSessionTransport.baseURL(from: ["WINDOWFOLK_IMAGE_BASE_URL": input]) == nil)
        }
    }
}
