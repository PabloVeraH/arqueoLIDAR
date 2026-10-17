#!/usr/bin/env python3
"""
Pruebas de verify_chain.py para la firma v2 y la rotación de clave
(mismos casos que SealV2Tests en CustodyTests.swift).

Uso:  python3 tools/test_verify_chain.py      (requiere `pip install cryptography`)
Sale con 0 si todo pasa.
"""

import base64
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_chain as vc  # noqa: E402

from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402


class Key:
    def __init__(self):
        self.priv = ec.generate_private_key(ec.SECP256R1())
        der = self.priv.public_key().public_bytes(serialization.Encoding.DER,
                                                  serialization.PublicFormat.SubjectPublicKeyInfo)
        self.der_b64 = base64.b64encode(der).decode()
        self.key_id = vc.sha256_hex(der)[:16]

    def sign(self, seal):
        sig = self.priv.sign(vc.signed_payload(seal), ec.ECDSA(hashes.SHA256()))
        seal["signatureDER"] = base64.b64encode(sig).decode()
        return seal


def make_bundle():
    d = tempfile.mkdtemp(prefix="vc-test-")
    os.makedirs(os.path.join(d, "scans", "s"))
    os.makedirs(os.path.join(d, "seals"))
    with open(os.path.join(d, "scans", "s", "mesh.ply"), "wb") as f:
        f.write(b"mesh")
    return d


def new_seal(bundle, key, prev_seal=None, prev_line=None, version=2, ms_offset=0):
    """Como SealSigner.seal: declara previousKeyID si la clave cambió."""
    manifest = vc.build_manifest(bundle)
    seal = {
        "index": 0 if prev_seal is None else prev_seal["index"] + 1,
        "rootHash": vc.compute_root_hash(manifest),
        "manifest": manifest,
        "author": {"name": "A|B", "role": "R", "institution": "I"},
        "deviceKeyID": key.key_id,
        "publicKeyDER": key.der_b64,
        "wallClock": f"2026-10-17T12:00:0{ms_offset}.123Z",
    }
    if prev_line is not None:
        seal["prevSealHash"] = vc.sha256_hex(prev_line)
    if version == 2:
        seal["signatureVersion"] = 2
        seal["keyProtection"] = "software"
        if prev_seal is not None and prev_seal["deviceKeyID"] != key.key_id:
            seal["previousKeyID"] = prev_seal["deviceKeyID"]
    return key.sign(seal)


def write_chain(bundle, seals):
    lines = [vc.canonical_json_bytes(s) for s in seals]
    with open(os.path.join(bundle, "seals", "chain.jsonl"), "wb") as f:
        f.write(b"\n".join(lines) + b"\n")
    return lines


def chain(bundle, keys, versions=None):
    """Cadena de sellos: uno por clave en `keys`."""
    seals, line = [], None
    for i, key in enumerate(keys):
        v = versions[i] if versions else 2
        s = new_seal(bundle, key, seals[-1] if seals else None, line, version=v, ms_offset=i)
        seals.append(s)
        line = vc.canonical_json_bytes(s)
    return seals


def check(name, bundle, expect_ok, needle=None):
    ok, sigs, errors, _ = vc.verify(bundle)
    passed = (ok and sigs) if expect_ok else (not ok and (needle is None or any(needle in e for e in errors)))
    print(("OK   " if passed else "FALLO"), name, "" if passed else errors)
    return passed


def main():
    results = []
    k1, k2 = Key(), Key()

    b = make_bundle()
    write_chain(b, chain(b, [k1, k1]))
    results.append(check("v2 íntegro", b, True))

    b = make_bundle()
    write_chain(b, chain(b, [k1], versions=[1]))
    results.append(check("v1 antiguo sigue verificando", b, True))

    b = make_bundle()
    s0, s1, s2 = chain(b, [k1, k1, k1])
    s2["index"] = 1
    s2["prevSealHash"] = vc.sha256_hex(vc.canonical_json_bytes(s0))
    write_chain(b, [s0, s2])
    results.append(check("borrar sello intermedio y corregir prevSealHash", b, False, "firma inválida"))

    b = make_bundle()
    seals = chain(b, [k1, k2, k2])
    assert seals[1]["previousKeyID"] == k1.key_id and "previousKeyID" not in seals[2]
    write_chain(b, seals)
    results.append(check("rotación declarada", b, True))

    b = make_bundle()
    s0, s1 = chain(b, [k1, k2])
    del s1["previousKeyID"]
    k2.sign(s1)
    write_chain(b, [s0, s1])
    results.append(check("rotación no declarada", b, False, "no declarado"))

    b = make_bundle()
    write_chain(b, chain(b, [k1, k1], versions=[2, 1]))
    results.append(check("v1 después de v2", b, False, "v1 después de uno v2"))

    b = make_bundle()
    s0 = chain(b, [k1])[0]
    s0["deviceKeyID"] = "0" * 16
    k1.sign(s0)
    write_chain(b, [s0])
    results.append(check("keyID falsa", b, False, "keyID no corresponde"))

    # La app copia este script a seals/ de cada expediente (VERIFY.txt, nivel B):
    # su copia empaquetada tiene que ser idéntica, y correr desde seals/ no
    # debe contar como archivo del expediente.
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "verify_chain.py"), "rb") as f:
        original = f.read()
    with open(os.path.join(here, "..", "arqueoLidar", "Resources", "verify_chain.py"), "rb") as f:
        same = f.read() == original
    print(("OK   " if same else "FALLO"), "copia de la app idéntica a tools/verify_chain.py")
    results.append(same)
    b = make_bundle()
    write_chain(b, chain(b, [k1]))
    with open(os.path.join(b, "seals", "verify_chain.py"), "wb") as f:
        f.write(original)
    results.append(check("copia dentro de seals/ no altera el expediente", b, True))

    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
