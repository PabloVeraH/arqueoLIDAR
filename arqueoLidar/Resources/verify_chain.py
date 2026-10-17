#!/usr/bin/env python3
"""
verify_chain.py — Verificador externo de la cadena de custodia de PaleoRegistro.

Reproduce, sin la app y sin Swift, el veredicto de `ChainVerifier` sobre un
expediente (carpeta FND-xxxxxxxx) copiado desde el iPhone. Detecta:
  - archivo alterado (hash no coincide con el manifiesto del último sello)
  - archivo faltante
  - archivo añadido no declarado en el manifiesto
  - manifiesto manipulado (rootHash recalculado ≠ rootHash sellado)
  - cadena rota (prevSealHash no encadena con el sello anterior)
  - firma inválida (ECDSA P-256 / SHA-256 sobre el payload firmado)

Uso:
    python3 verify_chain.py <ruta_al_expediente>

Requisitos: Python 3.8+. Para verificar las firmas se necesita además el
paquete `cryptography` (pip install cryptography). Sin él, el script verifica
integridad y encadenamiento, pero lo dice explícitamente y NO declara el
expediente como verificado por completo.

Códigos de salida:
    0  íntegro y firmas verificadas
    1  se detectó manipulación o un error de formato
    2  uso incorrecto
    3  íntegro, pero las firmas no se pudieron verificar (falta `cryptography`)

Formato que replica (ver PaleoRegistro/Sources):
  - Cada línea de seals/chain.jsonl es exactamente la salida de
    CanonicalJSONEncoder para un SealRecord. prevSealHash = SHA-256 de esos
    mismos bytes del sello anterior.
  - rootHash = SHA-256 del JSON canónico de la lista de FileDigest
    (claves ordenadas, sin espacios, UTF-8).
  - Payload firmado (ver SealPayload en Custody/SealSigner.swift):
      v2 (signatureVersion = 2):
        "v2|<index>|<prevSealHash o ->|<rootHash>|<ms>|<deviceKeyID>|<keyProtection o ->|<previousKeyID o ->|<author.name>"
      v1 (sellos antiguos, sin signatureVersion):
        "<rootHash>|<ms>|<author.name>"
    <ms> = wallClock en milisegundos Unix enteros; wallClock se guarda como
    ISO 8601 UTC con milisegundos ("2026-08-15T02:27:16.407Z").
  - Reglas de clave (solo sellos v2): deviceKeyID = 16 primeros hex del
    SHA-256 de publicKeyDER; si la clave cambia respecto del sello anterior,
    previousKeyID declara la anterior; tras un sello v2 no se acepta uno v1.
"""

import base64
import calendar
import hashlib
import json
import os
import re
import sys
from datetime import datetime

try:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    CRYPTO_AVAILABLE = True
except ImportError:
    CRYPTO_AVAILABLE = False

# Segundos entre 1970-01-01 y 2001-01-01 (epoch de referencia de Foundation).
# Solo se usa para leer sellos antiguos que guardaban wallClock como número.
APPLE_REFERENCE_EPOCH = 978_307_200

# Archivos que la app excluye del manifiesto (ver Hasher.buildManifest).
EXCLUDED_TOP_LEVEL = {".sealed", "VERIFY.txt"}


def canonical_json_bytes(obj) -> bytes:
    """JSON canónico equivalente a CanonicalJSONEncoder para objetos simples
    (strings, enteros, listas, diccionarios): claves ordenadas, sin espacios."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compute_root_hash(manifest_entries) -> str:
    """rootHash = SHA-256 del manifiesto (lista de FileDigest) en JSON canónico."""
    entries = [
        {"relativePath": e["relativePath"], "bytes": int(e["bytes"]), "sha256": e["sha256"]}
        for e in manifest_entries
    ]
    return sha256_hex(canonical_json_bytes(entries))


_ISO_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?Z$")


def wall_clock_millis(value) -> int:
    """Convierte wallClock del sello a milisegundos Unix enteros, igual que
    CanonicalDateCoding.millisecondsSince1970 en la app."""
    if isinstance(value, str):
        m = _ISO_RE.match(value)
        if not m:
            raise ValueError(f"wallClock con formato inesperado: {value!r}")
        dt = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")
        frac = (m.group(2) or "0").ljust(3, "0")[:3]
        return calendar.timegm(dt.timetuple()) * 1000 + int(frac)
    if isinstance(value, (int, float)):
        # Formato antiguo: segundos desde 2001-01-01 (Codable por defecto de Date).
        return int(round((float(value) + APPLE_REFERENCE_EPOCH) * 1000))
    raise ValueError(f"wallClock con tipo inesperado: {type(value).__name__}")


def signed_payload(seal) -> bytes:
    """Bytes firmados, igual que SealPayload.bytes(for:) en la app."""
    ms = wall_clock_millis(seal["wallClock"])
    name = seal["author"]["name"]
    if seal.get("signatureVersion") != 2:
        return f"{seal['rootHash']}|{ms}|{name}".encode("utf-8")
    fields = ["v2", str(seal["index"]), seal.get("prevSealHash") or "-", seal["rootHash"], str(ms),
              seal["deviceKeyID"], seal.get("keyProtection") or "-", seal.get("previousKeyID") or "-", name]
    return "|".join(fields).encode("utf-8")


def key_errors(i, seal, prev):
    """Reglas de clave de ChainVerifier.keyErrors."""
    if seal.get("signatureVersion") != 2:
        if prev is not None and prev.get("signatureVersion") == 2:
            return [f"Sello {i}: sello v1 después de uno v2 (formato sin firma de la cadena)"]
        return []
    errors = []
    key_id = sha256_hex(base64.b64decode(seal.get("publicKeyDER", "")))[:16]
    if seal.get("deviceKeyID") != key_id:
        errors.append(f"Sello {i}: keyID no corresponde a su clave pública")
    expected = None
    if prev is not None and prev.get("deviceKeyID") != seal.get("deviceKeyID"):
        expected = prev.get("deviceKeyID")
    if seal.get("previousKeyID") != expected:
        errors.append(f"Sello {i}: " + ("cambio de clave no declarado" if expected
                                         else "declara un cambio de clave que no ocurrió"))
    return errors


def verify_signature(seal, payload: bytes) -> bool:
    """Verifica la firma ECDSA P-256 (DER) con la clave pública del sello
    (SubjectPublicKeyInfo en DER, tal como la exporta CryptoKit)."""
    pub_der = base64.b64decode(seal.get("publicKeyDER", ""))
    sig_der = base64.b64decode(seal.get("signatureDER", ""))
    pub = serialization.load_der_public_key(pub_der)
    if not isinstance(pub, ec.EllipticCurvePublicKey) or pub.curve.name != "secp256r1":
        return False
    try:
        pub.verify(sig_der, payload, ec.ECDSA(hashes.SHA256()))
        return True
    except InvalidSignature:
        return False


def build_manifest(bundle_path: str):
    """Manifiesto actual del expediente, con las mismas exclusiones que la app:
    la carpeta seals/ completa y los archivos .sealed / VERIFY.txt de la raíz."""
    manifest = []
    for root, dirs, files in os.walk(bundle_path):
        if os.path.abspath(root) == os.path.abspath(bundle_path):
            dirs[:] = [d for d in dirs if d != "seals"]
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, bundle_path).replace(os.sep, "/")
            if rel in EXCLUDED_TOP_LEVEL:
                continue
            if name == ".DS_Store":
                # Lo crea Finder al abrir la carpeta en la Mac; no es parte del expediente.
                continue
            with open(full, "rb") as f:
                content = f.read()
            manifest.append({"relativePath": rel, "bytes": len(content), "sha256": sha256_hex(content)})
    manifest.sort(key=lambda e: e["relativePath"])
    return manifest


def verify(bundle_path: str):
    """Devuelve (íntegro, firmas_verificadas, errores, avisos)."""
    errors, warnings = [], []

    chain_path = os.path.join(bundle_path, "seals", "chain.jsonl")
    if not os.path.exists(chain_path):
        return False, False, ["No se encontró seals/chain.jsonl"], warnings

    with open(chain_path, "rb") as f:
        raw_lines = [ln for ln in f.read().split(b"\n") if ln.strip()]
    if not raw_lines:
        return False, False, ["chain.jsonl está vacía"], warnings

    seals = []
    for i, raw in enumerate(raw_lines):
        try:
            seals.append(json.loads(raw.decode("utf-8")))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return False, False, [f"Sello {i} no es JSON válido"], warnings

    # 1. Encadenamiento: prevSealHash = SHA-256 de los bytes del sello anterior.
    for i, seal in enumerate(seals):
        if seal.get("index") != i:
            errors.append(f"Sello {i}: índice {seal.get('index')} fuera de orden")
        if i == 0:
            if seal.get("prevSealHash") is not None:
                errors.append("Sello 0 no debería tener prevSealHash")
        elif seal.get("prevSealHash") != sha256_hex(raw_lines[i - 1]):
            errors.append(f"Sello {i}: prevSealHash no encadena con el sello {i - 1}")
        errors += key_errors(i, seal, seals[i - 1] if i > 0 else None)

    # 2. Cada sello: su rootHash debe corresponder a su propio manifiesto.
    for i, seal in enumerate(seals):
        if compute_root_hash(seal.get("manifest", [])) != seal.get("rootHash"):
            errors.append(f"Sello {i}: el manifiesto no corresponde a su rootHash (manifiesto manipulado)")

    # 3. Archivos actuales contra el manifiesto del último sello.
    last = seals[-1]
    manifest = last.get("manifest", [])
    declared = {m["relativePath"] for m in manifest}
    current = build_manifest(bundle_path)
    current_by_path = {m["relativePath"]: m for m in current}

    for entry in manifest:
        rel = entry["relativePath"]
        if rel not in current_by_path:
            errors.append(f"Falta archivo: {rel}")
        elif current_by_path[rel]["sha256"] != entry["sha256"]:
            errors.append(f"Hash alterado: {rel}")
    for m in current:
        if m["relativePath"] not in declared:
            errors.append(f"Archivo añadido no declarado: {m['relativePath']}")
    if compute_root_hash(current) != last.get("rootHash") and not errors:
        errors.append("El rootHash del contenido actual no coincide con el último sello")

    # 4. Firmas.
    signatures_ok = False
    if CRYPTO_AVAILABLE:
        signatures_ok = True
        for seal in seals:
            try:
                if not verify_signature(seal, signed_payload(seal)):
                    errors.append(f"Sello {seal.get('index')}: firma inválida")
                    signatures_ok = False
            except (KeyError, ValueError) as e:
                errors.append(f"Sello {seal.get('index')}: no se pudo verificar la firma ({e})")
                signatures_ok = False
    else:
        warnings.append("No está instalado el paquete 'cryptography': las firmas NO se verificaron "
                        "(instálalo con: pip install cryptography)")

    return (len(errors) == 0), signatures_ok, errors, warnings


def main():
    if len(sys.argv) != 2:
        print("Uso: python3 verify_chain.py <ruta_al_expediente>")
        sys.exit(2)

    bundle = sys.argv[1]
    if not os.path.isdir(bundle):
        print(f"ERROR: {bundle} no es un directorio")
        sys.exit(2)

    ok, signatures_ok, errors, warnings = verify(bundle)
    for w in warnings:
        print(f"AVISO: {w}")
    if not ok:
        print("VERIFICACIÓN: FALLO. Se detectó manipulación o un error de formato:")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)
    if not signatures_ok:
        print("VERIFICACIÓN: INCOMPLETA. Archivos y cadena íntegros, pero las firmas no se verificaron.")
        sys.exit(3)
    print("VERIFICACIÓN: OK. El expediente es íntegro, la cadena es consistente y las firmas son válidas.")
    sys.exit(0)


if __name__ == "__main__":
    main()
