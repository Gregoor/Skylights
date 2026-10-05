import Foundation

/// Stores the Jetstream API key in the Data Protection Keychain.
struct JetstreamCredentialStore {
    private let keychain = KeychainCredentialStore()
    private let account = "jetstream.api-key"

    func read() -> String? {
        keychain.read(account: account)
    }

    func write(_ value: String) throws {
        try keychain.write(value, account: account)
    }

    func delete() throws {
        try keychain.delete(account: account)
    }
}
