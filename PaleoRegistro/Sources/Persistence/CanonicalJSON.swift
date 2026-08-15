import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// F9 — CanonicalJSONEncoder. JSON determinista: claves ordenadas, floats con
// representación decimal fija (locale-independiente), rechazo de NaN/Inf.
//
// Propiedades:
// - Dos procesos con los mismos datos producen bytes idénticos (SHA-256).
// - Debug y Release producen los mismos bytes.
// - -0.0 y 0.0 se serializan igual.
// - NaN e Inf producen error, nunca null silencioso.
//
// Diseño: se construye un AST ligero (_JSONValue) y se renderiza al final con
// claves ordenadas. Esto evita los problemas de orden de escritura del
// protocolo Encoder y maneja correctamente enums con valores asociados
// (nested containers).
// ═══════════════════════════════════════════════════════════════════════════════

public enum CanonicalJSONError: Error, Equatable, Sendable {
    case nanOrInf(String)
    case encodingFailed(String)
}

public struct CanonicalJSONEncoder: Sendable {

    public init() {}

    public func encode<T: Encodable>(_ value: T) throws(CanonicalJSONError) -> Data {
        let encoder = _CanonicalEncoder()
        do {
            try value.encode(to: encoder)
        } catch {
            throw .encodingFailed("\(error)")
        }
        if let failure = encoder.failure {
            throw failure
        }
        let json = render(encoder.root ?? .null)
        guard let data = json.data(using: .utf8) else {
            throw .encodingFailed("No se pudo convertir a UTF-8")
        }
        return data
    }

    /// Conveniencia: SHA-256 (hex, 64 caracteres) del JSON canónico.
    /// Útil para calcular el `rootHash` del manifiesto en Custody.
    public func canonicalHash<T: Encodable>(_ value: T) throws(CanonicalJSONError) -> String {
        let data = try encode(value)
        return SelfSHA256.hex(data)
    }
}

// MARK: - AST

private indirect enum _JSONValue {
    case null
    case bool(Bool)
    case string(String)
    case number(String)          // ya formateado canónicamente
    case array(_ArrayBox)
    case object(_KeyedBox)
}

private final class _ArrayBox {
    var items: [_JSONValue] = []
}

private final class _KeyedBox {
    var entries: [(key: String, value: _JSONValue)] = []
}

// MARK: - Render

private func render(_ value: _JSONValue) -> String {
    switch value {
    case .null:
        return "null"
    case .bool(let b):
        return b ? "true" : "false"
    case .string(let s):
        return CanonicalFormat.escapeString(s)
    case .number(let n):
        return n
    case .array(let box):
        return "[" + box.items.map { render($0) }.joined(separator: ",") + "]"
    case .object(let box):
        let sorted = box.entries.sorted { $0.key < $1.key }
        return "{" + sorted.map { "\(CanonicalFormat.escapeString($0.key)):\(render($0.value))" }.joined(separator: ",") + "}"
    }
}

// MARK: - Encoder

private final class _CanonicalEncoder: Encoder {
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    var failure: CanonicalJSONError?
    var root: _JSONValue?

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        let box = _KeyedBox()
        root = .object(box)
        return KeyedEncodingContainer(_CanonicalKeyedContainer<Key>(box: box, encoder: self))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        let box = _ArrayBox()
        root = .array(box)
        return _CanonicalUnkeyedContainer(box: box, encoder: self)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        _CanonicalSingleValueContainer(encoder: self)
    }
}

// MARK: - Keyed container

private struct _CanonicalKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let box: _KeyedBox
    let encoder: _CanonicalEncoder
    var codingPath: [CodingKey] { encoder.codingPath }

    mutating func encodeNil(forKey key: Key) { box.entries.append((key.stringValue, .null)) }
    mutating func encode(_ value: Bool, forKey key: Key) { box.entries.append((key.stringValue, .bool(value))) }
    mutating func encode(_ value: String, forKey key: Key) { box.entries.append((key.stringValue, .string(value))) }

    mutating func encode(_ value: Double, forKey key: Key) {
        if let s = CanonicalFormat.formatDouble(value) {
            box.entries.append((key.stringValue, .number(s)))
        } else {
            encoder.failure = .nanOrInf(key.stringValue)
            box.entries.append((key.stringValue, .null))
        }
    }
    mutating func encode(_ value: Float, forKey key: Key) {
        if let s = CanonicalFormat.formatFloat(value) {
            box.entries.append((key.stringValue, .number(s)))
        } else {
            encoder.failure = .nanOrInf(key.stringValue)
            box.entries.append((key.stringValue, .null))
        }
    }

    mutating func encode(_ value: Int, forKey key: Key) { box.entries.append((key.stringValue, .number(String(value)))) }
    mutating func encode(_ value: Int8, forKey key: Key) { box.entries.append((key.stringValue, .number(String(value)))) }
    mutating func encode(_ value: Int16, forKey key: Key) { box.entries.append((key.stringValue, .number(String(value)))) }
    mutating func encode(_ value: Int32, forKey key: Key) { box.entries.append((key.stringValue, .number(String(value)))) }
    mutating func encode(_ value: Int64, forKey key: Key) { box.entries.append((key.stringValue, .number(String(value)))) }
    mutating func encode(_ value: UInt, forKey key: Key) { box.entries.append((key.stringValue, .number(String(value)))) }
    mutating func encode(_ value: UInt8, forKey key: Key) { box.entries.append((key.stringValue, .number(String(value)))) }
    mutating func encode(_ value: UInt16, forKey key: Key) { box.entries.append((key.stringValue, .number(String(value)))) }
    mutating func encode(_ value: UInt32, forKey key: Key) { box.entries.append((key.stringValue, .number(String(value)))) }
    mutating func encode(_ value: UInt64, forKey key: Key) { box.entries.append((key.stringValue, .number(String(value)))) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        let child = _CanonicalEncoder()
        try value.encode(to: child)
        if let f = child.failure { throw f }
        box.entries.append((key.stringValue, child.root ?? .null))
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let childBox = _KeyedBox()
        box.entries.append((key.stringValue, .object(childBox)))
        return KeyedEncodingContainer(_CanonicalKeyedContainer<NestedKey>(box: childBox, encoder: encoder))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let childBox = _ArrayBox()
        box.entries.append((key.stringValue, .array(childBox)))
        return _CanonicalUnkeyedContainer(box: childBox, encoder: encoder)
    }

    mutating func superEncoder() -> Encoder { encoder }
    mutating func superEncoder(forKey key: Key) -> Encoder { encoder }
}

// MARK: - Unkeyed container

private struct _CanonicalUnkeyedContainer: UnkeyedEncodingContainer {
    let box: _ArrayBox
    let encoder: _CanonicalEncoder
    var codingPath: [CodingKey] { encoder.codingPath }
    var count: Int { box.items.count }

    mutating func encodeNil() { box.items.append(.null) }
    mutating func encode(_ value: Bool) { box.items.append(.bool(value)) }
    mutating func encode(_ value: String) { box.items.append(.string(value)) }

    mutating func encode(_ value: Double) {
        if let s = CanonicalFormat.formatDouble(value) { box.items.append(.number(s)) }
        else { encoder.failure = .nanOrInf("array"); box.items.append(.null) }
    }
    mutating func encode(_ value: Float) {
        if let s = CanonicalFormat.formatFloat(value) { box.items.append(.number(s)) }
        else { encoder.failure = .nanOrInf("array"); box.items.append(.null) }
    }

    mutating func encode(_ value: Int) { box.items.append(.number(String(value))) }
    mutating func encode(_ value: Int8) { box.items.append(.number(String(value))) }
    mutating func encode(_ value: Int16) { box.items.append(.number(String(value))) }
    mutating func encode(_ value: Int32) { box.items.append(.number(String(value))) }
    mutating func encode(_ value: Int64) { box.items.append(.number(String(value))) }
    mutating func encode(_ value: UInt) { box.items.append(.number(String(value))) }
    mutating func encode(_ value: UInt8) { box.items.append(.number(String(value))) }
    mutating func encode(_ value: UInt16) { box.items.append(.number(String(value))) }
    mutating func encode(_ value: UInt32) { box.items.append(.number(String(value))) }
    mutating func encode(_ value: UInt64) { box.items.append(.number(String(value))) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let child = _CanonicalEncoder()
        try value.encode(to: child)
        if let f = child.failure { throw f }
        box.items.append(child.root ?? .null)
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let childBox = _KeyedBox()
        box.items.append(.object(childBox))
        return KeyedEncodingContainer(_CanonicalKeyedContainer<NestedKey>(box: childBox, encoder: encoder))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let childBox = _ArrayBox()
        box.items.append(.array(childBox))
        return _CanonicalUnkeyedContainer(box: childBox, encoder: encoder)
    }

    mutating func superEncoder() -> Encoder { encoder }
}

// MARK: - Single value container

private struct _CanonicalSingleValueContainer: SingleValueEncodingContainer {
    let encoder: _CanonicalEncoder
    var codingPath: [CodingKey] { encoder.codingPath }

    func encodeNil() { encoder.root = .null }
    func encode(_ value: Bool) { encoder.root = .bool(value) }
    func encode(_ value: String) { encoder.root = .string(value) }

    func encode(_ value: Double) {
        if let s = CanonicalFormat.formatDouble(value) { encoder.root = .number(s) }
        else { encoder.failure = .nanOrInf("single"); encoder.root = .null }
    }
    func encode(_ value: Float) {
        if let s = CanonicalFormat.formatFloat(value) { encoder.root = .number(s) }
        else { encoder.failure = .nanOrInf("single"); encoder.root = .null }
    }

    func encode(_ value: Int) { encoder.root = .number(String(value)) }
    func encode(_ value: Int8) { encoder.root = .number(String(value)) }
    func encode(_ value: Int16) { encoder.root = .number(String(value)) }
    func encode(_ value: Int32) { encoder.root = .number(String(value)) }
    func encode(_ value: Int64) { encoder.root = .number(String(value)) }
    func encode(_ value: UInt) { encoder.root = .number(String(value)) }
    func encode(_ value: UInt8) { encoder.root = .number(String(value)) }
    func encode(_ value: UInt16) { encoder.root = .number(String(value)) }
    func encode(_ value: UInt32) { encoder.root = .number(String(value)) }
    func encode(_ value: UInt64) { encoder.root = .number(String(value)) }

    func encode<T: Encodable>(_ value: T) throws {
        let child = _CanonicalEncoder()
        try value.encode(to: child)
        if let f = child.failure { throw f }
        encoder.root = child.root ?? .null
    }
}

// MARK: - Formato canónico de números (locale-independiente)

private enum CanonicalFormat {

    /// Formatea un Double a string canónico, sin depender de la configuración
    /// regional del dispositivo. Usa la representación más corta que hace
    /// round-trip exacto (`.description`), que es estable y usa `.` como
    /// separador decimal en todas las configuraciones.
    static func formatDouble(_ value: Double) -> String? {
        if value.isNaN || value.isInfinite { return nil }
        if value == 0 { return "0.0" } // elimina -0.0
        return value.description
    }

    static func formatFloat(_ value: Float) -> String? {
        if value.isNaN || value.isInfinite { return nil }
        if value == 0 { return "0.0" }
        return value.description
    }

    static func escapeString(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if let ascii = c.asciiValue, ascii < 0x20 {
                    out += String(format: "\\u%04x", ascii)
                } else {
                    out.append(c)
                }
            }
        }
        out += "\""
        return out
    }
}

// MARK: - SHA-256 autocontenida (sin dependencias externas)

private enum SelfSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ data: Data) -> String {
        var h: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        )
        var buf = Array(data)
        let bitCount = UInt64(data.count) * 8
        buf.append(0x80)
        while (buf.count % 64) != 56 { buf.append(0) }
        buf.append(contentsOf: withUnsafeBytes(of: bitCount.bigEndian) { Array($0) })
        for i in stride(from: 0, to: buf.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for j in 0..<16 {
                let o = i + j * 4
                w[j] = (UInt32(buf[o]) << 24) | (UInt32(buf[o+1]) << 16)
                     | (UInt32(buf[o+2]) << 8) | UInt32(buf[o+3])
            }
            for j in 16..<64 {
                let s0 = rotr(w[j-15], 7) ^ rotr(w[j-15], 18) ^ (w[j-15] >> 3)
                let s1 = rotr(w[j-2], 17) ^ rotr(w[j-2], 19) ^ (w[j-2] >> 10)
                w[j] = w[j-16] &+ s0 &+ w[j-7] &+ s1
            }
            var a = h.0, b = h.1, c = h.2, d = h.3
            var e = h.4, f = h.5, g = h.6, hh = h.7
            for j in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[j] &+ w[j]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h.0 &+= a; h.1 &+= b; h.2 &+= c; h.3 &+= d
            h.4 &+= e; h.5 &+= f; h.6 &+= g; h.7 &+= hh
        }
        let d = [h.0, h.1, h.2, h.3, h.4, h.5, h.6, h.7]
        return d.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotr(_ v: UInt32, _ n: UInt32) -> UInt32 {
        (v >> n) | (v << (32 - n))
    }
}