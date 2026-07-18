import Foundation

public enum AppServerEndpoint: Hashable, Sendable {
    case unixWebSocket(socketURL: URL, requestPath: String)
}

public struct AppServerEndpointDiscovery: Sendable {
    public static let maximumDocumentedCandidates = 4

    private let explicitSocketURL: URL?
    private let documentedSocketCandidates: [URL]

    public init(
        explicitSocketURL: URL?,
        documentedSocketCandidates: [URL] = []
    ) {
        self.explicitSocketURL = explicitSocketURL
        self.documentedSocketCandidates = documentedSocketCandidates
    }

    public func discover() -> AppServerEndpoint? {
        if let explicitSocketURL, isUnixSocket(explicitSocketURL) {
            return endpoint(for: explicitSocketURL)
        }

        for candidate in documentedSocketCandidates.prefix(Self.maximumDocumentedCandidates) {
            if isUnixSocket(candidate) {
                return endpoint(for: candidate)
            }
        }
        return nil
    }

    private func endpoint(for socketURL: URL) -> AppServerEndpoint {
        .unixWebSocket(
            socketURL: socketURL.standardizedFileURL,
            requestPath: "/"
        )
    }

    private func isUnixSocket(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.standardizedFileURL.path
        ) else {
            return false
        }
        guard let fileType = attributes[.type] as? FileAttributeType else {
            return false
        }
        return fileType == .typeSocket
    }
}
