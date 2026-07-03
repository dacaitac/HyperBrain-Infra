# HyperBrain-Infra

Infraestructura del ecosistema **HyperBrain**: Docker Compose, migraciones SQL (Supabase),
colas SQS (LocalStack) y gestión de secretos (SOPS + age).

## Arquitectura objetivo (MVP)

El MVP corre 100 % en Docker Compose sobre `daniel-ubuntu`
([ADR-006](https://github.com/dacaitac/HyperBrain-docs)). Orden de arranque:

```
PostgreSQL (+ pgvector)  →  Supabase (GoTrue + PostgREST)  →  HyperBrain-core
```

| Servicio | Imagen | Puerto | Health |
| :--- | :--- | :--- | :--- |
| `postgres` | `postgres:16-alpine` | 5432 | `pg_isready` |
| `supabase-auth` (GoTrue) | `supabase/gotrue` | 9999 | `/health` |
| `supabase-rest` (PostgREST) | `postgrest/postgrest` | 8000 | `/` |
| `localstack` | `localstack/localstack` | 4566 | `/_localstack/health` |
| `hyperbrain-core` | `ghcr.io/dacaitac/hyperbrain-core` | 8080 | `/actuator/health` |

Colas SQS (LocalStack, RNF-02): `sync-events.fifo`, `core-events`, `ia-jobs`, cada una con su DLQ.

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
