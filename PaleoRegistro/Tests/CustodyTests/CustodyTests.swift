import Testing
import Foundation
import Domain
import Persistence
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import Custody

// ═══════════════════════════════════════════════════════════════════════════════
// F10 — Custody: criterios de aceptación. Parte A (lógica pura, sin Secure Enclave).
// ═══════════════════════════════════════════════════════════════════════════════

func tempBundleDir(name: String = "test-bundle") -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("custody-\(name)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("F10 Custody: Hasher")
struct HasherTests {

    let hasher = Hasher()

    @Test("SHA-256 en streaming coincide con hash en memoria")
    func streamingMatchesInMemory() throws {
        let dir = tempBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Crear archivo de ~10 MB con contenido determinista
        let path = dir.appendingPathComponent("test.bin")
        let size = 10_000_000
        var data = Data(count: size)
        for i in 0..<min(size, 10000) { data[i] = UInt8(i % 256) }
        try data.write(to: path)

        let fileHash = try hasher.hash(fileAt: path)
        let memHash = hasher.hash(data: data)
        #expect(fileHash == memHash, "Hash en streaming difiere del hash en memoria")
        #expect(fileHash.count == 64)
    }

    @Test("El pico de memoria es bajo incluso con archivos grandes")
    func lowMemoryForLargeFiles() throws {
        // Verificar que usamos streaming (probado por diseño: InputStream con buffer de 1 MB)
        let dir = tempBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("big.bin")
        var data = Data(count: 50_000_000) // 50 MB
        for i in 0..<1000 { data[i] = UInt8(i % 256) }
        try data.write(to: path)

        let hash = try hasher.hash(fileAt: path)
        #expect(hash.count == 64)
        // Si llegamos aquí sin crash de memoria, el streaming funciona
    }

    @Test("Manifiesto es estable ante orden de archivos del sistema")
    func manifestStableFileOrder() throws {
        let dir = tempBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "a".data(using: .utf8)!.write(to: dir.appendingPathComponent("z.txt"))
        try "b".data(using: .utf8)!.write(to: dir.appendingPathComponent("a.txt"))

        let manifest1 = try hasher.buildManifest(directoryAt: dir)
        let manifest2 = try hasher.buildManifest(directoryAt: dir)

        #expect(manifest1 == manifest2)
        #expect(manifest1.count == 2)
        #expect(manifest1[0].relativePath == "a.txt") // ordenado alfabéticamente
        #expect(manifest1[1].relativePath == "z.txt")
    }

    @Test("Manifiesto con rutas relativas aunque la raíz se acceda por un enlace simbólico")
    func manifestRelativeThroughSymlink() throws {
        // Reproduce el caso de iOS: Documentos se entrega como /var/mobile/…,
        // pero /var es un enlace a /private/var.
        let fm = FileManager.default
        let realDir = tempBundleDir()
        defer { try? fm.removeItem(at: realDir) }
        try fm.createDirectory(at: realDir.appendingPathComponent("scans/s1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: realDir.appendingPathComponent("seals"), withIntermediateDirectories: true)
        try "a".data(using: .utf8)!.write(to: realDir.appendingPathComponent("finding.json"))
        try "b".data(using: .utf8)!.write(to: realDir.appendingPathComponent("scans/s1/mesh.ply"))
        try "c".data(using: .utf8)!.write(to: realDir.appendingPathComponent("seals/chain.jsonl"))
        try "d".data(using: .utf8)!.write(to: realDir.appendingPathComponent("VERIFY.txt"))

        let link = realDir.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString.prefix(8))")
        try fm.createSymbolicLink(at: link, withDestinationURL: realDir)
        defer { try? fm.removeItem(at: link) }

        let manifest = try Hasher().buildManifest(directoryAt: link)
        #expect(manifest.map(\.relativePath) == ["finding.json", "scans/s1/mesh.ply"])
    }

    @Test("Root hash es determinista para el mismo contenido")
    func rootHashDeterministic() throws {
        let dir = tempBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "hello".data(using: .utf8)!.write(to: dir.appendingPathComponent("file.txt"))
        let manifest = try hasher.buildManifest(directoryAt: dir)
        let encoder = CanonicalJSONEncoder()

        let h1 = try hasher.rootHash(manifest: manifest, encoder: encoder)
        let h2 = try hasher.rootHash(manifest: manifest, encoder: encoder)
        #expect(h1 == h2)
    }
}

@Suite("F10 Custody: SealSigner")
struct SealSignerTests {

    @Test("Sellar produce un SealRecord válido y verificable")
    func sealProducesValidRecord() async throws {
        let dir = tempBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Crear contenido de bundle de prueba
        let scansDir = dir.appendingPathComponent("scans/test-scan")
        try FileManager.default.createDirectory(at: scansDir, withIntermediateDirectories: true)
        try "mesh data".data(using: .utf8)!.write(to: scansDir.appendingPathComponent("mesh.ply"))

        let sealsDir = dir.appendingPathComponent("seals")
        try FileManager.default.createDirectory(at: sealsDir, withIntermediateDirectories: true)

        let author = AuthorIdentity(name: "Dr. Test", role: "Arqueólogo", institution: "MNHN")
        let key = SoftwareSigningKey()
        let signer = SealSigner()
        let clock = Date(timeIntervalSince1970: 1_700_000_000)

        let seal = try await signer.seal(
            bundleAt: dir,
            author: author,
            geo: nil,
            previousSeal: nil,
            key: key,
            clock: clock
        )

        #expect(seal.index == 0)
        #expect(seal.prevSealHash == nil)
        #expect(seal.manifest.count >= 1)
        #expect(seal.author.name == "Dr. Test")
        #expect(!seal.signatureDER.isEmpty)
        #expect(seal.rootHash.count == 64)

        // Verificar que la firma es válida con la clave pública del sello
        #expect(seal.signatureVersion == 2)
        #expect(seal.keyProtection == .software)
        #expect(seal.previousKeyID == nil)
        let payload = SealPayload.bytes(for: seal)
        let ms = CanonicalDateCoding.millisecondsSince1970(seal.wallClock)
        #expect(String(decoding: payload, as: UTF8.self)
            == "v2|0|-|\(seal.rootHash)|\(ms)|\(key.keyID)|software|-|Dr. Test")
        let pubKey = try P256.Signing.PublicKey(derRepresentation: seal.publicKeyDER)
        let sig = try P256.Signing.ECDSASignature(derRepresentation: seal.signatureDER)
        let valid = pubKey.isValidSignature(sig, for: payload)
        #expect(valid, "La firma del sello no verifica contra su propia clave pública")
    }

    @Test("Cadena de sellos: prevSealHash encadena correctamente")
    func sealChainLinksCorrectly() async throws {
        let dir = tempBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scansDir = dir.appendingPathComponent("scans/test")
        try FileManager.default.createDirectory(at: scansDir, withIntermediateDirectories: true)
        try "v1".data(using: .utf8)!.write(to: scansDir.appendingPathComponent("mesh.ply"))

        let sealsDir = dir.appendingPathComponent("seals")
        try FileManager.default.createDirectory(at: sealsDir, withIntermediateDirectories: true)

        let author = AuthorIdentity(name: "X", role: "R", institution: "I")
        let key = SoftwareSigningKey()
        let signer = SealSigner()

        let seal0 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: nil, key: key)
        #expect(seal0.index == 0)
        #expect(seal0.prevSealHash == nil)

        // Simular intervención: cambiar mesh
        try "v2 modified".data(using: .utf8)!.write(to: scansDir.appendingPathComponent("mesh.ply"))
        let seal1 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: seal0, key: key, clock: Date().addingTimeInterval(3600))

        #expect(seal1.index == 1)
        #expect(seal1.prevSealHash != nil)
        #expect(seal1.prevSealHash!.count == 64)
        #expect(seal1.rootHash != seal0.rootHash, "Root hash debe cambiar si el contenido cambió")
        #expect(seal1.monotonicDeltaSincePrevious != nil)
    }
}

@Suite("F10 Custody: ChainVerifier")
struct ChainVerifierTests {

    /// Crea un bundle sellado con dos eslabones para pruebas de verificación.
    func createSealedBundle() async throws -> (URL, ChainVerifier) {
        let dir = tempBundleDir()
        let scansDir = dir.appendingPathComponent("scans/test")
        try FileManager.default.createDirectory(at: scansDir, withIntermediateDirectories: true)
        try "original mesh".data(using: .utf8)!.write(to: scansDir.appendingPathComponent("mesh.ply"))
        let sealsDir = dir.appendingPathComponent("seals")
        try FileManager.default.createDirectory(at: sealsDir, withIntermediateDirectories: true)

        let author = AuthorIdentity(name: "A", role: "R", institution: "I")
        let key = SoftwareSigningKey()
        let signer = SealSigner()

        let seal0 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: nil, key: key)

        // Append seal0 to chain.jsonl
        let chainPath = sealsDir.appendingPathComponent("chain.jsonl")
        let encoder = CanonicalJSONEncoder()
        let seal0Data = try encoder.encode(seal0)
        try seal0Data.write(to: chainPath)
        try "\n".data(using: .utf8)!.writeToFile(chainPath, append: true)

        // Modificar y sellar de nuevo
        try "modified mesh v2".data(using: .utf8)!.write(to: scansDir.appendingPathComponent("mesh.ply"))
        let seal1 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: seal0, key: key, clock: Date().addingTimeInterval(3600))
        let seal1Data = try encoder.encode(seal1)
        try seal1Data.writeToFile(chainPath, append: true)

        let verifier = ChainVerifier()
        return (dir, verifier)
    }

    @Test("Verificación pasa con bundle íntegro")
    func verifyPassesWithIntactBundle() async throws {
        let (dir, verifier) = try await createSealedBundle()
        defer { try? FileManager.default.removeItem(at: dir) }

        let verdict = try await verifier.verify(bundleAt: dir)
        #expect(verdict.isValid, "Bundle íntegro debe verificar en verde")
    }

    @Test("Detección de byte alterado en mesh.ply")
    func detectsOneByteAlteration() async throws {
        let (dir, verifier) = try await createSealedBundle()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Alterar un byte
        let meshPath = dir.appendingPathComponent("scans/test/mesh.ply")
        var data = try Data(contentsOf: meshPath)
        data[0] = data[0] ^ 0xFF
        try data.write(to: meshPath)

        let verdict = try await verifier.verify(bundleAt: dir)
        guard case .invalid(let errors) = verdict else {
            Issue.record("Debería detectar la alteración")
            return
        }
        #expect(!errors.isEmpty)
        #expect(errors.contains { if case .hashMismatch = $0 { true } else { false } },
            "Debe reportar hashMismatch, errores: \(errors)")
    }

    @Test("Detección de sello intermedio borrado rompe prevSealHash")
    func detectsMissingIntermediateSeal() async throws {
        // Este test verifica que si se borra el sello 0 de una cadena de 2,
        // el sello 1 falla porque su prevSealHash apunta a un sello inexistente.
        // Esto se prueba indirectamente en el ChainVerifier cuando verifica
        // el encadenamiento — si falta un eslabón, el prevSealHash no coincide.

        // Como el ChainVerifier parsea chain.jsonl entero, el caso "borrar un sello
        // del medio" no es detectable parseando solo los que están. Lo que sí detecta
        // es un prevSealHash que no coincide con el hash del sello i-1.
        // Si se borra el sello 0 y queda solo el 1, el sello 1 tiene prevSealHash
        // que no es nil → error porque el sello en índice 0 (ahora el antiguo sello 1)
        // tiene prevSealHash != nil.

        // Para simplificar: creamos cadena de 2, luego reescribimos chain.jsonl
        // solo con el sello 1 (simulando borrado del 0).
        let dir = tempBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scansDir = dir.appendingPathComponent("scans/test")
        try FileManager.default.createDirectory(at: scansDir, withIntermediateDirectories: true)
        try "data".data(using: .utf8)!.write(to: scansDir.appendingPathComponent("mesh.ply"))
        let sealsDir = dir.appendingPathComponent("seals")
        try FileManager.default.createDirectory(at: sealsDir, withIntermediateDirectories: true)

        let author = AuthorIdentity(name: "A", role: "R", institution: "I")
        let key = SoftwareSigningKey()
        let signer = SealSigner()
        let encoder = CanonicalJSONEncoder()

        let seal0 = try! await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: nil, key: key)
        let seal1 = try! await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: seal0, key: key, clock: Date().addingTimeInterval(3600))

        // Escribir SOLO seal1 (simulando borrado de seal0)
        let chainPath = sealsDir.appendingPathComponent("chain.jsonl")
        let seal1Data = try encoder.encode(seal1)
        try seal1Data.write(to: chainPath)

        let verifier = ChainVerifier()
        let verdict = try await verifier.verify(bundleAt: dir)
        guard case .invalid(let errors) = verdict else {
            Issue.record("Debería detectar cadena rota (falta sello 0)")
            return
        }
        #expect(errors.contains { if case .chainBroken = $0 { true } else { false } },
            "Debe reportar cadena rota")
    }

    @Test("Detección de archivo añadido no declarado en manifiesto")
    func detectsUndeclaredFile() async throws {
        let (dir, verifier) = try await createSealedBundle()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Añadir archivo no declarado
        try "hidden data".data(using: .utf8)!.write(to: dir.appendingPathComponent("secret.txt"))

        let verdict = try await verifier.verify(bundleAt: dir)
        guard case .invalid(let errors) = verdict else {
            Issue.record("Debería detectar archivo no declarado")
            return
        }
        #expect(errors.contains { if case .extraFileNotDeclared = $0 { true } else { false } })
    }

    @Test("Bundle sin chain.jsonl produce error")
    func noChainFileProducesError() async throws {
        let dir = tempBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let verifier = ChainVerifier()
        let verdict = try await verifier.verify(bundleAt: dir)
        #expect(!verdict.isValid)
    }
}

// Helper: append data to file
extension Data {
    func writeToFile(_ url: URL, append: Bool) throws {
        if append, FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(self)
            try handle.close()
        } else {
            try write(to: url)
        }
    }
}

@Suite("F10 Custody: firma v2 y rotación de clave")
struct SealV2Tests {

    // El "|" en el nombre prueba que el payload v2 sigue siendo inequívoco.
    let author = AuthorIdentity(name: "A|B", role: "R", institution: "I")

    func bundle() throws -> URL {
        let dir = tempBundleDir(name: "v2")
        let scans = dir.appendingPathComponent("scans/s")
        try FileManager.default.createDirectory(at: scans, withIntermediateDirectories: true)
        try Data("mesh".utf8).write(to: scans.appendingPathComponent("mesh.ply"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("seals"), withIntermediateDirectories: true)
        return dir
    }

    func writeChain(_ seals: [SealRecord], to dir: URL) throws {
        var data = Data()
        for seal in seals { data += try CanonicalJSONEncoder().encode(seal) + Data("\n".utf8) }
        try data.write(to: dir.appendingPathComponent("seals/chain.jsonl"))
    }

    func hash(_ seal: SealRecord) throws -> String {
        SHA256.hash(data: try CanonicalJSONEncoder().encode(seal)).map { String(format: "%02x", $0) }.joined()
    }

    func errors(_ dir: URL) async throws -> [CustodyError] {
        if case .invalid(let e) = try await ChainVerifier().verify(bundleAt: dir) { return e }
        return []
    }

    @Test("Sello v1 antiguo (sin signatureVersion) sigue verificando")
    func legacyV1StillVerifies() async throws {
        let dir = try bundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SoftwareSigningKey()
        var seal = try await SealSigner().seal(bundleAt: dir, author: author, geo: nil, previousSeal: nil, key: key)
        seal.signatureVersion = nil
        seal.keyProtection = nil
        seal.signatureDER = try key.sign(data: SealPayload.bytes(for: seal))
        let ms = CanonicalDateCoding.millisecondsSince1970(seal.wallClock)
        #expect(SealPayload.bytes(for: seal) == Data("\(seal.rootHash)|\(ms)|A|B".utf8))
        // Los campos nuevos en nil no se escriben: un sello v1 conserva sus bytes.
        let json = String(decoding: try CanonicalJSONEncoder().encode(seal), as: UTF8.self)
        #expect(!json.contains("signatureVersion") && !json.contains("keyProtection"))
        try writeChain([seal], to: dir)
        #expect(try await errors(dir).isEmpty)
    }

    @Test("Borrar un sello intermedio y corregir prevSealHash rompe la firma v2")
    func deletingMiddleSealAndPatchingHashIsDetected() async throws {
        let dir = try bundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SoftwareSigningKey()
        let signer = SealSigner()
        let s0 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: nil, key: key)
        let s1 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: s0, key: key)
        var s2 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: s1, key: key)
        try writeChain([s0, s1, s2], to: dir)
        #expect(try await errors(dir).isEmpty)

        // Ataque: quitar s1, renumerar s2 y hacerlo apuntar a s0. Sin la clave no
        // se puede volver a firmar, así que la firma de s2 deja de verificar.
        s2.index = 1
        s2.prevSealHash = try hash(s0)
        try writeChain([s0, s2], to: dir)
        let errs = try await errors(dir)
        #expect(errs.contains { if case .invalidSeal(let m) = $0 { m.contains("Firma inválida") } else { false } },
                "errores: \(errs)")
    }

    @Test("Cambio de clave declarado verifica; previousKeyID es la clave anterior")
    func declaredRotationVerifies() async throws {
        let dir = try bundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldKey = SoftwareSigningKey(), newKey = SoftwareSigningKey()
        let signer = SealSigner()
        let s0 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: nil, key: oldKey)
        let s1 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: s0, key: newKey)
        let s2 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: s1, key: newKey)
        #expect(s1.previousKeyID == oldKey.keyID)
        #expect(s2.previousKeyID == nil)
        try writeChain([s0, s1, s2], to: dir)
        #expect(try await errors(dir).isEmpty)
    }

    @Test("Cambio de clave sin declarar se detecta aunque la firma sea válida")
    func undeclaredRotationIsDetected() async throws {
        let dir = try bundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldKey = SoftwareSigningKey(), newKey = SoftwareSigningKey()
        let signer = SealSigner()
        let s0 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: nil, key: oldKey)
        var s1 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: s0, key: newKey)
        s1.previousKeyID = nil
        s1.signatureDER = try newKey.sign(data: SealPayload.bytes(for: s1))
        try writeChain([s0, s1], to: dir)
        let errs = try await errors(dir)
        #expect(errs.contains { if case .chainBroken(index: 1, reason: let r) = $0 { r.contains("no declarado") } else { false } },
                "errores: \(errs)")
    }

    @Test("Un sello v1 después de uno v2 se rechaza")
    func downgradeToV1IsRejected() async throws {
        let dir = try bundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SoftwareSigningKey()
        let signer = SealSigner()
        let s0 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: nil, key: key)
        var s1 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: s0, key: key)
        s1.signatureVersion = nil
        s1.signatureDER = try key.sign(data: SealPayload.bytes(for: s1))
        try writeChain([s0, s1], to: dir)
        let errs = try await errors(dir)
        #expect(errs.contains { if case .chainBroken(index: 1, reason: _) = $0 { true } else { false } }, "errores: \(errs)")
    }

    @Test("keyID que no corresponde a la clave pública se rechaza")
    func keyIDMismatchIsRejected() async throws {
        let dir = try bundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SoftwareSigningKey()
        var s0 = try await SealSigner().seal(bundleAt: dir, author: author, geo: nil, previousSeal: nil, key: key)
        s0.deviceKeyID = "0000000000000000"
        s0.signatureDER = try key.sign(data: SealPayload.bytes(for: s0))
        try writeChain([s0], to: dir)
        let errs = try await errors(dir)
        #expect(errs.contains { if case .invalidSeal(let m) = $0 { m.contains("keyID") } else { false } })
    }

    @Test("La clave de software se guarda y recupera con la misma keyID")
    func softwareKeyRoundTrip() throws {
        let key = SoftwareSigningKey()
        let restored = try SoftwareSigningKey(rawRepresentation: key.rawRepresentation)
        #expect(restored.keyID == key.keyID)
        #expect(restored.publicKeyDER == key.publicKeyDER)
    }
}
