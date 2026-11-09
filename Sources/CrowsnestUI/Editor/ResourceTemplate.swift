import CrowsnestKit
import Foundation

/// Starting points for "new resource", like Lens' create-resource templates.
public struct ResourceTemplate: Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var symbol: String
    public var yaml: String

    func render(namespace: String) -> String {
        yaml.replacingOccurrences(of: "{{namespace}}", with: namespace)
    }

    public static let all: [ResourceTemplate] = [
        ResourceTemplate(name: "Deployment", symbol: "square.stack.3d.forward.dottedline", yaml: """
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: my-app
          namespace: {{namespace}}
          labels:
            app: my-app
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: my-app
          template:
            metadata:
              labels:
                app: my-app
            spec:
              containers:
                - name: my-app
                  image: nginx:1.27
                  ports:
                    - containerPort: 80
                  resources:
                    requests:
                      cpu: 50m
                      memory: 64Mi
                    limits:
                      memory: 128Mi

        """),
        ResourceTemplate(name: "Service", symbol: "point.3.connected.trianglepath.dotted", yaml: """
        apiVersion: v1
        kind: Service
        metadata:
          name: my-app
          namespace: {{namespace}}
        spec:
          type: ClusterIP
          selector:
            app: my-app
          ports:
            - name: http
              port: 80
              targetPort: 80

        """),
        ResourceTemplate(name: "Ingress", symbol: "globe", yaml: """
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: my-app
          namespace: {{namespace}}
        spec:
          rules:
            - host: my-app.example.com
              http:
                paths:
                  - path: /
                    pathType: Prefix
                    backend:
                      service:
                        name: my-app
                        port:
                          number: 80

        """),
        ResourceTemplate(name: "ConfigMap", symbol: "doc.text", yaml: """
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: my-config
          namespace: {{namespace}}
        data:
          key: value

        """),
        ResourceTemplate(name: "Secret", symbol: "key", yaml: """
        apiVersion: v1
        kind: Secret
        metadata:
          name: my-secret
          namespace: {{namespace}}
        type: Opaque
        stringData:
          password: change-me

        """),
        ResourceTemplate(name: "Job", symbol: "hammer", yaml: """
        apiVersion: batch/v1
        kind: Job
        metadata:
          name: my-job
          namespace: {{namespace}}
        spec:
          backoffLimit: 2
          template:
            spec:
              restartPolicy: Never
              containers:
                - name: job
                  image: busybox:1.37
                  command: ["sh", "-c", "echo hello"]

        """),
        ResourceTemplate(name: "CronJob", symbol: "clock.arrow.circlepath", yaml: """
        apiVersion: batch/v1
        kind: CronJob
        metadata:
          name: my-cronjob
          namespace: {{namespace}}
        spec:
          schedule: "0 3 * * *"
          jobTemplate:
            spec:
              template:
                spec:
                  restartPolicy: OnFailure
                  containers:
                    - name: job
                      image: busybox:1.37
                      command: ["sh", "-c", "date"]

        """),
        ResourceTemplate(name: "PersistentVolumeClaim", symbol: "externaldrive", yaml: """
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: my-data
          namespace: {{namespace}}
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 1Gi

        """),
        ResourceTemplate(name: "Namespace", symbol: "square.stack.3d.up", yaml: """
        apiVersion: v1
        kind: Namespace
        metadata:
          name: my-namespace

        """),
    ]

    public static let empty = ResourceTemplate(name: "Empty", symbol: "doc", yaml: """
    # One or more manifests, separated by ---
    # Apply = server-side apply (creates or updates)
    apiVersion: v1
    kind:
    metadata:
      name:
      namespace: {{namespace}}

    """)

    /// Kinds that the cluster manages itself – no "New …" shortcut for them.
    static let systemManagedKinds: Set<String> = [
        "Node", "Event", "ReplicaSet", "Endpoints", "EndpointSlice", "Lease", "ControllerRevision", "PodMetrics", "NodeMetrics",
    ]

    /// Starting point for a new object of `kind`: the curated template if there is one, otherwise a minimal skeleton.
    /// `nil` for kinds that are managed by the cluster.
    public static func forKind(_ kind: ResourceKind) -> ResourceTemplate? {
        guard !systemManagedKinds.contains(kind.kind) else { return nil }
        let apiVersion = kind.group.isEmpty ? kind.version : "\(kind.group)/\(kind.version)"
        if let curated = all.first(where: {
            $0.name == kind.kind && $0.yaml.contains("apiVersion: \(apiVersion)\n") && $0.yaml.contains("kind: \(kind.kind)\n")
        }) {
            return curated
        }
        var yaml = """
        apiVersion: \(apiVersion)
        kind: \(kind.kind)
        metadata:
          name: my-\(kind.kind.lowercased())

        """
        if kind.namespaced { yaml += "  namespace: {{namespace}}\n" }
        return ResourceTemplate(name: kind.kind, symbol: kind.symbol, yaml: yaml)
    }
}
