import Foundation
import Domain
import Persistence
import Crypto

// ═══════════════════════════════════════════════════════════════════════════════
// F10 — ChainVerifier. Verifica la cadena de custodia completa:
// integridad de archivos, encadenamiento de hashes, firma criptográfica.
// Detecta: byte alterado, sello intermedio borrado, orden alterado, archivo
// añadido no declarado en manifiesto.
// ═══════════════════════════════════════════════════════════════════════════════

public struct ChainVerifier: ChainVerifying {

    private let hasher: Hasher
    private let encoder: CanonicalJSONEncoder

    public init() {
        self.hasher = Hasher()
        self.encoder = CanonicalJSONEncoder()
    }

    public func verify(bundleAt url: URL) async throws(CustodyError) -> CustodyVerdict {

        let fm = FileManager.default
        var errors: [CustodyError] = []

        // 1. Leer chain.jsonl
        let chainPath = url.appendingPathComponent("seals/chain.jsonl")
        guard fm.fileExists(atPath: chainPath.path) else {
            return .invalid([.bundleNotFound])
        }

        guard let content = try? String(contentsOf: chainPath, encoding: .utf8) else {
            return .invalid([.verificationFailed("chain.jsonl ilegible")])
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        guard !lines.isEmpty else {
            return .invalid([.chainBroken(index: 0, reason: "chain.jsonl vacía")])
        }

        // 2. Parsear sellos
        let decoder = JSONDecoder()
        var seals: [SealRecord] = []
        for (i, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let seal = try? decoder.decode(SealRecord.self, from: data) else {
                errors.append(.invalidSeal("Sello \(i) no es JSON válido"))
                continue
            }
            seals.append(seal)
        }

        guard seals.allSatisfy({ $0.index < seals.count }) else {
            return .invalid([.chainBroken(index: -1, reason: "índices de sello inconsistentes")])
        }

        // 3. Verificar encadenamiento
        for i in 0..<seals.count {
            let seal = seals[i]

            // prevSealHash
            if i == 0 {
                if seal.prevSealHash != nil {
                    errors.append(.chainBroken(index: i, reason: "primer sello no debe tener prevSealHash"))
                }
            } else {
                let prev = seals[i - 1]
                do {
                    let prevData = try encoder.encode(prev)
                    let expected = SHA256.hash(data: prevData).compactMap { String(format: "%02x", $0) }.joined()
                    if seal.prevSealHash != expected {
                        errors.append(.chainBroken(index: i, reason: "prevSealHash no coincide: esperado \(expected.prefix(16))…"))
                    }
                } catch {
                    errors.append(.chainBroken(index: i, reason: "error al hashear sello anterior"))
                }
            }
        }

        // 4. Verificar integridad de archivos contra el último manifiesto
        if let lastSeal = seals.last {
            let currentManifest = (try? hasher.buildManifest(directoryAt: url)) ?? []

            // 4a. Verificar que cada archivo del manifiesto existe y tiene el mismo hash
            for entry in lastSeal.manifest {
                let filePath = url.appendingPathComponent(entry.relativePath).path
                if !fm.fileExists(atPath: filePath) {
                    errors.append(.hashMismatch("Falta: \(entry.relativePath)"))
                } else {
                    let currentHash = try? hasher.hash(fileAt: URL(fileURLWithPath: filePath))
                    if currentHash != entry.sha256 {
                        errors.append(.hashMismatch("Hash alterado: \(entry.relativePath)"))
                    }
                }
            }

            // 4b. Detectar archivos añadidos no declarados
            let declaredPaths = Set(lastSeal.manifest.map(\.relativePath))
            for cm in currentManifest {
                if !declaredPaths.contains(cm.relativePath) {
                    errors.append(.extraFileNotDeclared(cm.relativePath))
                }
            }

            // 4c. Verificar root hash
            let currentRoot = (try? hasher.rootHash(manifest: currentManifest, encoder: encoder)) ?? ""
            if !errors.isEmpty {
                // Si ya hay errores de archivos, el root hash va a diferir — no duplicar
            } else if currentRoot != lastSeal.rootHash {
                errors.append(.manifestTampered)
            }
        }

        // 5. Verificar firma criptográfica de cada sello
        for seal in seals {
            let payloadString = "\(seal.rootHash)|\(seal.wallClock.timeIntervalSince1970)|\(seal.author.name)"
            guard let payload = payloadString.data(using: .utf8) else {
                errors.append(.invalidSeal("Payload no codificable en sello \(seal.index)"))
                continue
            }

            do {
                let pubKey = try P256.Signing.PublicKey(derRepresentation: seal.publicKeyDER)
                let sig = try P256.Signing.ECDSASignature(derRepresentation: seal.signatureDER)
                if !pubKey.isValidSignature(sig, for: payload) {
                    errors.append(.invalidSeal("Firma inválida en sello \(seal.index)"))
                }
            } catch {
                errors.append(.invalidSeal("Error criptográfico en sello \(seal.index): \(error.localizedDescription)"))
            }
        }

        if errors.isEmpty {
            return .valid
        } else {
            return .invalid(errors)
        }
    }
}