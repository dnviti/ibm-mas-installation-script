#!/usr/bin/env bash

# Script di Installazione Maximo Application Suite
# Script di installazione configurabile tramite configurazione YAML

set -e

# Directory dello script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"

# Colori per l'output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Nessun colore

# Funzioni di logging
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Funzione per analizzare YAML (estrazione semplice chiave-valore)
parse_yaml() {
    local prefix=$2
    local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
    # Rimuove le righe di commento e i commenti in coda ai valori (es. key: "val" # nota)
    sed -e '/^[[:space:]]*#/d' -e "s|[[:space:]]\{1,\}#[^\"']*\$||" $1 |
    sed -ne "s|^\($s\):|\1|" \
        -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p" |
    awk -F$fs '{
        indent = length($1)/2;
        vname[indent] = $2;
        for (i in vname) {if (i > indent) {delete vname[i]}}
        if (length($3) > 0) {
            vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
            printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
        }
    }'
}

# Funzione per caricare la configurazione
load_config() {
    log_info "Loading configuration from $CONFIG_FILE..."

    # Verifica se il file di configurazione esiste
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    # Utilizza parsing YAML di base
    eval "$(parse_yaml "$CONFIG_FILE")"

    # Override locale (non versionato) nella cartella dei secret
    local secrets_dir="${files_secrets_dir:-.secrets}"
    if [[ "$secrets_dir" != /* ]]; then
        secrets_dir="${SCRIPT_DIR}/${secrets_dir}"
    fi
    LOCAL_CONFIG_FILE="${secrets_dir}/config.local.yaml"
    if [ -f "$LOCAL_CONFIG_FILE" ]; then
        log_info "Applying local overrides from $LOCAL_CONFIG_FILE"
        eval "$(parse_yaml "$LOCAL_CONFIG_FILE")"
    fi

    MAS_INSTANCE_ID="$mas_instance_id"
    MAS_WORKSPACE_ID="$mas_workspace_id"
    MAS_WORKSPACE_NAME="$mas_workspace_name"
    OCP_PROJECT="$ocp_project"
    NET_DOMAIN="$net_domain"
    MAS_CATALOG_VERSION="$mas_catalog_version"
    MAS_CHANNEL="$mas_channel"
    MAS_OPERATIONAL_MODE="$mas_operational_mode"
    MAS_ADMIN_MODE="$mas_admin_mode"


    STORAGE_RWO_CLASS="$storage_rwo_class"
    STORAGE_RWX_CLASS="$storage_rwx_class"
    STORAGE_PIPELINE_CLASS="$storage_pipeline_class"
    STORAGE_ACCESS_MODE="$storage_access_mode"

    UDS_EMAIL="$uds_email"
    UDS_FIRSTNAME="$uds_firstname"
    UDS_LASTNAME="$uds_lastname"

    MONGODB_NAMESPACE="$mongodb_namespace"

    DB2_MANAGE="$db2_manage"
    DB2_CHANNEL="$db2_channel"
    DB2_NAMESPACE="$db2_namespace"
    DB2_TYPE="$db2_type"
    DB2_CPU_REQUESTS="$db2_cpu_requests"
    DB2_CPU_LIMITS="$db2_cpu_limits"
    DB2_MEMORY_REQUESTS="$db2_memory_requests"
    DB2_MEMORY_LIMITS="$db2_memory_limits"
    DB2_BACKUP_STORAGE="$db2_backup_storage"
    DB2_DATA_STORAGE="$db2_data_storage"
    DB2_LOGS_STORAGE="$db2_logs_storage"
    DB2_META_STORAGE="$db2_meta_storage"
    DB2_TEMP_STORAGE="$db2_temp_storage"

    MANAGE_INSTALL="$manage_install"
    MANAGE_CHANNEL="$manage_channel"
    MANAGE_JDBC="$manage_jdbc"
    MANAGE_COMPONENTS="$manage_components"
    MANAGE_SERVER_BUNDLE_SIZE="$manage_server_bundle_size"
    MANAGE_DEMODATA="$manage_demodata"

    SECRETS_DIR="${files_secrets_dir:-.secrets}"
    ENTITLEMENT_KEY_FILE="${files_entitlement_key:-entitlement-key}"
    PULL_SECRET_FILE="${files_pull_secret:-pull-secret}"
    LICENSE_FILE="${files_license:-license.dat}"
    KUBECONFIG_FILE="${files_kubeconfig:-kubeconfig}"

    CONTAINER_NAME="$container_name"
    CONTAINER_IMAGE="$container_image"
    CONTAINER_NETWORK="$container_network"
    CONTAINER_ENGINE_PREFERENCE="$container_engine"

    REGISTRY_CONFIGURE="${image_registry_configure:-true}"
    REGISTRY_STORAGE_CLASS="${image_registry_storage_class:-$storage_rwo_class}"
    REGISTRY_SIZE="${image_registry_size:-100Gi}"

    # Risolve i percorsi relativi dei file
    # I file sensibili sono relativi alla cartella dei secret (relativa allo script se non assoluta)
    if [[ "$SECRETS_DIR" != /* ]]; then
        SECRETS_DIR="${SCRIPT_DIR}/${SECRETS_DIR}"
    fi
    ENTITLEMENT_KEY_PATH="${SECRETS_DIR}/${ENTITLEMENT_KEY_FILE}"
    PULL_SECRET_PATH="${SECRETS_DIR}/${PULL_SECRET_FILE}"
    LICENSE_PATH="${SECRETS_DIR}/${LICENSE_FILE}"
    KUBECONFIG_PATH="${SECRETS_DIR}/${KUBECONFIG_FILE}"

    # Entitlement key: variabile d'ambiente, poi config.yaml, poi file in SECRETS_DIR
    if [ -n "$IBM_ENTITLEMENT_KEY" ]; then
        ENTITLEMENT_KEY_SOURCE="environment variable IBM_ENTITLEMENT_KEY"
    elif [ -n "$ibm_entitlement_key" ]; then
        IBM_ENTITLEMENT_KEY="$ibm_entitlement_key"
        ENTITLEMENT_KEY_SOURCE="config.yaml (ibm.entitlement_key)"
    elif [ -f "$ENTITLEMENT_KEY_PATH" ]; then
        IBM_ENTITLEMENT_KEY="$(tr -d '[:space:]' < "$ENTITLEMENT_KEY_PATH")"
        ENTITLEMENT_KEY_SOURCE="$ENTITLEMENT_KEY_PATH"
    fi

    # Usa lo stesso kubeconfig anche per i comandi oc eseguiti sull'host
    if [ -f "$KUBECONFIG_PATH" ]; then
        export KUBECONFIG="$KUBECONFIG_PATH"
    fi

    log_success "Configuration loaded successfully"
}

# Funzione per verificare i prerequisiti
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Verifica se OpenShift CLI è disponibile
    if ! command -v oc &> /dev/null; then
        log_error "OpenShift CLI (oc) is not installed or not in PATH"
        exit 1
    fi

    # Verifica se Docker o Podman sono disponibili in base alla preferenza
    if [ "$CONTAINER_ENGINE_PREFERENCE" = "docker" ]; then
        if command -v docker &> /dev/null; then
            CONTAINER_ENGINE="docker"
            log_info "Using Docker as container engine (preference)"
        else
            log_error "Docker specified in config but not found in PATH"
            exit 1
        fi
    elif [ "$CONTAINER_ENGINE_PREFERENCE" = "podman" ]; then
        if command -v podman &> /dev/null; then
            CONTAINER_ENGINE="podman"
            log_info "Using Podman as container engine (preference)"
        else
            log_error "Podman specified in config but not found in PATH"
            exit 1
        fi
    else
        # Auto-rilevamento con priorità Podman (comportamento predefinito)
        if command -v podman &> /dev/null; then
            CONTAINER_ENGINE="podman"
            log_info "Using Podman as container engine (auto-detected, priority choice)"
        elif command -v docker &> /dev/null; then
            CONTAINER_ENGINE="docker"
            log_info "Using Docker as container engine (auto-detected, fallback)"
        else
            log_error "Neither Docker nor Podman is installed or in PATH"
            log_error "Please install Docker or Podman to continue"
            exit 1
        fi
    fi

    # Verifica se è connesso al cluster OpenShift
    if ! oc get nodes &> /dev/null; then
        log_error "Not connected to OpenShift cluster. Please login with 'oc login'"
        exit 1
    fi

    log_success "Prerequisites check completed"
}

# Funzione per validare la configurazione
validate_config() {
    log_info "Validating configuration..."

    if [ -z "$IBM_ENTITLEMENT_KEY" ]; then
        log_error "IBM entitlement key not set: save it in $ENTITLEMENT_KEY_PATH (or use IBM_ENTITLEMENT_KEY / ibm.entitlement_key)"
        exit 1
    fi

    # Verifica i file richiesti
    if [ ! -f "$KUBECONFIG_PATH" ]; then
        log_error "Kubeconfig file not found: $KUBECONFIG_PATH"
        exit 1
    fi

    if [ ! -f "$PULL_SECRET_PATH" ]; then
        log_error "Pull secret file not found: $PULL_SECRET_PATH"
        exit 1
    fi

    if [ ! -f "$LICENSE_PATH" ]; then
        log_error "License file not found: $LICENSE_PATH"
        exit 1
    fi

    # Verifica le classi di storage
    if ! oc get storageclass "$STORAGE_RWO_CLASS" &> /dev/null; then
        log_error "Storage class '$STORAGE_RWO_CLASS' not found"
        log_info "Available storage classes:"
        oc get storageclass
        exit 1
    fi

    # Le applicazioni opzionali non sono ancora gestite dallo script
    local app
    for app in iot monitor predict optimizer assist visual_inspection facilities; do
        local var="applications_${app}"
        if [ "${!var}" = "true" ]; then
            log_warning "applications.${app} is set to true but is not supported by this script: it will NOT be installed"
        fi
    done

    log_success "Configuration validation completed"
}

# Funzione per configurare l'image registry interno di OpenShift
# Manage esegue build con output su ImageStream: senza registry fallisce con
# "Builds not complete" / InvalidOutputReference
configure_image_registry() {
    if [ "$REGISTRY_CONFIGURE" != "true" ]; then
        log_info "Skipping image registry configuration (image_registry.configure=false)"
        return 0
    fi

    log_info "Checking OpenShift integrated image registry..."

    local state
    state=$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}')
    if [ "$state" = "Managed" ]; then
        log_success "Image registry already enabled (managementState=Managed)"
        return 0
    fi

    log_info "Image registry is '$state': enabling it with a ${REGISTRY_SIZE} PVC on '$REGISTRY_STORAGE_CLASS'"

    if ! oc get pvc image-registry-storage -n openshift-image-registry &> /dev/null; then
        cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: image-registry-storage
  namespace: openshift-image-registry
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${REGISTRY_STORAGE_CLASS}
  resources:
    requests:
      storage: ${REGISTRY_SIZE}
EOF
    fi

    # Con un PVC ReadWriteOnce il registry deve avere 1 replica e strategia Recreate
    oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
        -p '{"spec":{"managementState":"Managed","replicas":1,"rolloutStrategy":"Recreate","storage":{"pvc":{"claim":"image-registry-storage"}}}}'

    log_info "Waiting for image registry to become available..."
    local i
    for i in $(seq 1 60); do
        if [ "$(oc get co image-registry -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" = "True" ] &&
           [ "$(oc get co image-registry -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')" = "False" ]; then
            log_success "Image registry configured"
            return 0
        fi
        sleep 10
    done

    log_error "Image registry did not become available within 10 minutes"
    oc get co image-registry
    exit 1
}

# Funzione per visualizzare il riepilogo della configurazione
display_summary() {
    echo ""
    echo "======================================"
    echo "Installazione Maximo Application Suite"
    echo "======================================"
    echo "Instance ID: $MAS_INSTANCE_ID"
    echo "Workspace ID: $MAS_WORKSPACE_ID"
    echo "Workspace Name: $MAS_WORKSPACE_NAME"
    echo "Catalog Version: $MAS_CATALOG_VERSION"
    echo "Channel: $MAS_CHANNEL"
    echo "Operational Mode: $MAS_OPERATIONAL_MODE"
    echo "Admin Mode: ${MAS_ADMIN_MODE:-<none>}"
    echo "RWO Storage Class: $STORAGE_RWO_CLASS"
    echo "RWX Storage Class: $STORAGE_RWX_CLASS"
    echo "MongoDB Namespace: $MONGODB_NAMESPACE"
    echo "DB2 Namespace: $DB2_NAMESPACE"
    echo "Manage Demo Data: ${MANAGE_DEMODATA:-false}"
    echo "Secrets Dir: $SECRETS_DIR"
    echo "Entitlement Key: from $ENTITLEMENT_KEY_SOURCE"
    echo "Kubeconfig: $KUBECONFIG_PATH"
    echo "Configure Image Registry: $REGISTRY_CONFIGURE (${REGISTRY_SIZE} on ${REGISTRY_STORAGE_CLASS})"
    echo "======================================"
    echo ""
}

# Funzione per ripulire le installazioni esistenti
cleanup_existing() {
    log_info "Cleaning up any existing MAS installations..."

    # Ripulisci il container
    $CONTAINER_ENGINE rm -f "$CONTAINER_NAME" &> /dev/null || true

    # Ripulisci i namespace
    EXISTING_NAMESPACES=$(oc get namespaces -o name | grep -E "(mas-|mongoce|db2u|ibm-sls)" | cut -d'/' -f2 || true)
    if [ ! -z "$EXISTING_NAMESPACES" ]; then
        log_info "Found existing MAS namespaces: $EXISTING_NAMESPACES"
        log_info "Deleting existing namespaces..."
        for ns in $EXISTING_NAMESPACES; do
            log_info "  Deleting namespace: $ns"
            oc delete namespace "$ns" --timeout=300s &
        done
        wait
    fi

    log_success "Cleanup completed"
}

# Funzione per configurare il container
setup_container() {
    log_info "Setting up MAS CLI container..."

    # Scarica l'immagine
    log_info "Pulling IBM MAS CLI image: $CONTAINER_IMAGE"
    $CONTAINER_ENGINE pull "$CONTAINER_IMAGE"

    # Avvia il container
    log_info "Starting container: $CONTAINER_NAME"
    if [ "$CONTAINER_ENGINE" = "podman" ]; then
        # Opzioni specifiche di Podman per migliore connettività OpenShift
        CONTAINER_ID=$($CONTAINER_ENGINE run -dit --name "$CONTAINER_NAME" --network host --privileged "$CONTAINER_IMAGE" bash)
    else
        # Opzioni Docker
        CONTAINER_ID=$($CONTAINER_ENGINE run -dit --name "$CONTAINER_NAME" --network "$CONTAINER_NETWORK" "$CONTAINER_IMAGE" bash)
    fi
    log_info "Container started: $CONTAINER_ID"

    # Configura le directory
    $CONTAINER_ENGINE exec "$CONTAINER_NAME" mkdir -p /root/.kube /mascli/masconfig

    # Copia i file
    log_info "Copying configuration files to container..."
    $CONTAINER_ENGINE cp "$KUBECONFIG_PATH" "${CONTAINER_NAME}:/root/.kube/config"
    $CONTAINER_ENGINE cp "$PULL_SECRET_PATH" "${CONTAINER_NAME}:/mascli/masconfig/pull-secret"
    $CONTAINER_ENGINE cp "$LICENSE_PATH" "${CONTAINER_NAME}:/mascli/masconfig/license.dat"

    # Testa la connettività
    log_info "Testing OpenShift connectivity from container..."
    if ! $CONTAINER_ENGINE exec "$CONTAINER_NAME" bash -c 'export KUBECONFIG=/root/.kube/config && oc get nodes' &> /dev/null; then
        log_error "Cannot connect to OpenShift from container"
        $CONTAINER_ENGINE rm -f "$CONTAINER_NAME"
        exit 1
    fi

    log_success "Container setup completed"
}

# Funzione per costruire il comando di installazione
build_install_command() {
    local cmd="mas install"
    cmd="$cmd --mas-catalog-version '$MAS_CATALOG_VERSION'"
    cmd="$cmd --ibm-entitlement-key \$IBM_ENTITLEMENT_KEY"
    cmd="$cmd --mas-channel '$MAS_CHANNEL'"
    cmd="$cmd --mas-instance-id '$MAS_INSTANCE_ID'"
    cmd="$cmd --mas-workspace-id '$MAS_WORKSPACE_ID'"
    cmd="$cmd --mas-workspace-name '$MAS_WORKSPACE_NAME'"

    if [ "$MAS_OPERATIONAL_MODE" = "non-prod" ]; then
        cmd="$cmd --non-prod"
    fi

    # Richiesto da MAS 9.2+, non supportato da 9.1 e precedenti
    if [ -n "$MAS_ADMIN_MODE" ]; then
        cmd="$cmd --admin-mode '$MAS_ADMIN_MODE'"
    fi

    cmd="$cmd --storage-class-rwo '$STORAGE_RWO_CLASS'"
    cmd="$cmd --storage-class-rwx '$STORAGE_RWX_CLASS'"
    cmd="$cmd --storage-pipeline '$STORAGE_PIPELINE_CLASS'"
    cmd="$cmd --storage-accessmode '$STORAGE_ACCESS_MODE'"
    cmd="$cmd --license-file '/mascli/masconfig/license.dat'"
    cmd="$cmd --uds-email '$UDS_EMAIL'"
    cmd="$cmd --uds-firstname '$UDS_FIRSTNAME'"
    cmd="$cmd --uds-lastname '$UDS_LASTNAME'"
    cmd="$cmd --mongodb-namespace '$MONGODB_NAMESPACE'"

    if [ "$MANAGE_INSTALL" = "true" ]; then
        cmd="$cmd --manage-channel '$MANAGE_CHANNEL'"
        cmd="$cmd --manage-jdbc '$MANAGE_JDBC'"
        cmd="$cmd --manage-components '$MANAGE_COMPONENTS'"
        cmd="$cmd --manage-server-bundle-size '$MANAGE_SERVER_BUNDLE_SIZE'"
        if [ "$MANAGE_DEMODATA" = "true" ]; then
            cmd="$cmd --manage-demodata"
        fi
    fi

    if [ "$DB2_MANAGE" = "true" ]; then
        cmd="$cmd --db2-manage"
        # Se vuoto viene usato il canale di default del catalogo
        if [ -n "$DB2_CHANNEL" ]; then
            cmd="$cmd --db2-channel '$DB2_CHANNEL'"
        fi
        cmd="$cmd --db2-namespace '$DB2_NAMESPACE'"
        cmd="$cmd --db2-type '$DB2_TYPE'"
        cmd="$cmd --db2-cpu-requests '$DB2_CPU_REQUESTS'"
        cmd="$cmd --db2-cpu-limits '$DB2_CPU_LIMITS'"
        cmd="$cmd --db2-memory-requests '$DB2_MEMORY_REQUESTS'"
        cmd="$cmd --db2-memory-limits '$DB2_MEMORY_LIMITS'"
        cmd="$cmd --db2-backup-storage '$DB2_BACKUP_STORAGE'"
        cmd="$cmd --db2-data-storage '$DB2_DATA_STORAGE'"
        cmd="$cmd --db2-logs-storage '$DB2_LOGS_STORAGE'"
        cmd="$cmd --db2-meta-storage '$DB2_META_STORAGE'"
        cmd="$cmd --db2-temp-storage '$DB2_TEMP_STORAGE'"
    fi

    cmd="$cmd --accept-license --no-confirm"

    echo "$cmd"
}

# Funzione per eseguire l'installazione
run_installation() {
    log_info "Starting MAS installation..."
    log_info "This will take approximately 60-120 minutes to complete."

    local install_cmd=$(build_install_command)

    log_info "Installation command:"
    echo "$install_cmd"
    echo ""

    # Esegui l'installazione
    $CONTAINER_ENGINE exec "$CONTAINER_NAME" bash -c "
        export KUBECONFIG=/root/.kube/config
        export IBM_ENTITLEMENT_KEY='$IBM_ENTITLEMENT_KEY'
        $install_cmd
    "

    return $?
}

# Funzione per visualizzare il messaggio di completamento
display_completion() {
    local exit_code=$1

    if [ $exit_code -eq 0 ]; then
        echo ""
        log_success "MAS Installation completed successfully!"
        echo ""
        echo "Prossimi passi:"
        echo "1. Check MAS console: https://home.${MAS_WORKSPACE_ID}.${MAS_INSTANCE_ID}.apps.${OCP_PROJECT}.${NET_DOMAIN}"
        echo "2. Monitor pods: oc get pods -A | grep mas"
        echo "3. Check routes: oc get routes -A | grep mas"
        echo ""
    else
        echo ""
        log_error "MAS Installation failed with exit code: $exit_code"
        log_info "Check the logs above for details"
        echo ""
    fi

    log_info "Container '$CONTAINER_NAME' is still running for troubleshooting"
    log_info "To access: $CONTAINER_ENGINE exec -it $CONTAINER_NAME bash"
    log_info "To remove: $CONTAINER_ENGINE rm -f $CONTAINER_NAME"
}

# Esecuzione principale
main() {
    echo "IBM Maximo Application Suite - Script di Installazione Configurabile"
    echo "============================================================="

    load_config
    check_prerequisites
    validate_config
    display_summary

    # Richiesta di conferma (auto-confermato)
    log_info "Procedendo automaticamente con l'installazione..."

    cleanup_existing
    configure_image_registry
    setup_container

    if run_installation; then
        display_completion 0
        exit 0
    else
        display_completion $?
        exit 1
    fi
}

# Esegui la funzione principale
main "$@"
