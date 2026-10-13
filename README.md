# lakehouse-platform

Infraestructura como código de un lakehouse sobre Kubernetes. Arranca en un nodo con k3s y está pensada para crecer hasta un cluster productivo cambiando solo el archivo de entorno.

## Estructura

| Carpeta | Qué contiene |
|---|---|
| `host/` | Instalación de k3s en el servidor (requiere `sudo`), descarga del kubeconfig y plantilla de `registries.yaml` |
| `terraform/platform/` | Base del cluster: namespaces, operadores (Strimzi, Spark Operator, CloudNativePG) y object store (SeaweedFS) |
| `terraform/workloads/` | Postgres del catálogo (CloudNativePG), Lakekeeper y OpenFGA; después Keycloak, Trino con OPA, Kafka + Debezium, Airflow, OpenMetadata |
| `terraform/envs/<entorno>/` | Variables y estado por entorno. Solo `example/` se versiona |

`platform` y `workloads` se aplican por separado: los recursos de `workloads` usan tipos (`Kafka`, `Cluster`, `SparkApplication`) que solo existen después de instalar los operadores.

## Namespaces

| Namespace | Uso |
|---|---|
| `lakehouse-operators` | Operadores |
| `lakehouse-storage` | Object store compatible con S3 |
| `lakehouse-ingest` | Kafka y Kafka Connect con Debezium |
| `lakehouse-catalog` | Postgres `catalog-db`, Lakekeeper (catálogo Iceberg REST) y OpenFGA (permisos) |
| `lakehouse-compute` | Jobs de Spark |
| `lakehouse-query` | Trino |

## Dónde corre cada cosa

El repo vive en el equipo local; el servidor no tiene una copia. Terraform y `kubectl` corren en el equipo local y le mandan instrucciones al API de Kubernetes del servidor (puerto 6443); los pods se crean y corren en el servidor. Lo único que se ejecuta directo en el servidor es `install-k3s.sh`, una vez, porque instalar k3s necesita `sudo`.

## Entornos

Cada servidor o cluster es un entorno, con su carpeta `terraform/envs/<entorno>/`:

| Archivo | Qué tiene |
|---|---|
| `platform.tfvars`, `workloads.tfvars` | Nombre del entorno, StorageClass, tamaños |
| `platform.backend.hcl`, `workloads.backend.hcl` | Dónde queda el estado de Terraform de ese entorno |

El nombre del entorno es también el del kubeconfig: Terraform usa `~/.kube/config-<entorno>` con el contexto `<entorno>`, así varios clusters conviven en el mismo equipo. Si el kubeconfig viene de otro lado, se indica con `kubeconfig_path` y `kube_context` en los `.tfvars`.

Las carpetas de entornos reales quedan fuera del repo (`.gitignore`); `example/` es la plantilla.

## Puesta en marcha de un entorno

Los ejemplos usan el host SSH `<servidor>` y el entorno `<entorno>`.

### 1. k3s en el servidor

```bash
scp -r host <servidor>:~/lakehouse-host
ssh -t <servidor> "sudo bash ~/lakehouse-host/install-k3s.sh"
```

Sin `--fqdn`, el certificado del API queda a nombre de `hostname -f` del servidor; si desde el equipo local se llega por otro nombre, pasarlo con `--fqdn <nombre>`. Con login de Docker Hub o espejos en un registro interno, crear antes `registries.yaml` a partir de `registries.yaml.example` (fuera del repo, tiene credenciales) y pasarlo con `--registries <ruta>`.

El script abre el puerto 6443 a cualquier origen; si hace falta, restringirlo a la red de los equipos que administran el cluster.

En un cluster que ya existe este paso no se hace: se parte del kubeconfig que entrega el cluster.

### 2. Kubeconfig en el equipo local

```bash
bash host/get-kubeconfig.sh --server <servidor> --env <entorno>
```

En Windows:

```powershell
.\host\get-kubeconfig.ps1 -Server <servidor> -Environment <entorno>
```

Deja `~/.kube/config-<entorno>` con el contexto `<entorno>`, apuntando al nombre completo del servidor.

### 3. Variables del entorno

Copiar `terraform/envs/example/` a `terraform/envs/<entorno>/` y ajustar `environment`, las rutas de estado de los `.backend.hcl` y los tamaños.

### 4. Plataforma

```bash
cd terraform/platform
terraform init -reconfigure -backend-config=../envs/<entorno>/platform.backend.hcl
terraform apply -var-file ../envs/<entorno>/platform.tfvars
```

### 5. Cargas de trabajo

`workloads` usa los namespaces que crea `platform`, así que va después.

```bash
cd terraform/workloads
terraform init -reconfigure -backend-config=../envs/<entorno>/workloads.backend.hcl
terraform apply -var-file ../envs/<entorno>/workloads.tfvars
```

`-reconfigure` hace que cada `init` apunte al estado del entorno indicado; sin él, Terraform intentaría migrar el estado del entorno anterior al nuevo.

## Estado de Terraform

Hay un estado por módulo y por entorno, por defecto local en `terraform/envs/<entorno>/<módulo>.tfstate`. Contiene claves S3, las contraseñas de Postgres y la llave de cifrado de Lakekeeper en texto plano: no se versiona ni se comparte. Para un backend remoto se cambia el bloque `backend` de los dos `versions.tf`, los `.backend.hcl` del entorno pasan a tener la dirección del estado, y se migra con `terraform init -migrate-state`.

## Imágenes

Las imágenes se descargan de los registros públicos, con versión fija. Para descargarlas desde un registro interno basta un `registries.yaml` con espejos, sin tocar los nombres de imagen.

Los charts de Helm se bajan como `.tgz` desde GitHub Releases, con la versión en la URL. Si la red no llega a GitHub, `chart_overrides` en los `.tfvars` apunta cada chart a un espejo o a una ruta local (ver `envs/example/`).
