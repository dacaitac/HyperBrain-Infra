# HyperBrain-Infra

[![Validate Infra](https://github.com/dacaitac/HyperBrain-Infra/actions/workflows/validate.yml/badge.svg)](https://github.com/dacaitac/HyperBrain-Infra/actions/workflows/validate.yml)

Infraestructura del ecosistema **HyperBrain**: Docker Compose, migraciones SQL (Supabase),
colas SQS (LocalStack) y gestión de secretos (SOPS + age).

## Quick Start

**Prerrequisitos:** Docker ≥ 24, AWS CLI v2, `jq`

```bash
# 1. Copiar variables de entorno (solo la primera vez)
cp .env.example .env

# 2. Levantar infraestructura obligatoria
docker compose up -d

# 3. Verificar que todo quedó healthy (esperar ~60s)
docker compose ps

# 4. Ejecutar la prueba reina
./scripts/smoke-test.sh
```

**Perfiles opcionales:**

```bash
docker compose --profile app up -d      # + HyperBrain-core (CI/integración)
docker compose --profile ui up -d       # + Appsmith (dashboards 4DX)
docker compose --profile email up -d    # + Inbucket (testing de email GoTrue)
```

> **Nota:** el check #4 del smoke test (`sys_user`) falla hasta que se aplique el DDL v1 ([S0-02](https://github.com/dacaitac/HyperBrain-docs/issues/2)).

---

## Arquitectura (MVP)

El MVP corre 100 % en Docker Compose sobre `daniel-ubuntu`
([ADR-006](https://github.com/dacaitac/HyperBrain-docs)). Orden de arranque:

```
PostgreSQL (+ pgvector)  →  Supabase (GoTrue + PostgREST)  →  HyperBrain-core
```

| Servicio | Imagen | Puerto | Health |
| :--- | :--- | :--- | :--- |
| `postgres` | `pgvector/pgvector:pg16` | 5432 | `pg_isready` |
| `gotrue` (Supabase Auth) | `supabase/gotrue` | 9999 | `/health` |
| `postgrest` (Supabase REST) | `postgrest/postgrest` | 3000 | `/` |
| `localstack` | `localstack/localstack` | 4566 | `/_localstack/health` |
| `hyperbrain-core` | `ghcr.io/dacaitac/hyperbrain-core` | 8080 | `/actuator/health` |

Colas SQS (LocalStack, ADR-001): `sync-events.fifo`, `core-events`, `ia-jobs`, cada una con su DLQ.

## Gestión de Schema y Entornos

### Dev local (Compose)

El schema real lo gestiona **Supabase CLI** sobre la base levantada en Docker Compose.
Nunca usar Flyway contra la Compose DB (Flyway solo corre en Testcontainers — ver S0-07).

```bash
# Aplicar migraciones pendientes (requiere Supabase CLI y Compose levantado)
supabase db push

# Alternativa sin CLI (primera vez, schema vacío)
scripts/apply-schema.sh --seed
```

Supabase CLI conecta al PostgreSQL del Compose usando `POSTGRES_URL` (ver `.env.example`).
Para autenticar: `supabase login` la primera vez (solo necesario para operaciones de proyecto remoto).

### Prod (daniel-ubuntu)

Las migraciones se aplican en CD automáticamente: el runner self-hosted ejecuta
`supabase db push` al hacer merge a `main` si hay cambios en `supabase/migrations/`.
Nunca hacer `supabase db reset` en prod — es destructivo.

### Tests de integración (Core — Testcontainers)

El Core crea un PostgreSQL efímero en cada test run con Testcontainers y Flyway
(`V1__init.sql` contiene las 24 tablas del ERD v2.0.0). Este DB es independiente del
Compose y se destruye al terminar la suite. Flyway está **deshabilitado** en el perfil
runtime para que no interfiera con las migraciones de Supabase (ver S0-07, issue #29).

### Inyectar un evento SQS en dev (sin SentinelAPI)

SentinelAPI en dev apunta a prod SQS (Opción A). Para probar el pipeline localmente
sin ella, inyectar directamente en LocalStack:

```bash
awslocal sqs send-message \
  --queue-url http://localhost:4566/000000000000/sync-events.fifo \
  --message-group-id reminder-apple-local-001 \
  --message-deduplication-id evt-00000000-0000-0000-0000-000000000001 \
  --message-body "$(cat scripts/fixtures/sample-reminder-event.json)"
```

Fixture de ejemplo: `scripts/fixtures/sample-reminder-event.json`
Contrato completo del evento: [HU-09 #14](https://github.com/dacaitac/HyperBrain-docs/issues/14)

---

## Secretos

- `.env` con valores reales: **nunca** en git (ver `.gitignore`).
- `.env.example`: plantilla con claves vacías, sí versionada.
- `secrets.enc.env`: cifrado con SOPS + age, versionable.

## Kubernetes

Los manifests `k8s/` son un objetivo de aprendizaje **post-MVP**
([ADR-006](https://github.com/dacaitac/HyperBrain-docs)); no se trabajan durante el MVP sin ADR previo.

## Documentación

La documentación de ingeniería vive en **HyperBrain-docs**. `CLAUDE.md` (symlink al brain de IA)
contiene las reglas de operación, migraciones y gestión de secretos.

---

> **Nota:** el contenido legacy (stack Kafka + Apache Superset del proyecto anterior "SOPFC") fue
> eliminado al reiniciar el repo. La arquitectura vigente usa SQS ([ADR-001](https://github.com/dacaitac/HyperBrain-docs))
> y Appsmith en lugar de Superset.
