# Installazione di Maximo Application Suite

Questa directory contiene uno script di installazione configurabile per IBM Maximo Application Suite (MAS) su OpenShift.

## File

- `install-maximo.sh` - Script principale di installazione
- `config.yaml` - File di configurazione con tutti i parametri di installazione
- `.secrets/` - Cartella dei file sensibili, **esclusa da git** (`.gitignore`):
  - `entitlement-key` - IBM Entitlement Key (una riga)
  - `license.dat` - File di licenza MAS (obbligatorio)
  - `pull-secret` - Pull secret per IBM Container Registry (deve esistere, ma `mas install` non lo usa)
  - `kubeconfig-<cluster>` - Kubeconfig del cluster OpenShift
  - `config.local.yaml` - (opzionale) override di `config.yaml` per dati personali o specifici dell'ambiente

Nomi dei file e cartella sono configurabili nella sezione `files` di `config.yaml`.

## Prerequisiti

Sull'host servono **solo**:

1. **Container Engine** - Docker o Podman (lo script rileva automaticamente o usa la preferenza impostata)
2. **Kubeconfig** del cluster (`.secrets/kubeconfig-<cluster>`) con permessi cluster-admin

Non servono `oc`, `helm` o login sul cluster: ogni comando `oc`/`helm` gira **dentro il container MAS CLI**. L'immagine MAS CLI di solito include gia `helm` (in tal caso `cluster.helm_version` non e usato); se manca, lo script scarica nel container (non sull'host) una release Helm 3 fissata da `get.helm.sh` e confronta lo sha256 pubblicato (il checksum arriva dallo stesso host: e solo un controllo di integrita del download, non di autenticita).

Storage (Longhorn), StorageClass di default e image registry vengono preparati dallo script (fase `cluster`, vedi sotto): non serve installare nulla a mano sul cluster (la guida [LONGHORN.md](LONGHORN.md) resta come riferimento per l'installazione manuale).

Per la fase `install` servono inoltre:

3. **File obbligatori**:
   - `.secrets/pull-secret` - Credenziali per IBM Container Registry
   - `.secrets/license.dat` - File di licenza MAS valido
4. **IBM Entitlement Key** - Letta, nell'ordine, da variabile d'ambiente `IBM_ENTITLEMENT_KEY`, `ibm.entitlement_key` in `config.yaml`, file `.secrets/entitlement-key` (consigliato)

## Configurazione

Modificare `config.yaml` per personalizzare l'installazione:

### Sezioni principali di configurazione

#### Istanza MAS
```yaml
mas:
  instance_id: "masdemosno"      # Identificativo univoco dell'istanza MAS
  workspace_id: "masdemosno"    # Identificativo del workspace
  workspace_name: "MAS Demo"    # Nome visualizzato
  catalog_version: "v9-260924-amd64"
  channel: "9.2.x"
  operational_mode: "non-prod"  # non-prod o prod
  admin_mode: "cluster"         # Obbligatorio per MAS 9.2+ (cluster, namespaced, minimal)
```

#### Storage
```yaml
storage:
  rwo_class: "longhorn"         # Storage class ReadWriteOnce
  rwx_class: "longhorn"         # Storage class ReadWriteMany
  pipeline_class: "longhorn"    # Storage class per le pipeline
  access_mode: "ReadWriteOnce"
```

#### Configurazione Database
```yaml
mongodb:
  namespace: "mongoce"

db2:
  manage: true
  channel: "v120105.0"          # Lasciare vuoto per usare il default del catalogo
  namespace: "db2u"
  type: "db2wh"                 # DB2 Warehouse
  memory_requests: "8Gi"
  memory_limits: "12Gi"
  data_storage: "20Gi"
```

#### Applicazioni
```yaml
manage:
  install: true
  components: "base=latest,health=latest"
  server_bundle_size: "dev"     # dev, snojms, small, jms
  demodata: true                # Carica i dati demo di Manage (--manage-demodata)

# Nota: le applicazioni opzionali non sono ancora gestite dallo script,
# se impostate a true viene solo mostrato un warning
applications:
  iot: false
  monitor: false
  predict: false
  # ... altre applicazioni

container:
  name: "mas-installer"         # Nome del container
  image: "quay.io/ibmmas/cli:latest"
  network: "host"
  engine: "podman"              # docker, podman, o auto (rilevamento automatico)

files:                          # Percorsi relativi a secrets_dir
  secrets_dir: ".secrets"       # Relativa allo script, oppure percorso assoluto
  entitlement_key: "entitlement-key"
  pull_secret: "pull-secret"
  license: "license.dat"
  kubeconfig: "kubeconfig-masdemosno"
```

#### Pre-configurazione del cluster
```yaml
cluster:
  configure: true               # false = salta Longhorn e StorageClass di default
  default_storage_class: ""     # StorageClass che deve essere l'UNICA di default; vuoto = storage.rwo_class
  helm_version: "3.19.0"        # Helm scaricato nel container solo se manca
  longhorn:
    install: true               # false = Longhorn gestito altrove
    version: "1.13.0"
    namespace: "longhorn-system"
    replica_count: 1            # 1 per SNO (immutabile nella StorageClass dopo la creazione)
    oauth_proxy_tag: ""         # vuoto = major.minor del cluster (es. 4.22)
    settings:                   # allineate a ogni esecuzione; vuoto = non toccare
      priority_class: "system-node-critical"
      storage_minimal_available_percentage: 10
  preflight:
    min_cpu: 16                 # CPU allocabili minime (somma dei nodi Ready)
    min_memory_gib: 48          # memoria allocabile minima in GiB (somma dei nodi Ready)
    check_dns: true             # api.<dominio> e un host *.apps devono risolvere
```

La fase `cluster` esegue, nell'ordine:

1. **Longhorn** (chart `longhorn/longhorn`, `openshift.enabled=true`, 1 replica, tag oauth-proxy = versione del cluster). Il rilevamento e *fail closed*: legge le release Helm `longhorn` nel namespace (label `owner=helm,name=longhorn`, `status`). `deployed` = gia installato, **si salta e non si aggiorna**; un altro stato (`failed`, `pending-*`, ...) o un errore API terminano lo script con istruzioni; nessuna release ma DaemonSet `longhorn-manager` presente = installato fuori da Helm, si salta con un avviso; altrimenti `helm install`. Poi attende che deployment (la UI `longhorn-ui` e solo un avviso), DaemonSet e nodi Longhorn siano pronti, e in caso di timeout mostra `oc get pods`. Non servono MachineConfig, pacchetti sui nodi (RHCOS include iscsi), comandi `oc adm policy` (il chart concede le SCC) ne label sui nodi.
2. **Impostazioni Longhorn** `priority-class` e `storage-minimal-available-percentage`: su una nuova installazione sono nei values Helm (`defaultSettings.priorityClass`, `defaultSettings.storageMinimalAvailablePercentage`), perche una patch diretta verrebbe annullata da longhorn-manager al riavvio (ri-sincronizza la ConfigMap `longhorn-default-setting` del chart). Su un Longhorn gia presente vengono patchate se diverse, con un avviso (e il comando `helm upgrade --reuse-values --set-string ...` da usare) se la ConfigMap ha un valore diverso. Con `cluster.longhorn.install: false` non vengono toccate.
3. **StorageClass di default**: attende la StorageClass configurata e la rende l'unica di default (le altre vengono impostate a non-default).
4. **Image registry** (vedi sotto).

La fase `preflight` e in **sola lettura** e controlla: versione e stato di ClusterVersion, nodi Ready, CPU/memoria allocabili rispetto ai minimi configurati, risoluzione DNS di `api.<dominio>` e di un host `*.apps` (dal container), permessi cluster-admin (`oc auth can-i '*' '*'`), ClusterOperator non degradati/non disponibili. Se un controllo fallisce lo script termina prima di modificare qualsiasi cosa.

#### Image registry interno
```yaml
image_registry:
  configure: true               # Abilita il registry interno se è "Removed"
  storage_class: ""             # Vuoto = storage.rwo_class
  size: "100Gi"
```

Manage costruisce le proprie immagini (admin e server bundle) nel registry interno di OpenShift. Su bare metal/SNO il registry è `Removed` di default e l'installazione resta bloccata su `Builds not complete` (build in errore `InvalidOutputReference`). Lo script lo abilita con un PVC RWO, 1 replica e strategia `Recreate`. Su SNO l'abilitazione riavvia l'API server per un paio di minuti.

#### Override locale
I valori in `.secrets/config.local.yaml` sovrascrivono quelli di `config.yaml`, con la stessa struttura. Usarlo per i dati che non devono finire su git, ad esempio il contatto UDS:
```yaml
uds:
  email: "nome.cognome@azienda.com"
  firstname: "Nome"
  lastname: "Cognome"
```

I commenti in coda ai valori (`key: "valore" # nota`) sono supportati.

**Attenzione**: i valori vuoti in `config.local.yaml` (`chiave: ""`) **non** sovrascrivono i valori non vuoti di `config.yaml`, perche il parser scarta le chiavi vuote. Per ottenere un valore vuoto, svuotarlo direttamente in `config.yaml`.

## Fasi e opzioni da riga di comando

| Fase | Cosa fa |
|------|---------|
| `preflight` | Controlli in sola lettura sul cluster |
| `cluster` | Longhorn (Helm), impostazioni Longhorn, StorageClass di default, image registry |
| `install` | `mas install` (Db2, MongoDB, SLS, MAS Core, Manage) |

Di default vengono eseguite tutte le fasi, in questo ordine.

| Opzione | Effetto |
|---------|---------|
| `--only <elenco>` | Esegue solo le fasi indicate (separate da virgola), es. `--only preflight,cluster` |
| `--skip <elenco>` | Salta le fasi indicate (applicato dopo `--only`), es. `--skip install` |
| `--clean` | Elimina i namespace MAS esistenti **prima** di `cluster`/`install` (distruttivo). Chiede di digitare l'instance id; da stdin non interattivo richiede `--yes` |
| `--yes` | Non chiede conferma (solo per `--clean`) |
| `-h`, `--help` | Mostra l'help |

Fasi o opzioni non valide terminano con errore (exit 2) prima di qualsiasi accesso al cluster o al container.

`--clean` e l'unico modo per ripulire: non avviene piu in automatico. Elimina solo i namespace `mas-<instance_id>-*`, quello di MongoDB (`mongodb.namespace`), quello di Db2 (`db2.namespace`) e `ibm-sls`, con regex ancorata. Un errore nell'elenco dei namespace interrompe la pulizia; a fine pulizia lo script rielenca i namespace e termina con errore se ne resta qualcuno (es. in `Terminating` bloccato da finalizer).

## Utilizzo

1. **Preparare i file**:
   ```bash
   # Verificare che i file obbligatori siano presenti
   ls -la .secrets/ config.yaml
   ```

2. **Salvare la entitlement key** (da https://myibm.ibm.com/products-services/containerlibrary):
   ```bash
   mkdir -p .secrets && chmod 700 .secrets
   echo '<chiave>' > .secrets/entitlement-key && chmod 600 .secrets/entitlement-key
   ```

3. **Verificare la configurazione**:
   ```bash
   # Modificare config.yaml con i propri valori
   vi config.yaml
   ```

4. **Controllare il cluster** (sola lettura, consigliato come prima esecuzione):
   ```bash
   ./install-maximo.sh --only preflight
   ```

5. **Avviare l'installazione** (tutte le fasi):
   ```bash
   ./install-maximo.sh
   # oppure solo la preparazione del cluster
   ./install-maximo.sh --only cluster
   ```

## Processo di installazione

Lo script esegue i seguenti passaggi:

1. **Caricamento configurazione** - Analizza la configurazione YAML e gli argomenti
2. **Controllo prerequisiti e validazione** - Container engine, kubeconfig e (per `install`) entitlement key, pull secret, licenza
3. **Setup container** - Scarica l'immagine e avvia il container MAS CLI con il kubeconfig (tutti gli accessi al cluster passano da qui)
4. **Fase `preflight`** - Controlli in sola lettura
5. **Pulizia** - Solo con `--clean`
6. **Fase `cluster`** - Longhorn, StorageClass di default, image registry
7. **Fase `install`** - Esegue l'installazione completa di MAS
8. **Completamento** - Fornisce lo stato e i passaggi successivi. Il container resta attivo dopo `install` per il troubleshooting; se `install` non e tra le fasi viene rimosso a fine esecuzione

## Durata prevista

- **Tempo totale di installazione**: 60-120 minuti
- **Validazione pre-installazione**: 2-5 minuti
- **Componenti core MAS**: 45-60 minuti
- **Setup database**: 15-30 minuti
- **Configurazione applicazioni**: 10-20 minuti

## Post-installazione

Dopo un'installazione riuscita:

1. **Accedere alla console MAS**:
   ```
   https://admin.<workspace_id>.<instance_id>.apps.<dominio-cluster>
   ```

2. **Monitorare l'installazione**:
   ```bash
   # I comandi oc si eseguono nel container MAS CLI (es. podman exec -it mas-installer oc ...)
   # oppure con un oc locale e lo stesso kubeconfig
   # Controllare i pod in tutti i namespace
   oc get pods -A | grep mas

   # Controllare le route
   oc get routes -A | grep mas

   # Visualizzare un namespace specifico
   oc get pods -n mas-<instance_id>-core
   ```

3. **Risoluzione problemi**:
   ```bash
   # Accedere al container MAS CLI (Docker)
   docker exec -it mas-installer bash

   # Accedere al container MAS CLI (Podman)
   podman exec -it mas-installer bash

   # Controllare i log di installazione
   oc logs -n mas-<instance_id>-pipelines
   ```

## Esempi di personalizzazione

### Configurazione per client diversi
Creare un nuovo file di configurazione per ogni client:
```bash
cp config.yaml config-client1.yaml
# Modificare i valori specifici del client
vi config-client1.yaml
```

### Configurazione di produzione
```yaml
mas:
  operational_mode: "prod"      # Abilitare la modalita produzione

db2:
  memory_requests: "16Gi"       # Aumentare per la produzione
  memory_limits: "24Gi"
  data_storage: "100Gi"         # Storage piu grande

manage:
  server_bundle_size: "large"   # Dimensionamento per produzione
```

## Risoluzione problemi

### Problemi comuni

1. **Storage Class non trovata**:
   ```bash
   # Dall'host, con il container attivo: podman exec mas-installer oc get storageclass
   # (la fase `cluster` crea Longhorn e lo rende StorageClass di default)
   # Aggiornare config.yaml con il nome corretto della storage class
   ```

2. **Problemi con il pull secret**:
   ```bash
   # Verificare il formato del pull secret
   cat .secrets/pull-secret
   # Deve contenere JSON valido con le credenziali del registry
   ```

3. **Problemi con il file di licenza**:
   ```bash
   # Controllare il file di licenza
   file .secrets/license.dat
   # Deve essere un file di licenza binario valido
   ```

4. **Connettivita del container**:
   ```bash
   # Testare l'accesso a OpenShift dal container (Docker)
   docker exec -it mas-installer oc get nodes

   # Testare l'accesso a OpenShift dal container (Podman)
   podman exec -it mas-installer oc get nodes
   ```

## Supporto Container Engine

Lo script supporta sia Docker che Podman come container engine:

### **Rilevamento automatico (predefinito)**
Lo script rileva automaticamente i container engine disponibili con **priorita a Podman**:
1. Controlla prima la presenza di Podman (preferito per OpenShift)
2. Utilizza Docker come alternativa se Podman non e' disponibile
3. Fallisce se nessuno dei due e' disponibile

### **Preferenza esplicita**
E' possibile specificare una preferenza in `config.yaml`:
```yaml
container:
  engine: "docker"    # Forzare l'uso di Docker
  # OPPURE
  engine: "podman"    # Forzare l'uso di Podman
  # OPPURE
  engine: "auto"      # Rilevamento automatico (predefinito)
```

### **Funzionalita specifiche di Podman**
Quando si utilizza Podman, lo script automaticamente:
- Usa `--network host --privileged` per una migliore connettivita con OpenShift
- Gestisce l'esecuzione rootless dei container
- Fornisce comandi di risoluzione problemi specifici per Podman

### **Docker vs Podman**

| Caratteristica | Docker | Podman |
|----------------|--------|--------|
| Privilegi root | Richiede il daemon | Supporto rootless |
| Accesso di rete | Networking standard | Networking host preferito |
| Compatibilita OpenShift | Buona | Eccellente |
| Sicurezza | Standard | Migliorata (rootless) |

### Posizione dei log

- **Log di installazione**: stdout/stderr del container
- **Log delle pipeline**: `oc logs -n mas-<instance_id>-pipelines`
- **Log degli operator**: `oc logs -n mas-<instance_id>-core`

## Supporto

Per problemi o domande:
1. Controllare i log del container:
   - Docker: `docker exec -it mas-installer bash`
   - Podman: `podman exec -it mas-installer bash`
2. Verificare gli eventi OpenShift: `oc get events --sort-by=.lastTimestamp`
3. Consultare la documentazione IBM MAS: https://www.ibm.com/docs/en/maximo-application-suite
