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

1. **OpenShift CLI (`oc`)** - Deve essere installata e autenticata sul cluster OpenShift
2. **Container Engine** - Docker o Podman (lo script rileva automaticamente o usa la preferenza impostata)
3. **Storage Class** - Longhorn o altro storage persistente deve essere disponibile (vedi [guida installazione Longhorn su OpenShift](LONGHORN.md))
4. **File obbligatori**:
   - `.secrets/pull-secret` - Credenziali per IBM Container Registry
   - `.secrets/license.dat` - File di licenza MAS valido
   - `.secrets/kubeconfig-<cluster>` - Kubeconfig del cluster
5. **IBM Entitlement Key** - Letta, nell'ordine, da variabile d'ambiente `IBM_ENTITLEMENT_KEY`, `ibm.entitlement_key` in `config.yaml`, file `.secrets/entitlement-key` (consigliato)

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

4. **Avviare l'installazione**:
   ```bash
   ./install-maximo.sh
   ```

## Processo di installazione

Lo script esegue i seguenti passaggi:

1. **Controllo prerequisiti** - Verifica strumenti, connessione al cluster, file
2. **Caricamento configurazione** - Analizza la configurazione YAML
3. **Validazione** - Controlla le storage class e l'accessibilita dei file
4. **Pulizia** - Rimuove eventuali installazioni MAS preesistenti
5. **Setup container** - Avvia il container MAS CLI con la configurazione corretta
6. **Esecuzione installazione** - Esegue l'installazione completa di MAS
7. **Completamento** - Fornisce lo stato e i passaggi successivi

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
   oc get storageclass
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
