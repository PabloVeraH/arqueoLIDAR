#!/usr/bin/env python3
"""
preparar_prueba_tercero.py — Arma la prueba de verificación por un tercero
(Fase 17 del plan; guía en docs/prueba_tercero.md).

Toma tres expedientes íntegros y distintos (carpetas FND-… copiadas del
iPhone), los copia como Expediente_A, _B y _C en orden al azar y adultera uno
a propósito. Antes de entregar, comprueba con verify_chain.py que el
adulterado falla y los otros dos pasan. La respuesta queda en un archivo
aparte, solo para quien dirige la prueba.

Uso:
    python3 tools/preparar_prueba_tercero.py FND-1 FND-2 FND-3 [--salida DIR]
                                             [--modo byte|borrar|agregar] [--semilla N]

Modos de adulteración (al azar si no se indica):
    byte     cambia 1 byte de un modelo 3D (mesh.ply)
    borrar   elimina las lecturas GPS de un escaneo (geo.json)
    agregar  agrega un archivo de texto dentro de un escaneo

Requiere el paquete `cryptography` (pip3 install cryptography), para comprobar
también las firmas.

Resultado:
    DIR/PARA_PARTICIPANTE/Expediente_A, _B, _C   ← esto se le entrega
    DIR/CLAVE_SOLO_CONDUCTOR.txt                 ← esto NO
"""

import argparse
import os
import random
import shutil
import stat
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_chain as vc  # noqa: E402

MODOS = ("byte", "borrar", "agregar")
DESCRIPCION = {
    "byte": "se cambió 1 byte del modelo 3D",
    "borrar": "se eliminaron las lecturas GPS",
    "agregar": "se agregó un archivo que no estaba sellado",
}


def hacer_escribible(raiz):
    """Los expedientes sellados vienen de solo lectura (WORM)."""
    for base, dirs, archivos in os.walk(raiz):
        for nombre in dirs + archivos:
            ruta = os.path.join(base, nombre)
            os.chmod(ruta, os.stat(ruta).st_mode | stat.S_IWUSR)
    os.chmod(raiz, os.stat(raiz).st_mode | stat.S_IWUSR)


def archivos_del_manifiesto(expediente, nombre):
    """Rutas relativas del último sello que terminan en `nombre`, ordenadas."""
    with open(os.path.join(expediente, "seals", "chain.jsonl"), "rb") as f:
        lineas = [ln for ln in f.read().split(b"\n") if ln.strip()]
    ultimo = vc.json.loads(lineas[-1].decode("utf-8"))
    return sorted(m["relativePath"] for m in ultimo["manifest"] if m["relativePath"].endswith(nombre))


def adulterar(expediente, modo):
    """Aplica la adulteración y devuelve (modo usado, ruta relativa afectada)."""
    hacer_escribible(expediente)
    if modo == "byte" and archivos_del_manifiesto(expediente, "mesh.ply"):
        rel = archivos_del_manifiesto(expediente, "mesh.ply")[0]
    elif modo == "borrar" and archivos_del_manifiesto(expediente, "geo.json"):
        rel = archivos_del_manifiesto(expediente, "geo.json")[0]
        os.remove(os.path.join(expediente, rel))
        return modo, rel
    elif modo == "agregar":
        escaneos = archivos_del_manifiesto(expediente, "scan.json")
        carpeta = os.path.dirname(escaneos[0]) if escaneos else ""
        rel = os.path.join(carpeta, "notas_campo.txt").replace(os.sep, "/")
        with open(os.path.join(expediente, rel), "w", encoding="utf-8") as f:
            f.write("Corrección posterior al sellado.\n")
        return modo, rel
    else:
        # Sin el archivo pedido: cambiar 1 byte del primer archivo sellado.
        modo, rel = "byte", archivos_del_manifiesto(expediente, "")[0]
    ruta = os.path.join(expediente, rel)
    antes = os.stat(ruta)
    with open(ruta, "r+b") as f:
        f.seek(antes.st_size // 2)
        b = f.read(1) or b"\0"
        f.seek(antes.st_size // 2)
        f.write(bytes([b[0] ^ 0x01]))
    # Misma fecha de modificación: que no se delate por la fecha, solo por la verificación.
    os.utime(ruta, (antes.st_atime, antes.st_mtime))
    return modo, rel


def preparar(fuentes, salida, modo=None, semilla=None):
    """Arma la prueba. Devuelve (letra adulterada, modo, ruta, errores esperados)."""
    if len(fuentes) != 3:
        raise SystemExit("Se necesitan exactamente 3 expedientes.")
    raices = set()
    for f in fuentes:
        ok, firmas, errores, _ = vc.verify(f)
        if not ok:
            raise SystemExit(f"{f} no está íntegro; usa expedientes que verifiquen OK:\n  " + "\n  ".join(errores))
        if not firmas:
            raise SystemExit("Falta el paquete 'cryptography' (pip3 install cryptography).")
        with open(os.path.join(f, "seals", "chain.jsonl"), "rb") as h:
            raices.add(vc.json.loads([ln for ln in h.read().split(b"\n") if ln.strip()][-1])["rootHash"])
    if len(raices) != 3:
        raise SystemExit("Dos de los expedientes son el mismo: usa tres distintos, si no se delatan al compararlos.")
    if os.path.exists(salida) and os.listdir(salida):
        raise SystemExit(f"{salida} ya existe y no está vacía.")

    rng = random.Random(semilla)
    orden = list(fuentes)
    rng.shuffle(orden)
    letras = "ABC"
    victima = rng.randrange(3)
    modo = modo or rng.choice(MODOS)

    destino = os.path.join(salida, "PARA_PARTICIPANTE")
    copias = []
    for letra, fuente in zip(letras, orden):
        copia = os.path.join(destino, f"Expediente_{letra}")
        shutil.copytree(fuente, copia)
        copias.append(copia)
    modo, rel = adulterar(copias[victima], modo)

    # Autocomprobación: solo el adulterado debe fallar.
    resultados = [vc.verify(c) for c in copias]
    for i, (ok, _, errores, _) in enumerate(resultados):
        if ok == (i == victima):
            for c in copias:
                hacer_escribible(c)
            shutil.rmtree(salida, ignore_errors=True)
            raise SystemExit(f"La autocomprobación falló en Expediente_{letras[i]}: {errores}")

    errores = resultados[victima][2]
    with open(os.path.join(salida, "CLAVE_SOLO_CONDUCTOR.txt"), "w", encoding="utf-8") as f:
        f.write(f"PRUEBA DE VERIFICACIÓN POR UN TERCERO — {datetime.now():%Y-%m-%d %H:%M}\n")
        f.write("NO entregar este archivo al participante.\n\n")
        f.write(f"Expediente adulterado: {letras[victima]}\n")
        f.write(f"Qué se hizo: {DESCRIPCION[modo]} ({rel})\n\n")
        f.write("Lo que debería encontrar el participante con verify_chain.py:\n")
        f.writelines(f"  - {e}\n" for e in errores)
        f.write("\nOrigen de cada copia:\n")
        f.writelines(f"  Expediente_{l}: {os.path.abspath(s)}\n" for l, s in zip(letras, orden))
    return letras[victima], modo, rel, errores


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("expedientes", nargs=3, help="tres carpetas FND-… íntegras y distintas")
    p.add_argument("--salida", default=f"prueba_tercero_{datetime.now():%Y%m%d_%H%M}")
    p.add_argument("--modo", choices=MODOS)
    p.add_argument("--semilla", type=int)
    a = p.parse_args()
    letra, modo, rel, _ = preparar(a.expedientes, a.salida, a.modo, a.semilla)
    print(f"Listo en {a.salida}/")
    print("  Entregar: PARA_PARTICIPANTE/ (Expediente_A, _B, _C)")
    print("  Guardar aparte: CLAVE_SOLO_CONDUCTOR.txt (dice cuál es el adulterado)")
    print("Autocomprobación OK: el adulterado falla y los otros dos verifican.")


if __name__ == "__main__":
    main()
