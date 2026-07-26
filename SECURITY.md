# Política de seguridad — HyperBrain-Infra

Este repositorio contiene infraestructura como código (Docker Compose, migraciones
SQL, Terraform de SQS/Lambda, configuración de monitoreo). La seguridad aquí es
especialmente sensible: un fallo puede exponer datos o credenciales.

## Reporte de vulnerabilidades

**No abras un issue público.** Usa un canal privado:

1. **GitHub Security Advisories** — pestaña *Security* → *Report a vulnerability*.
2. **Correo** — **i7.danielcc@gmail.com**, asunto `[SECURITY] HyperBrain-Infra`.

Incluye descripción, impacto, pasos para reproducir, versión/commit afectado y
cualquier mitigación conocida.

## Qué esperar

Proyecto en fase MVP mantenido por **un único desarrollador**; sin SLA formal, pero
con acuse de recibo, evaluación y **divulgación coordinada** dando margen a corregir
antes de publicar. Se te dará crédito si lo deseas.

## Manejo de secretos

Este repositorio **no** versiona secretos en claro: se usa **SOPS** y variables de
entorno fuera del control de versiones. Si detectas un secreto filtrado en el
historial (clave, token, credencial de AWS/Supabase), trátalo como vulnerabilidad y
repórtalo por los canales privados de arriba.

## Alcance

Aplica a la infraestructura definida en este repositorio. Configuraciones inseguras
propias, ingeniería social y dependencias de terceros ya con parche disponible se
consideran fuera de alcance (repórtalas aguas arriba).
