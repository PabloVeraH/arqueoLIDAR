# Prompt para el asistente en la Mac

Para quien tenga una Mac y un iPhone Pro: copia el bloque de abajo y pégalo en el
asistente de código, abierto en la carpeta del repo `arqueoLIDAR`. Las tareas concretas
no van aquí: están en `docs/pendientes_mac.md`, que se va llenando desde Windows.

```
Trabajas en el repo arqueoLIDAR (app iOS PaleoRegistro), en la rama de trabajo actual.
Lee primero AGENTS.md y síguelo: varias personas trabajan en esta rama.

1. Sincroniza (AGENTS.md §1): commit de tus cambios locales, git fetch, git pull
   --no-rebase. Nunca push --force.
2. Lee docs/pendientes_mac.md y haz sus tareas pendientes en orden. No des nada por
   bueno sin compilar y, si la tarea lo pide, sin probar en el iPhone.
3. Si algo falla, arréglalo en la causa raíz con el cambio mínimo y agrega un test si
   es del paquete PaleoRegistro. No reviertas las decisiones de AGENTS.md §3.
4. Anota los resultados con números en docs/registro_pruebas.md y mueve cada tarea
   resuelta a "Resueltas" en docs/pendientes_mac.md, en el mismo commit.
5. Commits pequeños en español. git fetch antes de subir; push sin force.
6. Entrega un resumen: qué compiló a la primera, qué corregiste y por qué, el resultado
   de cada tarea y qué queda pendiente.
```
