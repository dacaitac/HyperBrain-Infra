# Contribuir a HyperBrain-Infra

Gracias por tu interés. Este documento describe cómo se aceptan contribuciones
externas y bajo qué condiciones legales.

> **Resumen:** aceptamos contribuciones bajo un **CLA obligatorio**; el proyecto se
> distribuye bajo **AGPLv3** ([LICENSE](LICENSE) · [NOTICE](NOTICE) · [CLA.md](CLA.md)).

## 1. Contributor License Agreement (CLA) — obligatorio

**Todo contribuidor externo debe firmar el CLA antes de que su PR pueda ser aceptado.**
Al abrir tu primer PR, el bot de **CLA Assistant** comentará las instrucciones y
registrará tu firma. El texto contractual completo vive en **[CLA.md](CLA.md)**: cede al
titular (Daniel Caita) una licencia amplia sobre tu contribución —incluido uso comercial
y relicenciamiento—, lo que sostiene el dual-licensing del ecosistema. Conservas la
autoría y el uso libre de tu propio trabajo.

## 2. Flujo de contribución

1. **Abre o referencia un issue** que describa el cambio de infraestructura.
2. **Haz fork** y **crea una rama** descriptiva desde `main`.
3. **Implementa el cambio** (Compose, migración SQL, Terraform, monitoreo).
4. **Abre el Pull Request** contra `main`, referenciando el issue (`Closes #NN`).
5. **Firma el CLA** cuando el bot lo solicite (solo la primera vez).
6. **Deja el CI en verde.** El PR solo se revisa con todos los checks pasando:
   - **`docker compose config --quiet`** valida el stack sin errores.
   - **Terraform** (`terraform validate`/`fmt`) para los módulos afectados.
   - **Migraciones**: revisadas; nunca se aplican a producción desde un PR.

### Convenciones

- **Conventional Commits** (`type(scope): descripción`).
- Un PR, un propósito. **Nunca** commitees `.env`, secretos ni claves (se usa SOPS).
- No uses `git commit --no-verify`.

## 3. Licencia de las contribuciones

Salvo lo establecido por el CLA (sección 1), tu contribución se distribuye bajo la
**GNU AGPLv3**, en coherencia con [LICENSE](LICENSE) y [NOTICE](NOTICE).

## Contacto

**Daniel Caita** — i7.danielcc@gmail.com.
