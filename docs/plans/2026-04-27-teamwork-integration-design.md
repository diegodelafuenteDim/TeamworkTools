# Diseño — Integración Claude Code ↔ Teamwork

**Fecha:** 2026-04-27
**Autor:** Diego De La Fuente (responsable del sector de desarrollo)
**Estado:** Aprobado en sesión de brainstorming. Estructura + cliente HTTP implementados; skill, agente y rutinas pendientes.

## Contexto

DIM Centros de Salud usa Teamwork (`dimcentrosdesalud.teamwork.com`) para gestionar tickets del sector de desarrollo. Diego es responsable de un equipo de 12 personas y necesita:

1. Operar Teamwork (listar / crear / actualizar tickets, cargar horas) desde Claude Code, sin abandonar la terminal.
2. Hacer queries en lenguaje natural sobre el equipo y los proyectos ("qué hizo Juan esta semana", "tickets bloqueados de Agenda Médicos").
3. Recibir reportes recurrentes generados solos:
   - Resumen semanal del equipo (cada lunes 8:00 AM).
   - WIP diario del equipo.
   - Sus tickets del día (los del responsable).

## Hallazgos del relevamiento

| Hallazgo | Implicancia |
|----------|-------------|
| 23 personas en Teamwork, **12 son del equipo** de desarrollo | Filtrar por lista explícita de IDs en `config/equipo.json` |
| Infra (4 personas) **no usa Teamwork** — sólo Martin Rzeszut tiene cuenta | Excluir categoría `SOPORTES INFRA` y a Martin |
| 41 proyectos `active` originalmente — ninguno archivado/completado | Saneamiento manual previo |
| Tag `sector-desarrollo` aplicado a 0 proyectos en realidad — la API lo ignora | No usar tags de proyecto para filtrar |
| Tag de tareas casi sin uso (3 abiertas con `sector-desarrollo`) | No usar tags de tarea para filtrar |
| 22 categorías de proyecto activas, casi todas son IT | Filtrar por categoría es la vía correcta |
| 7 proyectos sin categoría — 3 activos en uso, 4 abandonados | Categorizar los 3 (creada `GESTION INTERNA`), archivar los 4 |
| 658 tareas abiertas asignadas al responsable | Definir filtros útiles (no listar las 658) |
| API tiene varios bugs/rarezas (ver README) | Encapsular en cliente |

## Decisiones de diseño

### Arquitectura: 3 capas

```
~/.claude/skills/teamwork → c:\Net 8\TeamworkTools\skill\
~/.claude/agents/teamwork.md → c:\Net 8\TeamworkTools\agent\teamwork-agent.md

Capa 1 — Skill /teamwork           Capa 2 — Subagente              Capa 3 — Scheduled
  Sub-comandos deterministas:        Queries en NL                  Cron jobs:
   list, mis-tickets, create,         "qué tickets bloqueó X"        reporte-semanal (lun 8:00)
   update, log-time, reporte,         "comparar horas Juan/Pedro"    wip-diario (8:00)
   equipo, sanear                                                    mis-tickets-hoy (8:00)
```

Cada capa juega un rol distinto:
- **Skill**: barata, predecible, para acciones rutinarias.
- **Subagente**: razona qué endpoints llamar para queries no anticipadas.
- **Scheduled**: corre solo, sin intervención.

### Stack

- **Bash + curl + jq**, mismo stack que los skills `deploy-docker` y `subir-cambios` del repo VideoRepository.
- jq instalado vía winget (1 MB, una sola vez).
- Sin Python ni Node — todo shell.

### Repo dedicado

`c:\Net 8\TeamworkTools\` con git propio, vinculado a `~/.claude/skills/` y `~/.claude/agents/` por symlinks. Beneficios:
- Editás en un lugar, se ve desde cualquier proyecto.
- Versionado e historizable.
- Compartible con el equipo (eventualmente).

### Filtrado IT

Por **categoría + override JSON**, no por tag (porque los tags no funcionan para filtrar proyectos vía API):

```
scope_IT = (categoriasIncluidas ∪ proyectosIncluirSiempre)
           − categoriasExcluidas
           − proyectosExcluirSiempre
           ∩ status=active
```

Implementado en `tw_get_scope_proyectos_it` (lib/tw-client.sh).

### Reportes recurrentes (Fase 1 — A + B + D)

| Reporte | Cadencia | Salida |
|---------|----------|--------|
| **Resumen semanal del equipo** (tickets cerrados/abiertos, horas por persona/proyecto, semana pasada) | Lun 8:00 AM | `reports/YYYY-MM-DD/semanal-equipo.md` |
| **WIP del equipo** (qué tiene cada uno en curso, sin actualizar +N días, bloqueados) | Diario 8:00 AM | `reports/YYYY-MM-DD/wip.md` |
| **Mis tickets del día** (responsable: asignados, creados, en review) | Diario 8:00 AM | `reports/YYYY-MM-DD/mis-tickets.md` |

Postergados a Fase 2 según el feedback de uso real:
- C: Tickets vencidos / próximos a vencer.
- E: Tiempo cargado vs estimado.
- F: Higiene de backlog (tickets sin estimación / sin asignar / sin due date).
- G: Productividad por persona del último mes.

## Acciones de saneamiento ya aplicadas

- **Categoría nueva** `GESTION INTERNA` (id 51077) creada vía API.
- **3 proyectos** asignados a esa categoría (Mejoras y Cambios, Mesa de entrada, Reuniones y tareas de equipo).
- **4 proyectos archivados** (Análisis nuevos proyectos, Ejemplo/Pruebas, Gant General, Reclamos y Automatizaciones).

Estado final: 37 activos / 14 archivados / 1 deleted, con scope IT de 35 proyectos.

## Pendiente (en orden de implementación)

1. ✅ Repo + estructura de carpetas
2. ✅ `lib/tw-client.sh` con auth, paginación y funciones de scope/equipo
3. Implementar `lib/tw-reports.sh` con funciones de agregación
4. Implementar `skill/SKILL.md` con sub-comandos (empezando por `mis-tickets`, `equipo`, `list`)
5. Implementar `agent/teamwork-agent.md` (subagente NL)
6. Implementar las 3 rutinas en `scheduled/`
7. Crear los symlinks
8. Probar end-to-end y commitear
9. Decidir definición útil de "mis tickets" (filtro: en progreso / actualizados últimos N días / agrupados por proyecto / etc.)

## Riesgos / preguntas abiertas

- **Definición de "mis tickets"**: 658 abiertos asignados al responsable es demasiado. Hay que decidir el criterio útil (sugerencias: status=in_progress + actualizado <14 días, o agrupados por proyecto con conteo).
- **Jessica Degiovanni** crea muchos tickets que el equipo resuelve, pero no es del equipo. Sus tickets cuentan como "trabajo del equipo" en reportes de volumen pero no como "carga de Jessica". Documentado en `equipo.json`.
- **Si Infra empieza a usar Teamwork** en el futuro, hay que sumar la categoría SOPORTES INFRA y los IDs faltantes al config.
