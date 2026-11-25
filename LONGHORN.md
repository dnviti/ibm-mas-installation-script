# Installazione di Longhorn su OpenShift

Guida all'installazione di [Longhorn](https://longhorn.io/) come storage distribuito su OpenShift Container Platform (OCP).

> **Automatizzato**: `install-maximo.sh` (fase `cluster`) esegue gia tutto quello che segue (installazione Helm con i values per SNO, impostazioni Longhorn, StorageClass di default) partendo dal solo kubeconfig, vedi [README.md](README.md). Questa guida resta come riferimento per l'installazione manuale.

## Prerequisiti

Su OpenShift/RHCOS non servono interventi manuali sui nodi:

- **iSCSI / NFS**: `iscsi-initiator-utils`, `nfs-utils`, `cryptsetup` e `device-mapper` sono gia presenti in RHCOS (Longhorn riporta `RequiredPackages=True`). Il vecchio passo `dnf install iscsi-initiator-utils` non va eseguito: RHCOS ha un filesystem immutabile e `dnf` non e utilizzabile. Per un controllo, dopo l'installazione guardare le condizioni delle risorse `nodes.longhorn.io`.
- **Security Context Constraints (SCC)**: con `openshift.enabled=true` il chart Helm crea da solo il ruolo `longhorn-ocp-privileged-role` (SCC `anyuid` e `privileged`) e i relativi binding, quindi i comandi `oc adm policy add-scc-to-user ...` non servono.
- **Label dei nodi**: l'etichetta `node.longhorn.io/create-default-disk=true` e inutile con le impostazioni di default (`create-default-disk-labeled-nodes=false`: Longhorn crea il disco di default su tutti i nodi), quindi non va applicata.

## Aggiungere la repository Helm di Longhorn alla console OpenShift

### Metodo 1: Tramite risorsa HelmChartRepository (consigliato)

Creare un file `longhorn-helm-repo.yaml`:

```yaml
apiVersion: helm.openshift.io/v1beta1
kind: HelmChartRepository
metadata:
  name: longhorn
spec:
  name: Longhorn
  connectionConfig:
    url: https://charts.longhorn.io
```

Applicare la risorsa:

```bash
oc apply -f longhorn-helm-repo.yaml
```

Una volta applicata, la repository Longhorn comparira nel **Developer Catalog** della console OpenShift.

### Metodo 2: Tramite CLI Helm

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update
```

## Installazione dalla console di sviluppatore OpenShift

1. Accedere alla **console web di OpenShift**
2. Passare alla prospettiva **Developer**
3. Navigare su **+Add** > **Helm Chart**
4. Nel **Developer Catalog**, filtrare per repository "Longhorn"
5. Selezionare il chart **Longhorn**
6. Cliccare su **Install Helm Chart**
7. Configurare i seguenti parametri:
   - **Release Name**: `longhorn`
   - **Namespace**: `longhorn-system` (creare se non esiste)
   - Passare alla **YAML View** e inserire i values seguenti

### Values per OpenShift

```yaml
openshift:
  enabled: true

image:
  openshift:
    oauthProxy:
      registry: quay.io
      repository: openshift/origin-oauth-proxy
      tag: '4.22'   # major.minor del cluster OCP/OKD (lo script lo ricava da solo)
```

8. Cliccare su **Install**

## Installazione alternativa tramite CLI (riferimento di quanto fa lo script)

Valori per Single Node OpenShift (SNO) e installazione con Helm. Per SNO va impostata 1 replica **prima** di creare PVC: di default Longhorn ne crea 3, su un cluster a nodo singolo le repliche aggiuntive non possono essere schedulate e tutti i volumi restano in stato *Degraded* (i parametri della StorageClass non si applicano ai volumi esistenti).

```bash
cat > longhorn-values.yaml <<'EOF'
openshift:
  enabled: true
image:
  openshift:
    oauthProxy:
      registry: quay.io
      repository: openshift/origin-oauth-proxy
      tag: "4.22"   # major.minor del cluster OCP/OKD
persistence:
  defaultClass: true
  defaultClassReplicaCount: 1
defaultSettings:
  defaultReplicaCount: '{"v1":"1","v2":"1"}'
  priorityClass: "system-node-critical"
  storageMinimalAvailablePercentage: 10
EOF

helm repo add longhorn https://charts.longhorn.io
helm repo update longhorn
helm install longhorn longhorn/longhorn \
  --version 1.13.0 \
  --namespace longhorn-system --create-namespace \
  --values longhorn-values.yaml

# Verifica
oc get sc longhorn -o jsonpath='{.parameters.numberOfReplicas}'
```

Impostazioni Longhorn gestite dallo script (modificabili in `cluster.longhorn.settings` di `config.yaml`): `priority-class` e `storage-minimal-available-percentage`. Vanno messe **nei values Helm** (`defaultSettings.priorityClass`, `defaultSettings.storageMinimalAvailablePercentage`, come sopra): una `patch` diretta della setting viene annullata al successivo riavvio di `longhorn-manager`, che ri-sincronizza le setting dalla ConfigMap `longhorn-default-setting` generata dal chart (di default `priorityClass: longhorn-critical`). Su un'installazione esistente la patch e utile solo come misura temporanea:

```bash
oc -n longhorn-system patch settings.longhorn.io priority-class --type merge -p '{"value":"system-node-critical"}'
oc -n longhorn-system patch settings.longhorn.io storage-minimal-available-percentage --type merge -p '{"value":"10"}'

# per renderle permanenti
helm upgrade longhorn longhorn/longhorn -n longhorn-system --version <versione-installata> --reuse-values \
  --set-string defaultSettings.priorityClass=system-node-critical \
  --set-string defaultSettings.storageMinimalAvailablePercentage=10
```

La StorageClass `longhorn` deve essere l'unica di default (annotazione `storageclass.kubernetes.io/is-default-class`).

## Verifica dell'installazione

Controllare che tutti i pod siano in stato Running:

```bash
oc get pods -n longhorn-system
```

Verificare che la StorageClass sia stata creata:

```bash
oc get storageclass | grep longhorn
```

Accedere alla UI di Longhorn tramite la route creata automaticamente:

```bash
oc get route -n longhorn-system
```

## Note

- Longhorn deve essere installato esclusivamente nel namespace `longhorn-system`
- Il proxy OAuth protegge l'accesso alla UI di Longhorn tramite l'autenticazione OpenShift
- Il tag dell'immagine `oauthProxy` deve corrispondere alla versione del cluster OCP/OKD (major.minor, es. `4.22`)
- Per il supporto volumi RWX, assicurarsi che il client NFSv4 sia installato su tutti i nodi

## Riferimenti

- [Documentazione ufficiale Longhorn](https://longhorn.io/docs/)
- [Longhorn Helm Charts - GitHub](https://github.com/longhorn/charts)
- [Longhorn OpenShift Readme](https://github.com/longhorn/longhorn/blob/master/chart/ocp-readme.md)
- [Longhorn su Artifact Hub](https://artifacthub.io/packages/helm/longhorn/longhorn)
- [OpenShift - Working with Helm Charts](https://docs.redhat.com/en/documentation/openshift_container_platform/4.12/html/building_applications/working-with-helm-charts)
