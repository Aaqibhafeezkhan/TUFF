import Testing
import TUFFAppCore
@testable import TUFFMac

@Suite @MainActor struct ModelCatalogGroupTests {
    @Test func everyCatalogueModelLandsInExactlyOneGroup() {
        for descriptor in AppModelInstallDescriptor.catalog {
            let groups = ModelCatalogGroup.allCases.filter { $0.contains(descriptor) }
            #expect(groups.count == 1,
                    "\(descriptor.displayName) belongs to \(groups.count) groups")
        }
    }

    /// Maintained models follow their weight layout; Legacy is separate.
    @Test func groupingFollowsTheExpertCache() {
        for descriptor in AppModelInstallDescriptor.catalog {
            let streamed = ModelCatalogGroup.streaming.contains(descriptor)
            #expect(streamed == (descriptor.usesExpertCache && !descriptor.isLegacy))
            #expect(ModelCatalogGroup.legacy.contains(descriptor) == descriptor.isLegacy)
        }
    }

    /// Empty sections should not replace the current catalog groups.
    @Test func theShippedCatalogueUsesBothGroups() {
        for group in ModelCatalogGroup.allCases {
            #expect(AppModelInstallDescriptor.catalog.contains { group.contains($0) },
                    "\(group.title) is empty in the shipped catalogue")
        }
    }
}
