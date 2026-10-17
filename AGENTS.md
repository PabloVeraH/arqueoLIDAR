# Instrucciones para agentes (LLM)

Dos personas trabajan en paralelo sobre la misma rama (`feat/arreglosEsteban`), cada una
con su propio asistente. Sigue esto **siempre, antes de escribir código**.

## 1. Sincronizar con el remoto antes de empezar

1. `git status`. Si hay cambios locales sin commitear, haz commit (o `git stash`) antes de
   seguir. Nunca los descartes.
2. `git fetch origin` y compara: `git log --oneline HEAD..origin/<rama-actual>`.
3. Si hay commits nuevos: `git pull --no-rebase`. Resuelve los conflictos integrando ambos
   lados; nunca hagas `push --force` ni descartes el trabajo de la otra persona.
4. Lee los commits nuevos (`git log -p HEAD@{1}..HEAD` o `git show <sha>`) para saber qué
   cambió.

## 1b. ¿Dónde estás corriendo? (Mac vs. Windows)

Algunas tareas solo se pueden hacer en una Mac: compilar con Xcode o `swift`, correr
`swift test`, instalar en el iPhone y probar ARKit, LiDAR, Face ID o el chip seguro. La cola
de esas tareas es `docs/pendientes_mac.md`. Es distinta de `docs/faltantes.md`, que tiene
los pendientes generales de la app.

Comprueba el sistema operativo (`uname -s`, o la plataforma que te informa tu entorno):

- **macOS (`Darwin`):** después de sincronizar, **lee primero `docs/pendientes_mac.md`** y
  haz sus tareas pendientes en orden, antes de lo que te pidieron (salvo que el usuario
  diga otra cosa). Cuando resuelvas una, muévela a "Resueltas" en ese archivo, en el mismo
  commit que el arreglo. Los resultados con números van a `docs/registro_pruebas.md`.
- **Windows o Linux:** si escribes o cambias algo que no puedes compilar ni probar aquí
  (código de la app iOS, frameworks de Apple, el paquete Swift sin toolchain), agrega
  una tarea a `docs/pendientes_mac.md` en el mismo commit. Pon qué cambió, en qué commit
  y cómo se sabe que está bien. Al tomar una decisión de programación que solo se
  valida en Mac o iPhone, déjala anotada ahí. Nunca la marques como probada.

## 2. ¿Lo que te pidieron ya viene hecho?

Antes de implementar la tarea, busca si los commits recién bajados (o el código actual)
ya la resuelven, total o parcialmente: revisa los mensajes de commit, `git log -S<símbolo>`
y `grep` de los nombres o textos relevantes.

- **No está:** impleméntala.
- **Ya está:** no la reimplementes. Analiza si está bien hecha:
  - ¿Resuelve la causa raíz o solo el síntoma? ¿Cubre todos los llamadores?
  - ¿Respeta las decisiones del proyecto (abajo) y el estilo del código que la rodea?
  - ¿Compila y pasan los tests (`cd PaleoRegistro && swift build && swift test`)?
  - ¿Tiene casos borde sin cubrir o falta un test?

  Informa al usuario qué encontraste antes de tocar nada. Si hay un problema concreto,
  propón el cambio mínimo sobre la implementación existente; no la reemplaces por la tuya.
- **Está a medias:** complétala sobre lo existente.

## 3. Decisiones del proyecto que no se revierten sin una razón verificada

- La evidencia sellada no se borra: solo se pueden eliminar expedientes que **no**
  verifican como íntegros (`FieldStore.deleteIfNotIntact`).
- Las exportaciones van a `Documents/Exports/FND-…/`, **fuera** del expediente sellado.
  Cualquier archivo nuevo dentro del bundle rompe la verificación.
- `.sealed` de cada escaneo se escribe **antes** de sellar.
- `Hasher.buildManifest` usa `enumerator(atPath:)` (rutas relativas; arregla
  `/var` vs `/private/var` en iOS).
- El usuario final ve solo funciones de terreno (Sitios → Hallazgos → Captura → Visor/Exportar/Verificar).
  Las librerías internas no se muestran en la app: la pestaña Diagnóstico existe solo en `#if DEBUG`
  (`ArqueoLidarApp.swift`). No agregues pantallas que expongan módulos o términos internos.
- Solo `Rendering/` importa SceneKit. Target de la app: Swift 5 mode con
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; los tipos auxiliares son `nonisolated`.

## 4. Al terminar

- Vuelve a hacer `git fetch` antes del push; si la otra persona subió algo mientras
  trabajabas, haz pull e integra antes de subir.
- Commits pequeños en español (`fix(app): …`, `feat(custody): …`).
- Si cambia lo que la app hace, actualiza `docs/informe_general.md` (tono para un
  arqueólogo o paleontólogo sin conocimientos técnicos) y anota pruebas pendientes en
  `docs/registro_pruebas.md`.
