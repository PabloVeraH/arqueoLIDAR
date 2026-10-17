import Foundation
import Domain
import Persistence
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// ═══════════════════════════════════════════════════════════════════════════════
// F10 — SealSigner. Firma P-256 con clave de software (tests/CI) o
// Secure Enclave (dispositivo). Abstracción tras protocolo para testing.
// ═══════════════════════════════════════════════════════════════════════════════

public protocol SigningKey: Sendable {
    var publicKeyDER: Data { get }
    var keyID: String { get }
    var protection: KeyProtection { get }
    func sign(data: Data) throws(CustodyError) -> Data
}

/// Bytes que se firman en cada sello. Compartido por `SealSigner`,
/// `ChainVerifier` y replicado en `tools/verify_chain.py`.
public enum SealPayload {
    public static let currentVersion = 2

    /// keyID = primeros 16 hex del SHA-256 de la clave pública DER.
    public static func keyID(publicKeyDER: Data) -> String {
        SHA256.hash(data: publicKeyDER).compactMap { String(format: "%02x", $0) }.prefix(16).joined()
    }

    /// v1: `rootHash|ms|autor`. No cubre índice ni prevSealHash: quien borre un
    /// sello intermedio puede corregir el prevSealHash del siguiente sin romper
    /// ninguna firma. Solo se acepta para leer sellos antiguos.
    /// v2: `v2|índice|prevSealHash|rootHash|ms|keyID|protección|keyID anterior|autor`.
    /// Campos ausentes como "-". El autor va al final: es el único campo que
    /// puede contener "|", así el texto sigue siendo inequívoco.
    public static func bytes(for seal: SealRecord) -> Data {
        let ms = CanonicalDateCoding.millisecondsSince1970(seal.wallClock)
        guard seal.signatureVersion == 2 else {
            return Data("\(seal.rootHash)|\(ms)|\(seal.author.name)".utf8)
        }
        let fields = [
            "v2", "\(seal.index)", seal.prevSealHash ?? "-", seal.rootHash, "\(ms)",
            seal.deviceKeyID, seal.keyProtection?.rawValue ?? "-", seal.previousKeyID ?? "-",
            seal.author.name,
        ]
        return Data(fields.joined(separator: "|").utf8)
    }
}

/// Clave de software P-256 para testing y CI. No usa Secure Enclave.
/// swift-crypto (v3.x en Linux) no marca P256.PrivateKey como Sendable,
/// así que envolvemos la clave en una clase @unchecked Sendable (la clave
/// es inmutable tras init y se usa solo sincrónicamente en sign()).
public struct SoftwareSigningKey: SigningKey, Sendable {
    public let publicKeyDER: Data
    public let keyID: String
    private let box: _KeyBox

    public var protection: KeyProtection { .software }
    /// Para guardar la clave en el llavero y reusarla entre arranques.
    public var rawRepresentation: Data { box.key.rawRepresentation }

    private final class _KeyBox: @unchecked Sendable {
        let key: P256.Signing.PrivateKey
        init(_ key: P256.Signing.PrivateKey) { self.key = key }
    }

    public init() {
        self.init(key: P256.Signing.PrivateKey())
    }

    public init(rawRepresentation: Data) throws(CustodyError) {
        let key: P256.Signing.PrivateKey
        do { key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation) }
        catch { throw .signingFailed("Clave guardada ilegible: \(error.localizedDescription)") }
        self.init(key: key)
    }

    private init(key: P256.Signing.PrivateKey) {
        self.box = _KeyBox(key)
        self.publicKeyDER = key.publicKey.derRepresentation
        self.keyID = SealPayload.keyID(publicKeyDER: key.publicKey.derRepresentation)
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

        // `wallClock` se serializa como ISO 8601 con milisegundos (ver
        // `CanonicalDateCoding`), así que se normaliza el reloj a esa misma
        // precisión ANTES de firmar: firmar con precisión de `Double` completa
        // y luego serializar con menos precisión haría que la firma dejara de
        // verificar contra el sello ya escrito en disco. Firmar exactamente lo
        // que se va a persistir es lo que garantiza que ambos coincidan
        // siempre, sin depender de que el redondeo del formateador ISO 8601
        // coincida bit a bit con el de aquí.
        let clockMillis = CanonicalDateCoding.millisecondsSince1970(clock)
        let clock = Date(timeIntervalSince1970: Double(clockMillis) / 1000.0)

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

        // 4. Delta monótono desde sello anterior
        let delta: TimeInterval?
        if let prev = previousSeal {
            delta = clock.timeIntervalSince(prev.wallClock)
        } else {
            delta = nil
        }

        // 5. Rotación: si la clave cambió respecto del sello anterior, este sello
        // declara cuál era. Va dentro de lo firmado (v2).
        let previousKeyID = previousSeal.flatMap { $0.deviceKeyID == key.keyID ? nil : $0.deviceKeyID }

        var record = SealRecord(
            index: (previousSeal?.index ?? -1) + 1,
            prevSealHash: prevHash,
            rootHash: rootHash,
            manifest: manifest,
            geo: geo,
            author: author,
            deviceKeyID: key.keyID,
            publicKeyDER: key.publicKeyDER,
            signatureDER: Data(),
            wallClock: clock,
            monotonicDeltaSincePrevious: delta,
            gnssTime: nil,
            rfc3161Token: nil,
            signatureVersion: SealPayload.currentVersion,
            keyProtection: key.protection,
            previousKeyID: previousKeyID
        )

        // 6. Firmar (milisegundos enteros en el payload, ver `CanonicalDateCoding`).
        record.signatureDER = try key.sign(data: SealPayload.bytes(for: record))
        return record
    }
}