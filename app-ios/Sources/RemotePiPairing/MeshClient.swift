import Foundation
import RemotePiCrypto
import RemotePiProtocol

// MARK: - Results

public enum MeshFetchResult: Sendable {
    case ok(MeshEnvelope, version: Int, updatedAt: Int64)
    /// `304` — `since` compared with `<=`, so `since == current` lands here.
    /// The body is **empty**; do not try to decode it. Means "your cache is
    /// current", not "no membership": leave the local cache alone.
    case notModified
    /// `404` — the relay has never held a row for this Owner. Also not a
    /// reason to touch the local cache; treat the current version as 0.
    case notFound
    case failure(String)
}

public enum MeshPublishResult: Sendable, Equatable {
    case ok(version: Int, updatedAt: Int64)
    /// `409 stale_version (current=N)`. `current` is parsed out of that text so
    /// the retry can jump straight to `N + 1` instead of paying a `GET`.
    case conflict(current: Int?)
    /// `400` — malformed request. Our bug; the body is a plain-text reason.
    case badRequest(String)
    /// `403` — `sig_invalid`, `owner_pk_hash mismatch`, or an `owner_pk` that
    /// is not a valid key.
    case forbidden(String)
    /// `413` — body over 500 KB.
    case tooLarge
    case failure(String)
    /// Refused locally: an empty member set on top of a non-zero version,
    /// without the caller opting in. See ``MeshPublisher``.
    case refusedEmpty
    /// Folded into a publish that was already in flight; the coalesced
    /// mutation is included in that one's member set.
    case coalesced
}

// MARK: - HTTP seam

/// The one HTTP call the mesh endpoints need, as a seam so tests never open a
/// socket.
public protocol MeshHTTPClient: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionMeshHTTPClient: MeshHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

// MARK: - Client

/// `GET`/`POST /mesh/<owner_pk_hash>` — the Owner's membership row.
///
/// The endpoint is public and unauthenticated by design: the blob carries its
/// own signature, and the URL slot is derived from the Owner key. Which means
/// the slot proves nothing on its own — see ``MeshPublisher/pull()``.
public struct MeshClient: Sendable {
    private let baseURL: URL
    private let http: any MeshHTTPClient

    public init(baseURL: URL, http: any MeshHTTPClient = URLSessionMeshHTTPClient()) {
        self.baseURL = baseURL
        self.http = http
    }

    /// The mesh URL for an Owner key.
    ///
    /// Trap T4: the path segment is `sha256(raw 32 key bytes)`, lowercase hex —
    /// **not** a hash of the Base64 text. Hashing the text produces a
    /// perfectly valid-looking 64-hex string that yields `403 owner_pk_hash
    /// mismatch` on POST and `404` on GET forever.
    public static func meshURL(base: URL, owner: PeerID) -> URL? {
        meshURL(base: base, hash: meshPathHash(for: owner))
    }

    public static func meshURL(base: URL, hash: String) -> URL? {
        // The pi-extension strips *all* trailing slashes (`client.ts:86`); the
        // Flutter client strips one. Stripping all is the superset and cannot
        // produce a `//mesh/` path.
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: "\(text)/mesh/\(hash)")
    }

    public func fetch(owner: PeerID, since: Int? = nil) async -> MeshFetchResult {
        guard let url = Self.meshURL(base: baseURL, owner: owner) else {
            return .failure("could not build mesh URL from \(baseURL)")
        }
        var target = url
        if let since, since > 0 {
            guard
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return .failure("could not build mesh URL from \(baseURL)") }
            // A non-numeric `since` is rejected by the relay's extractor before
            // the handler runs, so it is always a bare integer.
            components.queryItems = [URLQueryItem(name: "since", value: String(since))]
            guard let withQuery = components.url else {
                return .failure("could not build mesh URL from \(baseURL)")
            }
            target = withQuery
        }

        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await http.perform(request)
            switch response.statusCode {
            case 200:
                guard
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let blob = object["blob"] as? String,
                    let sig = object["sig"] as? String,
                    let version = (object["version"] as? NSNumber)?.intValue,
                    let updatedAt = (object["updated_at"] as? NSNumber)?.int64Value
                else { return .failure("200 OK body was not a mesh envelope") }
                // `version`/`updated_at` sit OUTSIDE the envelope — decoding
                // them into it would change the bytes we later verify.
                return .ok(
                    MeshEnvelope(blob: blob, sig: sig),
                    version: version,
                    updatedAt: updatedAt
                )
            case 304:
                return .notModified
            case 404:
                return .notFound
            default:
                return .failure("unexpected status \(response.statusCode)")
            }
        } catch {
            return .failure(String(describing: error))
        }
    }

    public func publish(owner: PeerID, envelope: MeshEnvelope) async -> MeshPublishResult {
        guard let url = Self.meshURL(base: baseURL, owner: owner) else {
            return .failure("could not build mesh URL from \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try JSONEncoder().encode(envelope)
        } catch {
            return .failure(String(describing: error))
        }

        do {
            let (data, response) = try await http.perform(request)
            // Trap T13: 4xx bodies are `text/plain`, not JSON. Running them
            // through a decoder loses the one useful thing they carry.
            let text = String(data: data, encoding: .utf8) ?? ""
            switch response.statusCode {
            case 200:
                guard
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let version = (object["version"] as? NSNumber)?.intValue,
                    let updatedAt = (object["updated_at"] as? NSNumber)?.int64Value
                else { return .failure("200 OK missing version / updated_at integers") }
                return .ok(version: version, updatedAt: updatedAt)
            case 400:
                return .badRequest(text)
            case 403:
                return .forbidden(text)
            case 409:
                return .conflict(current: Self.parseConflictVersion(text))
            case 413:
                return .tooLarge
            default:
                return .failure("unexpected status \(response.statusCode)")
            }
        } catch {
            return .failure(String(describing: error))
        }
    }

    /// Pulls `N` out of `stale_version (current=N)` (`handler.rs:37-40`).
    /// Returns `nil` for any other body — a relay that changes the wording
    /// costs one extra `GET`, not a broken client.
    public static func parseConflictVersion(_ body: String) -> Int? {
        guard let range = body.range(of: "current=") else { return nil }
        let digits = body[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}
