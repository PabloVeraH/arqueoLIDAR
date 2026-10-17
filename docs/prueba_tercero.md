# Prueba de verificación por un tercero (Fase 17)

Guía para quien **dirige** la prueba. El participante nunca ve este documento.

## Qué se prueba

Que una persona ajena al proyecto, en un computador **sin la app**, pueda comprobar si
un expediente fue alterado **siguiendo solo `VERIFY.txt`**. Ante el CMN o un tribunal,
la cadena de custodia vale lo que vale que **otro** la pueda comprobar.

**Se aprueba si**, sin ayuda y en **menos de 15 minutos**, el participante:

1. dice correctamente cuál de los tres expedientes fue alterado, y
2. dice que los otros dos están íntegros.

Si tuvo que preguntar algo o se quedó trabado, la prueba **no se aprueba**: `VERIFY.txt`
está incompleto y hay que corregirlo (ver "Después de la prueba").

## Qué se necesita

- **Tres expedientes reales y distintos**, sellados con la app, cada uno con al menos
  un escaneo, copiados del iPhone a la Mac (Archivos → En mi iPhone → ArqueoLiDAR →
  Findings). Tienen que ser distintos: si fueran copias del mismo, el participante
  podría encontrar el alterado comparándolos, sin verificar nada.
- **Un computador para el participante**, idealmente una Mac (trae `shasum` y Python),
  con internet para instalar la librería de firmas. En Windows no existe `shasum`, así
  que el nivel A de `VERIFY.txt` no funciona tal cual; solo sirve el nivel B.
- **El participante**: alguien ajeno al proyecto, idealmente arqueólogo, paleontólogo o
  abogado, sin conocimientos de programación. No se le explica nada antes.
- Un reloj y esta guía impresa (o abierta en otro equipo).

## Preparar (en la Mac, el día antes)

```bash
pip3 install cryptography
python3 tools/preparar_prueba_tercero.py RUTA/FND-AAAA RUTA/FND-BBBB RUTA/FND-CCCC
```

El script:

- comprueba que los tres expedientes estén íntegros y sean distintos;
- los copia como `Expediente_A`, `_B` y `_C`, en un orden al azar;
- **altera uno** a propósito (cambia 1 byte de un modelo 3D, borra las lecturas GPS de
  un escaneo, o agrega un archivo no sellado);
- comprueba que el alterado falle y los otros dos pasen.

Al final queda una carpeta `prueba_tercero_<fecha>/` con:

- `PARA_PARTICIPANTE/`: **esto se le entrega** (por pendrive o AirDrop).
- `CLAVE_SOLO_CONDUCTOR.txt`: dice cuál es el alterado y qué se le hizo. **No se entrega.**

Si quiere probar un caso en particular, agregue `--modo byte`, `--modo borrar` o
`--modo agregar`. El modo `agregar` es el más exigente: la revisión rápida (nivel A)
**no** lo detecta, y solo lo encuentra quien hace la verificación completa (nivel B).

## Durante la prueba

1. Copie `PARA_PARTICIPANTE/` al escritorio del computador del participante.
2. Lea la consigna en voz alta, tal cual:

   > "Te entrego tres expedientes digitales: A, B y C. Usando **solo** las instrucciones
   > del archivo `VERIFY.txt` que está dentro de cada uno, dime para cada expediente si
   > está íntegro o si fue alterado. No puedo responder preguntas. Tienes 15 minutos."

3. Anote la hora de inicio. **No ayude**, ni con gestos. Si el participante pregunta,
   responda "sigue lo que dice `VERIFY.txt`" y **anote la pregunta tal cual**: es el
   dato más valioso de la prueba.
4. Anote dónde se trabó y qué nivel usó (A: `shasum`, B: `verify_chain.py`).
5. Cuando entregue su respuesta (o a los 15 minutos), anote la hora y lo que dijo de cada
   expediente.

## Registro (copiar en `docs/registro_pruebas.md`)

| Campo | Valor |
|---|---|
| Fecha | |
| Participante (rol, sin nombre) | |
| Computador (Mac / Linux / Windows) | |
| Modo de alteración (de la clave) | |
| Expediente alterado (de la clave) | |
| Respuesta: A / B / C | íntegro o alterado, para cada uno |
| Tiempo total | min |
| Nivel usado | A, B o ambos |
| Preguntas que quiso hacer | textuales |
| Dónde se trabó | |
| **Resultado** | Aprobado / No aprobado |

## Después de la prueba

- **No aprobado:** cada pregunta o traba es un hueco de `VERIFY.txt`. El texto vive en
  `PaleoRegistro/Sources/Persistence/BundleWriter.swift` (`VerifyTemplate`). Corríjalo,
  anote el cambio en `docs/pendientes_mac.md` (hay que compilar y volver a sellar para
  que los expedientes nuevos traigan el texto nuevo) y repita con **otra persona**: la
  misma ya sabe cómo se hace.
- **Aprobado:** marque la prueba como hecha en `docs/faltantes.md`. Conviene repetirla
  al menos una vez con el modo `agregar`, que es el más difícil.
