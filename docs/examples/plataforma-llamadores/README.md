# Ejemplo: reconstruir historia de Plataforma Llamadores en Teamwork

Este ejemplo muestra cómo se cargaron en Teamwork los 4 meses de historia de los repos `VideoRepository` y `LlamadorNew` (136 commits) como un proyecto retrospectivo.

Ejecutado el 2026-04-27. Resultado:
- Proyecto **Plataforma Llamadores** (id `1271590`) en categoría `PLATAFORMA LLAMADORES` (id `51078`).
- 21 task lists temáticas (Fundación, TTS, Multi-TV, Watchdog, etc.).
- 40 tickets cerrados, todos asignados a Diego (id `677620`).
- 40 time entries con rúbrica conservadora (105.5 h totales, ~2.1 h/día sobre 50 días hábiles).

## Archivos

| Archivo | Qué hace |
|---------|----------|
| `tickets-manifest.json` | 39 tickets (T2-T40) con tasklist, título, fechas, summary y commits asociados. T1 se cargó manualmente antes (ver script). |
| `create-tickets.sh` | Itera el manifiesto. Para cada ticket: garantiza la tasklist (cache en memoria), crea task con descripción, marca completed. |
| `log-time.sh` | Carga 1 time entry por ticket usando rúbrica conservadora B (max 8 h por ticket) en el mid-point de su rango. |

## Pasos resumidos

1. **Relevamiento**: explorar la cuenta Teamwork (categorías, equipo, proyectos existentes), saneamiento previo (archivar proyectos abandonados, crear categorías necesarias).
2. **Análisis de git**: `git log --reverse --pretty=format:"%ad|%h|%s" --date=short` en cada repo. Agrupar commits semánticamente en tickets (no 1:1 — un ticket es una unidad de valor, no un commit).
3. **Crear proyecto + categoría**: `tw_create_category`, `tw_post_v1 /projects.json` (sin `start-date` solo, requiere también `end-date`).
4. **Bulk de tickets**: `create-tickets.sh` → ~3 calls/ticket (tasklist + create + complete).
5. **Validar rúbrica de horas con el usuario** antes de cargar tiempo. La rúbrica que aplicamos:
   - 1 commit, fix simple → 30 min
   - 1 commit, feature → 60 min
   - 2-3 commits → 2 h
   - 4-5 commits → 3 h
   - 6-9 commits → 5 h
   - 10+ commits → 8 h
6. **Cargar time entries**: `log-time.sh` → 1 call/ticket.

## Lecciones aprendidas (incorporadas al cliente y al README principal)

- DELETE en bash loops contra Teamwork con lista pre-fetchada **falla a partir del 2do** (HTTP 000). Workaround: traer un ID por iteración del API.
- Rate limit visible en header `x-ratelimit-limit: 150 / 60s`.
- Encoding UTF-8: bodies con acentos requieren `--data-binary @tmpfile` y `Content-Type: charset=utf-8`. El cliente lo hace automáticamente.
- Post-creación, las tasklists con todas las tasks completed se ocultan de los listings — no hay parámetro de la API que las traiga de vuelta. Si se quiere iterar, mantener cache local de IDs.

## Variables y constantes usadas

```bash
PROJECT_ID=1271590           # Plataforma Llamadores
ASSIGNEE_ID=677620           # Diego
CATEGORY_ID=51078            # PLATAFORMA LLAMADORES (creada acá)

# Categorías nuevas creadas durante el saneamiento previo:
GESTION_INTERNA_CAT=51077    # Para Mejoras y Cambios, Mesa de entrada, Reuniones
PLATAFORMA_LLAMADORES_CAT=51078
```

Para reusar el patrón con otro repo, copiar este directorio, editar el manifest y los IDs, y correr.
