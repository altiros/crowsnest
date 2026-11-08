import Foundation

public enum KubeError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfig(String)
    case invalidInput(String)
    case api(status: Int, reason: String?, message: String)
    case transport(String)
    case execPlugin(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfig(let m): "Invalid kubeconfig: \(m)"
        case .invalidInput(let m): m
        case .api(let status, let reason, let message):
            "\(message) (HTTP \(status)\(reason.map { ", \($0)" } ?? ""))"
        case .transport(let m): "Connection error: \(m)"
        case .execPlugin(let m): "Auth plugin failed: \(m)"
        case .unsupported(let m): "Not supported: \(m)"
        }
    }

    public var httpStatus: Int? {
        if case .api(let status, _, _) = self { return status }
        return nil
    }
}
