#!/usr/bin/env python3
"""
Prueba de preparar_prueba_tercero.py: en cada modo, exactamente un expediente
queda adulterado, la clave lo nombra y los otros dos siguen verificando.

Uso:  python3 tools/test_preparar_prueba_tercero.py   (requiere `pip install cryptography`)
"""

import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import preparar_prueba_tercero as pp  # noqa: E402
import test_verify_chain as tv  # noqa: E402
import verify_chain as vc  # noqa: E402


def expediente(contenido):
    """Expediente sellado sintético con un escaneo (mesh.ply, geo.json, scan.json)."""
    b = tv.make_bundle()
    for nombre, datos in (("geo.json", b"[]"), ("scan.json", contenido)):
        with open(os.path.join(b, "scans", "s", nombre), "wb") as f:
            f.write(datos)
    tv.write_chain(b, tv.chain(b, [tv.Key()]))
    return b


def main():
    fuentes = [expediente(f"escaneo {i}".encode()) for i in range(3)]
    todo_ok = True
    for semilla, modo in enumerate(pp.MODOS):
        salida = tempfile.mkdtemp(prefix="prueba-tercero-")
        os.rmdir(salida)  # preparar exige que no exista o esté vacía
        letra, usado, rel, _ = pp.preparar(fuentes, salida, modo, semilla)
        resultados = {l: vc.verify(os.path.join(salida, "PARA_PARTICIPANTE", f"Expediente_{l}"))[0] for l in "ABC"}
        with open(os.path.join(salida, "CLAVE_SOLO_CONDUCTOR.txt"), encoding="utf-8") as f:
            clave = f.read()
        ok = (usado == modo and [l for l, v in resultados.items() if not v] == [letra]
              and f"Expediente adulterado: {letra}" in clave)
        print(("OK   " if ok else "FALLO"), f"modo {modo}: adulterado {letra} ({rel})", "" if ok else resultados)
        todo_ok &= ok
        shutil.rmtree(salida, ignore_errors=True)

    try:
        pp.preparar([fuentes[0], fuentes[0], fuentes[1]], tempfile.mkdtemp())
        print("FALLO expedientes repetidos deberían rechazarse")
        todo_ok = False
    except SystemExit:
        print("OK    expedientes repetidos se rechazan")
    sys.exit(0 if todo_ok else 1)


if __name__ == "__main__":
    main()
