import Foundation
import CryptoKit
import LocalAuthentication
import Security
import Domain
import Custody

// ═══════════════════════════════════════════════════════════════════════════════
// Clave con la que el iPhone firma los sellos (plan §2.C.6, Fase 10 parte B).
//
// - Con chip seguro y código configurado: clave P-256 no exportable dentro del
//   Secure Enclave. Cada sello exige Face ID o el código del iPhone.
// - Sin eso (simulador, iPhone sin código): clave de software guardada en el
//   llavero, la misma en cada arranque. El sello lo declara (`keyProtection`).
//
// Si la clave cambia (teléfono nuevo, se quitó el código), el siguiente sello
// declara la anterior en `previousKeyID` (lo hace SealSigner) y los sellos
// viejos siguen verificando con la clave pública que lleva cada uno.
// ═══════════════════════════════════════════════════════════════════════════════

nonisolated enum SealingKeyStore {

    private static let service = "cl.arqueolidar.sealing-key"

    /// Pide Face ID o el código ANTES de que se escriba nada: si se cancela, el
    /// escaneo no queda guardado a medias ni sellado.
    static func key(reason: String) async throws -> any SigningKey {
        guard SecureEnclave.isAvailable,
              LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return try softwareKey()
        }
        let access = try accessControl()
        let context = LAContext()
        do {
            _ = try await context.evaluateAccessControl(access, operation: .useKeySign, localizedReason: reason)
        } catch {
            throw FieldError("No se selló: no se confirmó Face ID ni el código del iPhone. El escaneo sigue abierto; vuelve a tocar Guardar para sellarlo.")
        }

        if let blob = read(account: "secure-enclave"),
           let stored = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context),
           (try? stored.signature(for: Data())) != nil {
            return SecureEnclaveSigningKey(stored)
        }
        // Primera vez, o la clave guardada ya no sirve: clave nueva. El próximo
        // sello de cada expediente declara la rotación.
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
            try save(key.dataRepresentation, account: "secure-enclave")
            return SecureEnclaveSigningKey(key)
        } catch let error as FieldError {
            throw error
        } catch {
            throw FieldError("No se pudo crear la clave del chip seguro: \(error.localizedDescription)")
        }
    }

    private static func softwareKey() throws -> SoftwareSigningKey {
        if let raw = read(account: "software"), let key = try? SoftwareSigningKey(rawRepresentation: raw) {
            return key
        }
        let key = SoftwareSigningKey()
        try save(key.rawRepresentation, account: "software")
        return key
    }

    /// Se borra si se quita el código del iPhone; `.userPresence` acepta Face ID o código.
    private static func accessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .userPresence], &error
        ) else {
            throw FieldError("No se pudo preparar la clave del chip seguro: \(error.map { "\($0.takeRetainedValue())" } ?? "?")")
        }
        return access
    }

    // MARK: - Llavero

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// El blob del chip seguro va cifrado por el propio chip: solo sirve en este iPhone.
    private static func save(_ data: Data, account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw FieldError("No se pudo guardar la clave de sellado en el llavero (código \(status)).")
        }
    }
}

/// Clave del Secure Enclave ya autenticada (el LAContext evaluado va dentro), así
/// que `sign` no vuelve a pedir Face ID.
nonisolated struct SecureEnclaveSigningKey: SigningKey, @unchecked Sendable {
    let publicKeyDER: Data
    let keyID: String
    var protection: KeyProtection { .secureEnclave }
    private let key: SecureEnclave.P256.Signing.PrivateKey

    init(_ key: SecureEnclave.P256.Signing.PrivateKey) {
        let der = key.publicKey.derRepresentation
        self.key = key
        publicKeyDER = der
        keyID = SealPayload.keyID(publicKeyDER: der)
    }

    func sign(data: Data) throws(CustodyError) -> Data {
        do { return try key.signature(for: data).derRepresentation }
        catch { throw .signingFailed(error.localizedDescription) }
    }
}
