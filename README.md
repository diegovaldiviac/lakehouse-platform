# lakehouse-platform

Infraestructura como código de un lakehouse sobre Kubernetes. Arranca en un nodo con k3s y está pensada para crecer hasta un cluster productivo cambiando solo el archivo de entorno.

## Estructura

| Carpeta | Qué contiene |
|---|---|
| `host/` | Instalación de k3s en el servidor (requiere `sudo`), descarga del kubeconfig y plantilla de `registries.yaml` |
| `terraform/platform/` | Base del cluster: namespaces, operadores (Strimzi, Spark Operator, CloudNativePG con el plugin barman-cloud, cert-manager, Keycloak) y object store (SeaweedFS) |
| `terraform/workloads/` | CA del lakehouse, Postgres del catálogo (CloudNativePG) con sus respaldos, Lakekeeper y OpenFGA, Keycloak; después Trino con OPA, Kafka + Debezium, Airflow, OpenMetadata |
| `terraform/identity/` | Contenido de Keycloak: realm `lakehouse`, usuarios y clientes. Se aplica contra la API de Keycloak, no la de Kubernetes |
| `terraform/envs/<entorno>/` | Variables y estado por entorno. Solo `example/` se versiona |
| `images/spark/` | Imagen de Spark con Iceberg y OpenLineage, que construye `.github/workflows/spark-image.yml` |

`platform` y `workloads` se aplican por separado: los recursos de `workloads` usan tipos (`Kafka`, `Cluster`, `ObjectStore`, `SparkApplication`) que solo existen después de instalar los operadores, y Secrets que crea `platform`. Por eso el `plan` de `workloads` se hace después de aplicar `platform`.

## Namespaces

| Namespace | Uso |
|---|---|
| `lakehouse-operators` | Operadores |
| `lakehouse-storage` | Object store compatible con S3 |
| `lakehouse-ingest` | Kafka y Kafka Connect con Debezium |
| `lakehouse-catalog` | Postgres `catalog-db`, Lakekeeper (catálogo Iceberg REST) y OpenFGA (permisos) |
| `lakehouse-compute` | Jobs de Spark |
| `lakehouse-query` | Trino |
| `lakehouse-identity` | Operador de Keycloak y Keycloak |

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

### 6. Identidad

`identity` se conecta a Keycloak por su URL pública, así que va después de `workloads` y necesita el NodePort de Keycloak abierto en el firewall del nodo (`install-k3s.sh` lo abre).

```bash
cd terraform/identity
terraform init -reconfigure -backend-config=../envs/<entorno>/identity.backend.hcl
terraform apply -var-file ../envs/<entorno>/identity.tfvars
```

### 7. Tests

Suite pytest contra el cluster real, un archivo por etapa. Necesita `uv` y `kubectl`:

```bash
cd tests
LAKEHOUSE_ENV=<entorno> uv run pytest
```

Usa `~/.kube/config-<entorno>` (o `LAKEHOUSE_KUBECONFIG`) y el `kubectl` del PATH (o `KUBECTL`). Las pruebas de red levantan un pod temporal de `busybox` en `lakehouse-compute`.

La prueba de restauración queda fuera de la corrida normal porque tarda unos minutos: `uv run pytest -m restauracion`. Escribe una fila en la base `postgres` de `catalog-db`, espera a que su WAL se archive, recupera un cluster temporal `catalog-db-restore-test` desde el bucket de respaldos, comprueba la fila y el warehouse, y borra el cluster con su volumen.

## Recursos y red

- Cada namespace tiene una `ResourceQuota` (`namespace_quotas` en `platform.tfvars`; la de `lakehouse-compute` es el tope de Spark) y un `LimitRange` que da requests y límite de memoria por defecto a los contenedores que no los declaran.
- El catálogo (Postgres, Lakekeeper, OpenFGA) corre con QoS Guaranteed.
- SeaweedFS tiene una identidad por consumidor: `admin` para operación, `lakekeeper` acotada al bucket `warehouse` y `catalog-backup` al de respaldos, con sus claves en el Secret `s3-<consumidor>` de su namespace. Solo `lakekeeper` puede asumir el rol `lakekeeper-vended` por STS, y SeaweedFS respeta la política de sesión con que Lakekeeper acota cada credencial temporal a una tabla.
- Los buckets los crea el Job `seaweedfs-buckets` con la identidad `admin`. El Job `lakekeeper-bootstrap` hace el bootstrap de Lakekeeper con la cuenta de servicio `lakehouse-admin` de `lakehouse-catalog`, que queda como administradora (rol `operator`), y crea el warehouse `lakehouse` con credenciales temporales por STS. Quien pueda crear pods con esa cuenta administra el catálogo.
- Los jobs de Spark corren en `lakehouse-compute` con la cuenta de servicio `spark-operator-spark`, que el Job `lakekeeper-bootstrap` registra en Lakekeeper con permisos `create` y `modify` sobre el warehouse. El ConfigMap `spark-lakehouse` tiene lo que un `SparkApplication` copia: `image`, `service-account` y `spark-conf.json` (catálogo Iceberg REST con credenciales delegadas). Spark no lleva claves de S3; el job lee el token de su cuenta de servicio y lo fija en `spark.sql.catalog.<catálogo>.token` antes de usar el catálogo (ver `tests/spark/crear_tabla.py`).
- `catalog-db` archiva su WAL de forma continua y hace un respaldo base diario en el bucket `catalog-backups`, con la identidad `catalog-backup` y retención de 14 días. En un solo nodo el bucket está en el mismo disco: cubre errores humanos y de software, no la pérdida del disco.
- En `lakehouse-catalog` la entrada está denegada por defecto: Lakekeeper (8181) recibe de los namespaces del lakehouse; OpenFGA solo de Lakekeeper; Postgres de Lakekeeper, OpenFGA y el operador de CloudNativePG.

## Acceso desde fuera del cluster

Keycloak se expone por NodePort en `https://<public_host>:30443`, con la misma URL desde los equipos y desde los pods, para que los tokens tengan un solo emisor. El certificado lo emite la CA del lakehouse (cert-manager, ClusterIssuer `lakehouse-ca`), que los equipos tienen que aceptar. En Windows, sin permisos de administrador:

```powershell
kubectl --kubeconfig $HOME\.kube\config-<entorno> -n lakehouse-operators get secret lakehouse-ca -o jsonpath='{.data.ca\.crt}' |
  ForEach-Object { [IO.File]::WriteAllBytes("$HOME\lakehouse-ca.crt", [Convert]::FromBase64String($_)) }
Import-Certificate -FilePath $HOME\lakehouse-ca.crt -CertStoreLocation Cert:\CurrentUser\Root
```

- Consola de administración: `https://<public_host>:30443/admin`, usuario `admin`, clave en el Secret `keycloak-bootstrap-admin` de `lakehouse-identity`.
- Consola de cuenta del realm: `https://<public_host>:30443/realms/lakehouse/account`, usuario `prueba`, clave con `terraform output -raw test_user_password` en `terraform/identity`.

El administrador y el cliente `terraform` del bootstrap son temporales para Keycloak: sirven hasta federar con el proveedor de identidad definitivo.

Trino se expone igual, en `https://<public_host>:30843` (la interfaz web en `/ui/`), con login OAuth2 contra el realm `lakehouse`; el usuario de Trino es el `preferred_username` del token. Trino llega a Lakekeeper con la cuenta de servicio del cliente `trino`, cuyo usuario de Lakekeeper es `oidc~service-account-trino`; el Job de bootstrap le da permisos sobre el warehouse.

Lakekeeper acepta tokens del realm `lakehouse` con audiencia `lakekeeper` (la agrega el scope del mismo nombre) y tokens de cuentas de servicio del cluster. Un usuario o cliente OIDC queda en Lakekeeper como `oidc~<preferred_username>` (el puente OPA de Trino arma el id igual) y se registra con `POST /management/v1/user`; los permisos sobre el warehouse se le dan aparte (`catalog_users` en `workloads.tfvars`, además de Spark y Trino). Los pods que llaman a Keycloak montan el ConfigMap `lakehouse-ca` de su namespace.

## Estado de Terraform

Hay un estado por módulo y por entorno, por defecto local en `terraform/envs/<entorno>/<módulo>.tfstate`. Contiene claves S3, las contraseñas de Postgres y la llave de cifrado de Lakekeeper en texto plano: no se versiona ni se comparte. Para un backend remoto se cambia el bloque `backend` de los dos `versions.tf`, los `.backend.hcl` del entorno pasan a tener la dirección del estado, y se migra con `terraform init -migrate-state`.

## Imágenes

Las imágenes se descargan de los registros públicos, con versión fija. Para descargarlas desde un registro interno basta un `registries.yaml` con espejos, sin tocar los nombres de imagen.

La imagen de Spark es propia: la oficial `apache/spark` más los jars de Iceberg (runtime y bundle de AWS) y OpenLineage, cada uno verificado con un SHA-256 fijo en el Dockerfile. GitHub Actions la construye en cada cambio de `images/spark/` en `main` y la publica en `ghcr.io/<owner>/<repo>/spark`, con el tag `sha-<commit>`; en un pull request solo la construye. Terraform la referencia por digest (`spark_image` en `workloads.tfvars`). El paquete de ghcr.io nace privado aunque el repo sea público: hay que dejarlo público una vez en su configuración o darle a k3s credenciales de lectura en `registries.yaml`. Para construirla desde un registro y un espejo de Maven internos están los argumentos `BASE_IMAGE` y `MAVEN_REPO`.

Los charts de Helm se bajan como `.tgz` desde GitHub Releases (cert-manager desde `charts.jetstack.io`), con la versión en la URL. Si la red no llega a esos sitios, `chart_overrides` en los `.tfvars` apunta cada chart a un espejo o a una ruta local (ver `envs/example/`).
