# Installazione di Longhorn su OpenShift

Guida all'installazione di [Longhorn](https://longhorn.io/) come storage distribuito su OpenShift Container Platform (OCP) tramite la console di sviluppatore.

## Prerequisiti

### 1. iSCSI

Longhorn richiede che `open-iscsi` sia installato e il demone `iscsid` sia attivo su tutti i nodi worker. Su RHEL/CoreOS (nodi OpenShift):

```bash
yum --setopt=tsflags=noscripts install iscsi-initiator-utils
echo "InitiatorName=$(/sbin/iscsi-iname)" > /etc/iscsi/initiatorname.iscsi
systemctl enable iscsid
systemctl start iscsid
```

Per verificare che il modulo kernel sia caricato:

```bash
modprobe iscsi_tcp
```

### 2. Security Context Constraints (SCC)

Longhorn necessita di privilegi elevati per funzionare correttamente. Configurare le SCC prima dell'installazione:

```bash
oc adm policy add-scc-to-user anyuid -z default -n longhorn-system
oc adm policy add-scc-to-user privileged -z longhorn-service-account -n longhorn-system
```

### 3. Label dei nodi

Etichettare i nodi worker su cui Longhorn deve creare i dischi di storage:

```bash
oc label node <nome-nodo-worker> node.longhorn.io/create-default-disk=true
```

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
  ui:
    route: longhorn-ui
    port: 443
    proxy: 8443

image:
  openshift:
    oauthProxy:
      repository: quay.io/openshift/origin-oauth-proxy
      tag: '4.18'   # Impostare la versione OCP/OKD del proprio cluster
```

8. Cliccare su **Install**

## Installazione alternativa tramite CLI

Se si preferisce installare da riga di comando:

```bash
oc create namespace longhorn-system

helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --set openshift.enabled=true \
  --set openshift.ui.route=longhorn-ui \
  --set openshift.ui.port=443 \
  --set openshift.ui.proxy=8443 \
  --set image.openshift.oauthProxy.repository=quay.io/openshift/origin-oauth-proxy \
  --set image.openshift.oauthProxy.tag=4.18
```

Oppure con un file `values.yaml`:

```bash
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --values values.yaml
```

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
- Il tag dell'immagine `oauthProxy` deve corrispondere alla versione del cluster OCP/OKD (es. `4.18`)
- Per il supporto volumi RWX, assicurarsi che il client NFSv4 sia installato su tutti i nodi

## Riferimenti

- [Documentazione ufficiale Longhorn](https://longhorn.io/docs/)
- [Longhorn Helm Charts - GitHub](https://github.com/longhorn/charts)
- [Longhorn OpenShift Readme](https://github.com/longhorn/longhorn/blob/master/chart/ocp-readme.md)
- [Longhorn su Artifact Hub](https://artifacthub.io/packages/helm/longhorn/longhorn)
- [OpenShift - Working with Helm Charts](https://docs.redhat.com/en/documentation/openshift_container_platform/4.12/html/building_applications/working-with-helm-charts)
