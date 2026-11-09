import CrowsnestKit
import Testing
@testable import CrowsnestUI

@Suite struct ResourceTemplateTests {
    @Test func curatedTemplateForBuiltinKind() throws {
        let template = try #require(ResourceTemplate.forKind(.secrets))
        #expect(template.name == "Secret")
        #expect(template.yaml.contains("kind: Secret\n"))
    }

    @Test func skeletonForKindWithoutTemplate() throws {
        let template = try #require(ResourceTemplate.forKind(.roles))
        let yaml = template.render(namespace: "team-a")
        #expect(yaml.contains("apiVersion: rbac.authorization.k8s.io/v1\n"))
        #expect(yaml.contains("kind: Role\n"))
        #expect(yaml.contains("  namespace: team-a\n"))
    }

    @Test func clusterScopedSkeletonHasNoNamespace() throws {
        let template = try #require(ResourceTemplate.forKind(.customResourceDefinitions))
        #expect(!template.yaml.contains("namespace:"))
    }

    @Test func customResourceWithBuiltinNameGetsSkeleton() throws {
        let kind = ResourceKind(kind: "Secret", group: "example.com", version: "v1alpha1", plural: "secrets", category: .customResources)
        let template = try #require(ResourceTemplate.forKind(kind))
        #expect(template.yaml.hasPrefix("apiVersion: example.com/v1alpha1\n"))
    }

    @Test func noShortcutForSystemManagedKinds() {
        #expect(ResourceTemplate.forKind(.nodes) == nil)
        #expect(ResourceTemplate.forKind(.events) == nil)
    }
}
