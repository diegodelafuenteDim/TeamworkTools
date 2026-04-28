---
description: Commit y push de cambios pendientes en el repo TeamworkTools. Analiza cambios, genera commit message, pide aprobación y sube a git. Usar cuando el usuario pida subir cambios, commitear, pushear o ver si hay algo por subir.
---

# Subir Cambios a Git — TeamworkTools

Skill para commit + push de cambios pendientes en el repo `c:/Net 8/TeamworkTools`.

**IMPORTANTE**: Este skill es la única forma autorizada de ejecutar comandos git de escritura en este repo. Fuera de este skill, `git add` / `git commit` / `git push` están prohibidos.

## Repositorio

| Propiedad | Valor |
|-----------|-------|
| Path | `c:/Net 8/TeamworkTools` |
| Branch principal | `master` |
| Remote | Verificar con `git remote -v` (puede no existir aún) |

Si todavía no hay remote, este skill ofrece crearlo (ver Fase 0b).

## Procedimiento (orden estricto)

### Fase 0: Sincronizar con remoto — si existe

Ejecutar SIN pedir permiso (es solo lectura):

```bash
git -C "c:/Net 8/TeamworkTools" remote -v
```

**Si NO hay remote configurado**: saltar a Fase 0b.

**Si hay remote**:

```bash
git -C "c:/Net 8/TeamworkTools" fetch origin

# Commits remotos que no tenemos localmente (necesitan pull):
git -C "c:/Net 8/TeamworkTools" log HEAD..origin/master --oneline

# Commits locales no pusheados (necesitan push):
git -C "c:/Net 8/TeamworkTools" log origin/master..HEAD --oneline
```

- Si hay commits remotos: ejecutar `git pull --rebase origin master`. Si hay conflictos, informar al usuario y pedir instrucciones.
- Si hay commits locales no pusheados: incluirlos en la Fase 4 aunque no haya cambios nuevos.

### Fase 0b: Sin remote — ofrecer configurar

Si `git remote -v` no devuelve nada, informar al usuario:

```
No hay remote configurado en este repo. Opciones:
  (a) Crear un repo en GitHub/GitLab/Bitbucket y agregarlo:
      git -C "c:/Net 8/TeamworkTools" remote add origin <URL>
      git -C "c:/Net 8/TeamworkTools" push -u origin master
  (b) Solo commitear localmente (sin push).
```

Esperar respuesta. Si el usuario elige (b), continuar con Fase 1 y omitir Fase 4.

### Fase 1: Diagnóstico — Revisar estado del repo

```bash
git -C "c:/Net 8/TeamworkTools" status
git -C "c:/Net 8/TeamworkTools" diff
git -C "c:/Net 8/TeamworkTools" diff --cached
git -C "c:/Net 8/TeamworkTools" log --oneline -5
```

**Si no hay cambios** (working tree clean) **y no hay commits locales no pusheados**: Informar "No hay cambios pendientes" y TERMINAR.

**Si solo hay commits locales no pusheados**: Saltar a Fase 4 (push directo, sin Fase 2-3).

**Si hay cambios sin commitear**: Continuar a Fase 2.

### Fase 2: Generar commit message

1. Analizar los cambios (archivos modificados, nuevos, eliminados).
2. Generar un commit message siguiendo esta convención:
   - Formato: `tipo(scope): descripción en español`
   - Tipos válidos: `feat`, `fix`, `refactor`, `docs`, `chore`, `test`, `style`, `perf`
   - Scopes típicos para este repo: `client`, `reports`, `skill`, `agent`, `scheduled`, `config`, `docs`
3. **Mostrar al usuario** el mensaje propuesto y un resumen de archivos.
4. **Esperar aprobación** del usuario antes de continuar.
5. Si el usuario pide cambios, ajustar y volver a mostrar.

### Fase 3: Commit

**Archivos prohibidos** — NUNCA incluir en `git add`:

- `secrets/teamwork.env` (API key)
- Cualquier archivo con `*.env` que no sea `*.env.example`
- `reports/` (gitignored, pero re-validar)
- Archivos `*.tar`, `*.zip`, `*.7z`
- Archivos con tokens, credenciales, dumps de DB

Si alguno aparece en los cambios, **ADVERTIR al usuario** y excluirlo del staging.

**Proceso**:

1. Stagear archivos específicos (NUNCA `git add -A` ni `git add .`):

   ```bash
   git -C "c:/Net 8/TeamworkTools" add <archivo1> <archivo2> ...
   ```

2. Crear el commit con HEREDOC para preservar formato:

   ```bash
   git -C "c:/Net 8/TeamworkTools" commit -m "$(cat <<'EOF'
   tipo(scope): descripción del cambio

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
   EOF
   )"
   ```

3. Verificar que el commit fue exitoso:

   ```bash
   git -C "c:/Net 8/TeamworkTools" log --oneline -1
   ```

### Fase 4: Push (solo si hay remote)

```bash
git -C "c:/Net 8/TeamworkTools" push origin master
```

Primer push después de configurar remote: usar `-u origin master`.

**Si el push falla** (rejected por divergencia con remoto):

- Informar al usuario.
- NUNCA hacer `git push --force`.
- Sugerir `git pull --rebase` pero NO ejecutarlo automáticamente — pedir permiso.

### Fase 5: Reporte final

```
Cambios subidos a git (TeamworkTools):

  Commit: abc1234 — tipo(scope): descripción
  Push:   OK → origin/master
```

Si solo se commiteó localmente (sin remote o usuario eligió omitir push):

```
Commit local creado:

  Commit: abc1234 — tipo(scope): descripción
  Push:   omitido (sin remote configurado)
```

Si no había nada que subir:

```
Sin cambios pendientes en TeamworkTools.
```

## Reglas de seguridad

1. **NUNCA** `git push --force` ni `git push -f`.
2. **NUNCA** `git add -A` ni `git add .` — siempre archivos específicos.
3. **NUNCA** commitear `secrets/teamwork.env` ni otros secrets.
4. **NUNCA** `git reset --hard` ni `git checkout .`.
5. **NUNCA** `--amend` — siempre commits nuevos.
6. **SIEMPRE** mostrar diff y mensaje al usuario ANTES de commitear.
7. **SIEMPRE** incluir footer `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
