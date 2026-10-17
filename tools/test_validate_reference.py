#!/usr/bin/env python3
"""Prueba de validate_reference.py.  Uso: python3 tools/test_validate_reference.py"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import validate_reference as vr  # noqa: E402


def main():
    filas = "fecha,commit,magnitud,condicion,referencia,medido,unidad,distancia_m,material,notas\n"
    # Caja de 0,060 m³ medida 5 veces a la sombra con sesgo +2 L.
    for medido in (0.061, 0.062, 0.063, 0.062, 0.062):
        filas += f"2026-10-20,abc,volumen_positivo,sombra,0.060,{medido},m3,1.5,carton,\n"
    for medido in (0.0004, -0.0007, 0.0002):
        filas += f"2026-10-20,abc,ensayo_nulo,sombra,0,{medido},m3,1.5,arena,\n"
    ruta = os.path.join(tempfile.mkdtemp(), "log.csv")
    with open(ruta, "w", encoding="utf-8") as f:
        f.write(filas)

    res = {(r["magnitud"], r["condicion"]): r for r in vr.resumir(vr.leer(ruta))}
    caja, nulo = res[("volumen_positivo", "sombra")], res[("ensayo_nulo", "sombra")]
    checks = [
        ("sesgo de la caja ≈ +0,002 m³", abs(caja["sesgo"] - 0.002) < 1e-9),
        ("5 corridas a la sombra bastan", caja["estado"] == "OK"),
        ("al sol no hay datos", res[("volumen_positivo", "sol")]["estado"] == "sin datos"),
        ("piso de ruido = mayor cambio falso", abs(nulo["piso_ruido"] - 0.0007) < 1e-12),
        ("ensayo nulo con 3/5 incompleto", nulo["estado"] == "faltan 2"),
        ("tabla dice incompleta", "incompleta" in vr.tabla(vr.resumir(vr.leer(ruta)))),
    ]
    doc = os.path.join(tempfile.mkdtemp(), "V.md")
    with open(doc, "w", encoding="utf-8") as f:
        f.write("antes\n<!-- resumen -->\nviejo\n<!-- /resumen -->\ndespués\n")
    vr.escribir(doc, "nuevo")
    with open(doc, encoding="utf-8") as f:
        checks.append(("escribe solo dentro del bloque", f.read() == "antes\n<!-- resumen -->\nnuevo\n<!-- /resumen -->\ndespués\n"))

    for nombre, ok in checks:
        print(("OK   " if ok else "FALLO"), nombre)
    sys.exit(0 if all(ok for _, ok in checks) else 1)


if __name__ == "__main__":
    main()
