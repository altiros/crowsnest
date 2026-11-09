import CrowsnestKit
import Foundation

// End-to-end check for exec and port-forward against a TEST cluster:
//   swift run crowsnest-streamcheck <context> <namespace>
// Needs a running pod with an HTTP server on port 80 and a service with port 8080 → 80 in <namespace>,
// e.g. kubectl create deployment web --image=nginx --port=80 && kubectl expose deployment web --port=8080 --target-port=80
// It runs commands inside a pod – use a throwaway test cluster.
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments.dropFirst()
guard args.count == 2, let contextName = args.first, let namespace = args.last else {
    print("Usage: crowsnest-streamcheck <context> <namespace>"); exit(2)
}

let config = try KubeConfig.load(from: KubeConfig.defaultFileURLs())
let client = try await KubeClientPool.shared.client(for: config.connection(forContext: contextName))
let pods = try await client.list(.pods, namespace: namespace).filter { $0["status.phase"]?.string == "Running" }
guard let pod = pods.first else { print("No running pod in \(namespace)"); exit(1) }
print("Pod: \(pod.name)")

func collect(_ session: ExecSession, input: [String] = []) async throws -> (String, Int?) {
    for line in input { session.write(line) }
    var output: [UInt8] = []
    var code: Int?
    for try await event in session.events {
        switch event {
        case .output(let bytes): output += bytes
        case .exited(let c, let message): code = c; if let message { print("  Message: \(message)") }
        }
    }
    return (String(decoding: output, as: UTF8.self), code)
}

var failures = 0
@MainActor func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : " – \(detail)")")
    if !ok { failures += 1 }
}

// 1. Non-interactive command with exit code.
let s1 = try await client.exec(pod: pod.name, namespace: namespace, container: nil,
                               command: ["sh", "-c", "echo hello-from-pod; exit 3"])
let (out1, code1) = try await collect(s1)
check("exec: output", out1.contains("hello-from-pod"), out1.trimmingCharacters(in: .whitespacesAndNewlines))
check("exec: exit code 3", code1 == 3, "\(code1.map(String.init) ?? "nil")")

// 2. Interactive shell with input and resize.
let s2 = try await client.exec(pod: pod.name, namespace: namespace, container: nil, columns: 100, rows: 30)
s2.resize(columns: 120, rows: 40)
let (out2, code2) = try await collect(s2, input: ["echo $((6*7)) $(stty size)\n", "exit\n"])
check("shell: input/output", out2.contains("42"))
check("shell: TTY size", out2.contains("40 120"))
check("shell: exit 0", code2 == 0, "\(code2.map(String.init) ?? "nil")")

// 3. Unknown container → API error.
do {
    _ = try await client.exec(pod: pod.name, namespace: namespace, container: "does-not-exist")
    check("exec: error for unknown container", false)
} catch {
    check("exec: error for unknown container", true, error.localizedDescription)
}

// 4. Port-forward to the pod and via the service.
let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
}()
func fetch(_ url: URL) async throws -> String {
    let (data, _) = try await session.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5))
    return String(decoding: data, as: UTF8.self)
}
let f1 = try await client.forward(pod: pod.name, namespace: namespace, remotePort: 80)
let page1 = try await fetch(f1.url!)
let page2 = try await fetch(f1.url!.appending(path: "missing"))
check("forward pod :80 → \(f1.localPort)", page1.contains("nginx"))
check("forward: second connection", page2.contains("404"))
let parallel = try await withThrowingTaskGroup(of: Bool.self) { group in
    for _ in 0..<8 { group.addTask { try await fetch(f1.url!).contains("nginx") } }
    var all = true
    for try await ok in group { all = all && ok }
    return all
}
check("forward: 8 parallel connections", parallel, "total \(f1.status.totalConnections)")
f1.stop()
try await Task.sleep(for: .milliseconds(300))
let stopped = (try? await fetch(f1.url!)) == nil
check("forward: stopped", stopped)

if let service = try await client.list(.services, namespace: namespace).first(where: { $0["spec.ports"]?.array?.first?["port"]?.int == 8080 }) {
    let target = try await client.forwardTarget(service: service, port: 8080)
    let f2 = try await client.forward(pod: target.pod, namespace: namespace, remotePort: target.port, localPort: 18080)
    let page = try await fetch(URL(string: "http://127.0.0.1:18080")!)
    check("forward service \(service.name):8080 → \(target.pod):\(target.port)", page.contains("nginx"))
    f2.stop()
}

// 5. Forward to a closed port → error reported, listener survives.
let f3 = try await client.forward(pod: pod.name, namespace: namespace, remotePort: 9999)
_ = try? await fetch(f3.url!)
try await Task.sleep(for: .milliseconds(300))
check("forward: error for closed port", f3.status.lastError != nil, f3.status.lastError ?? "")
f3.stop()

print(failures == 0 ? "All OK" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
