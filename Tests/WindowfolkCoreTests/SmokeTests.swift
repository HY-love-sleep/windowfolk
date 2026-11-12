import PropertyBased
import Testing
@testable import WindowfolkCore

@Test func coreModuleLoads() {
    #expect(!WindowfolkCore.version.isEmpty)
}
