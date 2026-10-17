import Foundation
import Domain
import Custody

// ═══════════════════════════════════════════════════════════════════════════════
// Custodia en palabras de terreno: qué archivo es cada ruta del expediente, qué
// selló cada eslabón y qué significa cada problema de verificación. El detalle
// técnico (rutas, códigos) queda aparte, para el perito.
// ═══════════════════════════════════════════════════════════════════════════════

nonisolated enum CustodyText {

    /// "el modelo 3D del escaneo «Registro inicial» del 14 oct 2026, 23:04"
    static func describe(path: String, scans: [ScanEntry]) -> String {
        let parts = path.split(separator: "/").map(String.init)
        switch parts.first ?? "" {
        case "finding.json": return "la ficha del hallazgo"
        case "site.json": return "la copia de la ficha del sitio"
        case "notes":
            return "la nota de custodia \((parts.last ?? "").replacingOccurrences(of: ".json", with: ""))"
        case "measurements":
            return "la medición de volumen \((parts.last ?? "").replacingOccurrences(of: ".json", with: ""))"
        case "scans" where parts.count >= 3:
            let file = parts.dropFirst(2).joined(separator: "/")
            let what = switch file {
            case "mesh.ply": "el modelo 3D"
            case "geo.json": "las lecturas GPS"
            case "scan.json": "los datos"
            case ".sealed": "la marca de sellado"
            default: "el archivo \(file)"
            }
            return "\(what) \(scanName(parts[1], scans: scans))"
        default:
            return "el archivo \(path)"
        }
    }

    /// Qué incorporó un sello, en una línea por cosa (escaneo, medición, ficha).
    static func sealedItems(_ change: SealChange, scans: [ScanEntry],
                            notes: [String: CustodyNote] = [:]) -> [String] {
        var items: [String] = []
        let added = Set(change.added)
        if added.contains("finding.json") { items.append("Apertura del expediente (ficha del hallazgo y del sitio)") }
        var seenScans = Set<String>()
        for path in change.added {
            let parts = path.split(separator: "/").map(String.init)
            if parts.first == "scans", parts.count >= 3, seenScans.insert(parts[1]).inserted {
                items.append("Escaneo nuevo: \(scanName(parts[1], scans: scans).replacingOccurrences(of: "del escaneo ", with: ""))")
            } else if parts.first == "notes", let note = notes[parts.last ?? ""] {
                items.append("Sello «\(note.kind.label)»: \(note.text)")
            } else if parts.first == "measurements" {
                items.append("Medición nueva: " + describe(path: path, scans: scans).replacingOccurrences(of: "la medición de volumen ", with: "volumen "))
            }
        }
        items += change.modified.map { "Cambió " + describe(path: $0, scans: scans) }
        items += change.removed.map { "Se quitó " + describe(path: $0, scans: scans) }
        return items.isEmpty ? ["Sin archivos nuevos (sello de control)"] : items
    }

    /// Con qué clave se firmó un sello.
    static func signature(_ seal: SealRecord) -> String {
        switch seal.keyProtection {
        case .secureEnclave: "Firmado con el chip seguro del iPhone (Face ID o código)"
        case .software: "Firmado con clave de software (sin chip seguro)"
        case nil: "Firmado con clave de software (formato antiguo)"
        }
    }

    /// Problema de verificación en una frase entendible.
    static func describe(_ error: CustodyError, scans: [ScanEntry]) -> String {
        switch error {
        case .hashMismatch(let path):
            "Se modificó \(describe(path: path, scans: scans)) después de sellarse."
        case .fileMissing(let path):
            "Falta \(describe(path: path, scans: scans)), que estaba sellado."
        case .extraFileNotDeclared(let path):
            "Se agregó \(describe(path: path, scans: scans)) sin sellarlo."
        case .manifestTampered:
            "La lista de archivos sellada no coincide con lo que hay en la carpeta."
        case .chainBroken(let index, _):
            "La cadena se rompe en el sello N.º \(index + 1): se borró, agregó, reordenó o editó un sello."
        case .invalidSeal:
            "Un sello tiene una firma que no corresponde: fue editado después de firmarse."
        case .bundleNotFound:
            "El expediente todavía no tiene sellos (aún no se guarda ningún escaneo)."
        case .verificationFailed:
            "No se pudo leer la cadena de sellos."
        case .sealedDirectoryImmutable, .signingFailed:
            "Problema al sellar el expediente."
        }
    }

    private static func scanName(_ dirName: String, scans: [ScanEntry]) -> String {
        guard let entry = scans.first(where: { $0.dir.lastPathComponent == dirName }) else {
            return "del escaneo \(dirName.prefix(8))"
        }
        return "del escaneo «\(entry.scan.purpose.label)» del \(entry.scan.capturedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
