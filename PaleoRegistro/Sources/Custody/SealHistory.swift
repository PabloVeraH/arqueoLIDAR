import Foundation
import Domain
import Persistence

// ═══════════════════════════════════════════════════════════════════════════════
// F14 — Historial de sellos para mostrar al operador: qué archivos agregó o
// cambió cada sello respecto del anterior (comparando manifiestos). No verifica
// nada: eso es ChainVerifier.
// ═══════════════════════════════════════════════════════════════════════════════

public struct SealChange: Sendable, Equatable {
    public var seal: SealRecord
    /// Rutas relativas que aparecen por primera vez en este sello.
    public var added: [String]
    /// Rutas cuya huella cambió respecto del sello anterior.
    public var modified: [String]
    /// Rutas que estaban en el sello anterior y ya no.
    public var removed: [String]
}

public enum SealHistory {

    /// Sellos de `seals/chain.jsonl` en orden. Las líneas ilegibles se omiten:
    /// el verificador es quien las reporta.
    public static func read(bundleAt url: URL) -> [SealRecord] {
        let chain = url.appendingPathComponent("seals/chain.jsonl")
        guard let text = try? String(contentsOf: chain, encoding: .utf8) else { return [] }
        let decoder = CanonicalDateCoding.decoder()
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(SealRecord.self, from: Data($0.utf8))
        }
    }

    public static func changes(_ seals: [SealRecord]) -> [SealChange] {
        var previous: [String: String] = [:]
        return seals.map { seal in
            let current = Dictionary(seal.manifest.map { ($0.relativePath, $0.sha256) }, uniquingKeysWith: { a, _ in a })
            let added = current.keys.filter { previous[$0] == nil }.sorted()
            let modified = current.keys.filter { previous[$0] != nil && previous[$0] != current[$0] }.sorted()
            let removed = previous.keys.filter { current[$0] == nil }.sorted()
            previous = current
            return SealChange(seal: seal, added: added, modified: modified, removed: removed)
        }
    }
}
