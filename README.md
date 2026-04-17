# HyperBrain Infrastructure Management

Este repositorio gestiona el despliegue de **HyperBrain** en el cluster local mediante Kubernetes y Kustomize.

## Estructura
- `k8s/base/`: Manifiestos base (Namespace, Deployment, Service, Ingress).
- `k8s/base/kustomization.yaml`: Configuración de Kustomize para manejar la imagen y tags.

## Cómo cambiar la imagen (Variable)
Para actualizar la versión del backend, simplemente edita el archivo `k8s/base/kustomization.yaml` en la sección `images`:
```yaml
images:
  - name: dacaitac/backend-app
    newTag: v1.2.3  # <--- Cambia esto
```

## Configuración de CI/CD (GitHub Actions)
He creado un ServiceAccount (`github-actions-sa`) en el cluster para automatizar el despliegue.

### Secretos en GitHub:
Para que GitHub pueda desplegar, añade estos **Actions Secrets** a tu repositorio de Infra:

1. **KUBECONFIG_DATA**: El contenido de tu archivo kubeconfig en base64.
2. **K8S_SERVER**: La URL de tu cluster (puedes usar tu MagicDNS de Tailscale: `https://daniel-z370p-d3.tail95d990.ts.net:6443`).

### Ejemplo de GitHub Action (.github/workflows/deploy.yml):
```yaml
name: Deploy HyperBrain
on:
  push:
    branches: [ main ]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
    - name: Set up Kustomize
      run: curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash
    - name: Update Image Tag
      run: |
        cd k8s/base
        ../../kustomize edit set image dacaitac/backend-app=${{ secrets.DOCKER_IMAGE_TAG }}
    - name: Deploy to K8s
      run: |
        echo "${{ secrets.KUBECONFIG_DATA }}" | base64 -d > kubeconfig
        kubectl apply -k k8s/base --kubeconfig=kubeconfig
```
