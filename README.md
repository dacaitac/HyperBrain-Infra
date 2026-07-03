# HyperBrain-Infra

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
