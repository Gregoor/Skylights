import CryptoKit
import Foundation

/// Small native AT Protocol OAuth client for public repo access. The client metadata
/// document is static; all authorization, DPoP signing and token refresh stays on device.
final class PopfeedOAuthClient: @unchecked Sendable {
    static let clientID = "https://cdn.jsdelivr.net/gh/Gregoor/Skylights@main/iOS/popfeed-oauth-client-v2.json"
    static let redirectURI = "net.jsdelivr.cdn:/oauth/callback"
    static let scope = "atproto repo:social.popfeed.feed.review repo:social.popfeed.feed.list repo:social.popfeed.feed.listItem"

    private struct Pending: Codable {
        var did: String
        var pds: String
        var authorizationServer: String
        var tokenEndpoint: String
        var authorizationEndpoint: String
        var state: String
        var verifier: String
        var privateKey: String
        var authorizationNonce: String?
    }

    private struct Session: Codable {
        var did: String
        var pds: String
        var authorizationServer: String
        var tokenEndpoint: String
        var privateKey: String
        var accessToken: String
        var refreshToken: String
        var authorizationNonce: String?
        var resourceNonce: String?
    }

    private let keychain = KeychainCredentialStore()
    private let lock = NSLock()
    private var session: Session?

    init() {
        if let json = keychain.read(account: "popfeed.oauth.session"),
           let data = json.data(using: .utf8) {
            session = try? JSONDecoder().decode(Session.self, from: data)
        }
    }

    var connectedDID: String? { lock.lock(); defer { lock.unlock() }; return session?.did }

    func personalDataServer() async throws -> URL {
        if let value = try? getSession(), let url = URL(string: value.pds) { return url }
        guard let did = connectedDID else { throw OAuthError.noSession }
        return try await resolvePDS(did: did)
    }

    func begin(did: String) async throws -> URL {
        let pds = try await resolvePDS(did: did)
        let resourceURL = pds.appendingPathComponent(".well-known/oauth-protected-resource")
        let resource = try await getJSON(resourceURL)
        guard let servers = resource["authorization_servers"] as? [String],
              let authorizationServer = servers.first,
              let asURL = URL(string: authorizationServer) else { throw OAuthError.invalidMetadata("PDS did not publish an authorization server") }
        let metadataURL = asURL.appendingPathComponent(".well-known/oauth-authorization-server")
        let metadata = try await getJSON(metadataURL)
        guard metadata["issuer"] as? String == authorizationServer else {
            throw OAuthError.invalidMetadata("Authorization server issuer does not match the discovered server")
        }
        guard let par = metadata["pushed_authorization_request_endpoint"] as? String,
              let tokenEndpoint = metadata["token_endpoint"] as? String,
              let authorizationEndpoint = metadata["authorization_endpoint"] as? String,
              let parURL = URL(string: par), URL(string: tokenEndpoint) != nil,
              let authURL = URL(string: authorizationEndpoint) else { throw OAuthError.invalidMetadata("Authorization server metadata is missing required endpoints") }

        let privateKey = P256.Signing.PrivateKey()
        let verifier = Self.randomURLSafe(count: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = UUID().uuidString.lowercased()
        let form = [
            "client_id": Self.clientID,
            "response_type": "code",
            "redirect_uri": Self.redirectURI,
            "scope": Self.scope,
            "state": state,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "login_hint": did,
            "resource": pds.absoluteString
        ]
        let parResponse = try await postForm(parURL, form: form, privateKey: privateKey, nonce: nil, authorizationServer: true)
        guard let requestURI = parResponse.json["request_uri"] as? String else { throw OAuthError.invalidMetadata("PAR response did not include request_uri") }
        let pending = Pending(did: did, pds: pds.absoluteString, authorizationServer: authorizationServer,
                             tokenEndpoint: tokenEndpoint, authorizationEndpoint: authorizationEndpoint,
                             state: state, verifier: verifier, privateKey: privateKey.rawRepresentation.base64EncodedString(),
                             authorizationNonce: parResponse.nonce)
        try saveJSON(pending, account: "popfeed.oauth.pending")
        var components = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "client_id", value: Self.clientID), URLQueryItem(name: "request_uri", value: requestURI)]
        guard let url = components.url else { throw OAuthError.invalidMetadata("Could not build authorization URL") }
        return url
    }

    func complete(callback url: URL) async throws -> String {
        guard let pendingData = keychain.read(account: "popfeed.oauth.pending")?.data(using: .utf8),
              let pending = try? JSONDecoder().decode(Pending.self, from: pendingData) else { throw OAuthError.missingRequest }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(parts.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        guard values["state"] == pending.state else { throw OAuthError.stateMismatch }
        guard values["iss"] == pending.authorizationServer else { throw OAuthError.invalidMetadata("OAuth callback issuer did not match the discovered authorization server") }
        if let error = values["error"] { throw OAuthError.authorizationDenied(values["error_description"] ?? error) }
        guard let code = values["code"] else { throw OAuthError.missingCode }
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: pending.privateKey)!)
        let tokenURL = URL(string: pending.tokenEndpoint)!
        let response = try await postForm(tokenURL, form: [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": pending.verifier
        ], privateKey: privateKey, nonce: pending.authorizationNonce, authorizationServer: true)
        guard let access = response.json["access_token"] as? String,
              let refresh = response.json["refresh_token"] as? String,
              let grantedScope = response.json["scope"] as? String, grantedScope.split(separator: " ").contains("atproto"),
              (response.json["sub"] as? String) == pending.did else {
            throw OAuthError.invalidToken("Token response did not match the requested account")
        }
        let session = Session(did: pending.did, pds: pending.pds, authorizationServer: pending.authorizationServer,
                             tokenEndpoint: pending.tokenEndpoint, privateKey: pending.privateKey,
                             accessToken: access, refreshToken: refresh, authorizationNonce: response.nonce,
                             resourceNonce: nil)
        save(session)
        try keychain.delete(account: "popfeed.oauth.pending")
        return pending.did
    }

    func disconnect() {
        lock.lock(); session = nil; lock.unlock()
        try? keychain.delete(account: "popfeed.oauth.session")
        try? keychain.delete(account: "popfeed.oauth.pending")
    }

    func request(_ request: URLRequest) async throws -> Data {
        var current = try getSession()
        var response = try await resourceRequest(request, session: current)
        if response.http.statusCode == 401 {
            current = try await refresh(current)
            response = try await resourceRequest(request, session: current)
        }
        guard (200..<300).contains(response.http.statusCode) else { throw OAuthError.http(response.http.statusCode, String(data: response.data.prefix(700), encoding: .utf8) ?? "") }
        return response.data
    }

    private func resolvePDS(did: String) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "https://plc.directory/\(did)")!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let services = json["service"] as? [[String: Any]],
              let value = services.first(where: { $0["type"] as? String == "AtprotoPersonalDataServer" })?["serviceEndpoint"] as? String,
              let pds = URL(string: value), pds.scheme == "https" else { throw OAuthError.invalidMetadata("Could not resolve the account PDS") }
        return pds
    }

    private func resourceRequest(_ original: URLRequest, session source: Session) async throws -> (data: Data, http: HTTPURLResponse) {
        var current = source
        for attempt in 0..<2 {
            var request = original
            let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: current.privateKey)!)
            let proof = try Self.dpop(method: request.httpMethod ?? "GET", url: request.url!, key: privateKey, nonce: current.resourceNonce, accessToken: current.accessToken)
            request.setValue("DPoP \(current.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(proof, forHTTPHeaderField: "DPoP")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OAuthError.invalidMetadata("Missing PDS response") }
            guard let nonce = http.value(forHTTPHeaderField: "DPoP-Nonce") else {
                let host = http.url?.host ?? "unknown PDS"
                let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate") ?? "none"
                let detail = String(data: data.prefix(400), encoding: .utf8) ?? "(non-text response)"
                throw OAuthError.invalidMetadata("PDS response did not include the required DPoP nonce (HTTP \(http.statusCode), host=\(host), WWW-Authenticate=\(challenge), body=\(detail))")
            }
            current.resourceNonce = nonce
            save(current)
            if http.statusCode == 401, attempt == 0, Self.needsNonce(data) { continue }
            return (data, http)
        }
        throw OAuthError.invalidMetadata("PDS rejected DPoP proof")
    }

    private func refresh(_ source: Session) async throws -> Session {
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: source.privateKey)!)
        var current = source
        for attempt in 0..<2 {
            let response = try await postForm(URL(string: source.tokenEndpoint)!, form: [
                "grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": current.refreshToken
            ], privateKey: key, nonce: current.authorizationNonce, authorizationServer: true)
            if let access = response.json["access_token"] as? String, let refresh = response.json["refresh_token"] as? String {
                current.accessToken = access
                current.refreshToken = refresh
                current.authorizationNonce = response.nonce
                save(current)
                return current
            }
            if attempt == 1 { break }
        }
        throw OAuthError.invalidToken("Could not refresh the OAuth session")
    }

    private func postForm(_ url: URL, form: [String: String], privateKey: P256.Signing.PrivateKey, nonce: String?, authorizationServer: Bool) async throws -> (json: [String: Any], nonce: String?) {
        var body = URLComponents(); body.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for attempt in 0..<2 {
            let proof = try Self.dpop(method: "POST", url: url, key: privateKey, nonce: nonce, accessToken: nil)
            request.setValue(proof, forHTTPHeaderField: "DPoP")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OAuthError.invalidMetadata("Missing authorization server response") }
            let responseNonce = http.value(forHTTPHeaderField: "DPoP-Nonce")
            guard responseNonce != nil else { throw OAuthError.invalidMetadata("Authorization server response did not include the required DPoP nonce") }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 400, attempt == 0, Self.needsNonce(data), let responseNonce {
                    // The request must be retried with the server's fresh nonce.
                    return try await postForm(url, form: form, privateKey: privateKey, nonce: responseNonce, authorizationServer: authorizationServer)
                }
                throw OAuthError.http(http.statusCode, String(data: data.prefix(700), encoding: .utf8) ?? "")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OAuthError.invalidMetadata("Authorization server returned invalid JSON") }
            return (json, responseNonce)
        }
        throw OAuthError.invalidMetadata("Authorization server rejected DPoP proof")
    }

    private static func dpop(method: String, url: URL, key: P256.Signing.PrivateKey, nonce: String?, accessToken: String?) throws -> String {
        let publicBytes = Array(key.publicKey.x963Representation.dropFirst())
        let header: [String: Any] = ["typ": "dpop+jwt", "alg": "ES256", "jwk": ["kty": "EC", "crv": "P-256", "x": base64URL(Data(publicBytes.prefix(32))), "y": base64URL(Data(publicBytes.suffix(32)))]]
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.query = nil; components.fragment = nil
        var payload: [String: Any] = ["jti": UUID().uuidString.lowercased(), "htm": method.uppercased(), "htu": components.url!.absoluteString, "iat": Int(Date().timeIntervalSince1970)]
        if let nonce { payload["nonce"] = nonce }
        if let accessToken { payload["ath"] = base64URL(Data(SHA256.hash(data: Data(accessToken.utf8)))) }
        let encodedHeader = base64URL(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let encodedPayload = base64URL(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let signingInput = "\(encodedHeader).\(encodedPayload)"
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
        return "\(signingInput).\(base64URL(signature))"
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OAuthError.invalidMetadata("Could not load \(url.host ?? "OAuth") metadata") }
        return json
    }

    private func getSession() throws -> Session {
        lock.lock(); defer { lock.unlock() }
        guard let session else { throw OAuthError.noSession }
        return session
    }
    private func save(_ value: Session) {
        lock.lock(); session = value; lock.unlock()
        try? saveJSON(value, account: "popfeed.oauth.session")
    }
    private func saveJSON<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else { throw OAuthError.invalidMetadata("Could not encode OAuth session") }
        try keychain.write(json, account: account)
    }
    private static func needsNonce(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (json["error"] as? String) == "use_dpop_nonce"
    }
    private static func randomURLSafe(count: Int) -> String {
        base64URL(Data((0..<count).map { _ in UInt8.random(in: 0...255) }))
    }
    private static func base64URL<D: DataProtocol>(_ data: D) -> String {
        Data(data).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    enum OAuthError: LocalizedError {
        case invalidMetadata(String), missingRequest, stateMismatch, authorizationDenied(String), missingCode, invalidToken(String), http(Int, String), noSession
        var errorDescription: String? {
            switch self {
            case .invalidMetadata(let value): return value
            case .missingRequest: return "There is no pending Popfeed authorization request."
            case .stateMismatch: return "OAuth callback state did not match the pending request."
            case .authorizationDenied(let reason): return "Authorization was declined: \(reason)"
            case .missingCode: return "OAuth callback did not contain an authorization code."
            case .invalidToken(let reason): return reason
            case .http(let code, let detail): return "OAuth server returned HTTP \(code): \(detail)"
            case .noSession: return "Connect your Popfeed account first."
            }
        }
    }
}
