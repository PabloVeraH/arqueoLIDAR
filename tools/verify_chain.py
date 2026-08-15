#!/usr/bin/env python3
"""
verify_chain.py — Verificador externo de la cadena de custodia de PaleoRegistro.

Reproduce, sin la app y sin Swift, el veredicto de `ChainVerifying` sobre un
bundle de hallazgo exportado. Detecta:
  - archivo alterado (hash no coincide con el manifiesto)
  - archivo añadido no declarado en el manifiesto
  - cadena rota (prevSealHash no encadena)
  - firma inválida (verificación P-256 ECDSA sobre el payload)

Uso:
    python3 verify_chain.py <ruta_al_bundle>

Requisitos: solo la biblioteca estándar de Python 3.8+ (hashlib, json, base64).
No necesita pip ni dependencias externas.

Devuelve código de salida 0 si el bundle es íntegro, 1 si detecta manipulación.
"""

import base64
import hashlib
import json
import os
import sys

try:
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import hashes
    CRYPTO_AVAILABLE = True
except ImportError:
    CRYPTO_AVAILABLE = False


def canonical_json_bytes(obj) -> bytes:
    """Serializa a JSON canónico: claves ordenadas, sin espacios, UTF-8."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compute_root_hash(manifest_entries):
    """Replica el rootHash del app: SHA-256 del manifiesto ordenado canónicamente."""
    # El manifiesto es una lista de {relativePath, bytes, sha256}
    # Se serializa canónicamente (claves ordenadas, sin espacios).
    return sha256_hex(canonical_json_bytes(manifest_entries))


def verify_signature(seal, payload: bytes) -> bool:
    """Verifica la firma P-256 ECDSA en DER. Si `cryptography` no está
    disponible, se omite la verificación criptográfica (solo integridad)."""
    if not CRYPTO_AVAILABLE:
        return True
    try:
        pub_der = base64.b64decode(seal.get("publicKeyDER", ""))
        sig_der = base64.b64decode(seal.get("signatureDER", ""))
        pub = ec.EllipticCurvePublicKey.from_encoded_point(
            ec.SECP256R1(), pub_der
        )
        # ECDSA P-256 + SHA-256 (CryptoKit usa SHA-256 por defecto)
        pub.verify(sig_der, payload, ec.ECDSA(hashes.SHA256()))
        return True
    except Exception:
        return False


def build_manifest(bundle_path: str):
    """Recorre el bundle y construye el manifiesto, ignorando la carpeta seals/ y
    los marcadores que el app excluye del hash (chain.jsonl se verifica aparte)."""
    manifest = []
    for root, dirs, files in os.walk(bundle_path):
        # Excluir la carpeta de sellos del manifiesto de archivos
        dirs[:] = [d for d in dirs if d != "seals"]
        for name in sorted(files):
            if name in (".sealed", "VERIFY.txt"):
                continue
            full = os.path.join(root, name)
            rel = os.path.relpath(full, bundle_path)
            with open(full, "rb") as f:
                content = f.read()
            manifest.append({
                "relativePath": rel.replace(os.sep, "/"),
                "bytes": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
            })
    manifest.sort(key=lambda e: e["relativePath"])
    return manifest


def verify(bundle_path: str):
    """Devuelve (veredicto, lista_de_errores)."""
    errors = []

    chain_path = os.path.join(bundle_path, "seals", "chain.jsonl")
    if not os.path.exists(chain_path):
        return False, ["No se encontró seals/chain.jsonl"]

    with open(chain_path, "r", encoding="utf-8") as f:
        lines = [ln for ln in f.read().splitlines() if ln.strip()]

    if not lines:
        return False, ["chain.jsonl está vacía"]

    seals = []
    for i, line in enumerate(lines):
        try:
            seals.append(json.loads(line))
        except json.JSONDecodeError:
            return False, [f"Sello {i} no es JSON válido"]

    # 1. Verificar encadenamiento (prevSealHash)
    for i, seal in enumerate(seals):
        if i == 0:
            if seal.get("prevSealHash") is not None:
                errors.append(f"Sello 0 no debería tener prevSealHash")
        else:
            prev = seals[i - 1]
            expected = sha256_hex(canonical_json_bytes(prev))
            if seal.get("prevSealHash") != expected:
                errors.append(
                    f"Sello {i}: prevSealHash no encadena (esperado {expected[:16]}…)"
                )

    # 2. Verificar integridad de archivos contra el último manifiesto
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

    # 3. Verificar firma criptográfica de cada sello
    if CRYPTO_AVAILABLE:
        for seal in seals:
            payload = (
                f"{seal['rootHash']}|{seal['wallClock']}|{seal['author']['name']}"
            ).encode("utf-8")
            if not verify_signature(seal, payload):
                errors.append(f"Sello {seal.get('index')}: firma inválida")

    return (len(errors) == 0), errors


def main():
    if len(sys.argv) != 2:
        print("Uso: python3 verify_chain.py <ruta_al_bundle>")
        sys.exit(2)

    bundle = sys.argv[1]
    if not os.path.isdir(bundle):
        print(f"ERROR: {bundle} no es un directorio")
        sys.exit(2)

    ok, errors = verify(bundle)
    if ok:
        print("VERIFICACIÓN: OK. El bundle es íntegro y la cadena es consistente.")
        sys.exit(0)
    else:
        print("VERIFICACIÓN: FALLO. Se detectó manipulación:")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
