import Foundation
import Domain
import Persistence
import Crypto

// ═══════════════════════════════════════════════════════════════════════════════
// F10 — SealSigner. Firma P-256 con clave de software (tests/CI) o
// Secure Enclave (dispositivo). Abstracción tras protocolo para testing.
// ═══════════════════════════════════════════════════════════════════════════════

public protocol SigningKey: Sendable {
    var publicKeyDER: Data { get }
    var keyID: String { get }
    func sign(data: Data) throws(CustodyError) -> Data
}

/// Clave de software P-256 para testing y CI. No usa Secure Enclave.
/// swift-crypto (v3.x en Linux) no marca P256.PrivateKey como Sendable,
/// así que envolvemos la clave en una clase @unchecked Sendable (la clave
/// es inmutable tras init y se usa solo sincrónicamente en sign()).
public struct SoftwareSigningKey: SigningKey, Sendable {
    public let publicKeyDER: Data
    public let keyID: String
    private let box: _KeyBox

    private final class _KeyBox: @unchecked Sendable {
        let key: P256.Signing.PrivateKey
        init(_ key: P256.Signing.PrivateKey) { self.key = key }
    }

    public init() {
        let key = P256.Signing.PrivateKey()
        self.box = _KeyBox(key)
        self.publicKeyDER = key.publicKey.derRepresentation
        self.keyID = SHA256.hash(data: key.publicKey.derRepresentation)
            .compactMap { String(format: "%02x", $0) }
            .prefix(16)
            .joined()
    }

    public func sign(data: Data) throws(CustodyError) -> Data {
        do {
            let signature = try box.key.signature(for: data)
            return signature.derRepresentation
        } catch {
            throw .signingFailed(error.localizedDescription)
        }
    }
}

public struct SealSigner: Sendable {
    private let hasher: Hasher
    private let encoder: CanonicalJSONEncoder

    public init() {
        self.hasher = Hasher()
        self.encoder = CanonicalJSONEncoder()
    }

    /// Genera un sello nuevo sobre el directorio de un scan/expediente.
    /// - Parameters:
    ///   - bundleURL: directorio raíz del bundle.
    ///   - author: identidad del operador.
    ///   - geo: fijación GPS asociada (opcional).
    ///   - previousSeal: sello anterior en la cadena (nil si es el primero).
    ///   - key: clave de firma (software o Secure Enclave).
    ///   - clock: reloj actual (inyectable para testing).
    public func seal(
        bundleAt bundleURL: URL,
        author: AuthorIdentity,
        geo: GeoFix?,
        previousSeal: SealRecord?,
        key: SigningKey,
        clock: Date = Date()
    ) async throws(CustodyError) -> SealRecord {

        // 1. Manifiesto
        let manifest = try hasher.buildManifest(directoryAt: bundleURL)

        // 2. Root hash
        let rootHash = try hasher.rootHash(manifest: manifest, encoder: encoder)

        // 3. Prev seal hash
        let prevHash: String?
        if let prev = previousSeal {
            do {
                let prevData = try encoder.encode(prev)
                prevHash = SHA256.hash(data: prevData).compactMap { String(format: "%02x", $0) }.joined()
            } catch {
                throw .chainBroken(index: prev.index, reason: "No se pudo hashear el sello anterior")
            }
        } else {
            prevHash = nil
        }

        // 4. Payload a firmar: rootHash + timestamp + author
        let payloadString = "\(rootHash)|\(clock.timeIntervalSince1970)|\(author.name)"
        let payload = payloadString.data(using: .utf8)!

        // 5. Firmar
        let signature = try key.sign(data: payload)

        // 6. Delta monótono desde sello anterior
        let delta: TimeInterval?
        if let prev = previousSeal {
            delta = clock.timeIntervalSince(prev.wallClock)
        } else {
            delta = nil
        }

        return SealRecord(
            index: (previousSeal?.index ?? -1) + 1,
            prevSealHash: prevHash,
            rootHash: rootHash,
            manifest: manifest,
            geo: geo,
            author: author,
            deviceKeyID: key.keyID,
            publicKeyDER: key.publicKeyDER,
            signatureDER: signature,
            wallClock: clock,
            monotonicDeltaSincePrevious: delta,
            gnssTime: nil,
            rfc3161Token: nil
        )
    }
}