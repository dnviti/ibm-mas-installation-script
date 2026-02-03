#!/usr/bin/env bash

# Script di Installazione Maximo Application Suite
# Script di installazione configurabile tramite configurazione YAML

set -e

# Directory dello script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LICENSES_DIR="$SCRIPT_DIR/licenses"
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
    sed -ne "s|^\($s\):|\1|" \
        -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p" $1 |
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

    # Utilizza parsing YAML di base
    eval $(parse_yaml "$CONFIG_FILE")

    MAS_INSTANCE_ID="$mas_instance_id"
    MAS_WORKSPACE_ID="$mas_workspace_id"
    MAS_WORKSPACE_NAME="$mas_workspace_name"
    OCP_PROJECT="$ocp_project"
    NET_DOMAIN="$net_domain"
    MAS_CATALOG_VERSION="$mas_catalog_version"
    MAS_CHANNEL="$mas_channel"
    MAS_OPERATIONAL_MODE="$mas_operational_mode"

    IBM_ENTITLEMENT_KEY="$ibm_entitlement_key"

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

    PULL_SECRET_FILE="$files_pull_secret"
    LICENSE_FILE="$files_license"

    CONTAINER_NAME="$container_name"
    CONTAINER_IMAGE="$container_image"
    CONTAINER_NETWORK="$container_network"
    CONTAINER_ENGINE_PREFERENCE="$container_engine"

    # Risolve i percorsi relativi dei file
    PULL_SECRET_PATH="${LICENSES_DIR}/${PULL_SECRET_FILE}"
    LICENSE_PATH="${LICENSES_DIR}/${LICENSE_FILE}"

    log_success "Configuration loaded successfully"
}

# Funzione per verificare i prerequisiti
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Verifica se il file di configurazione esiste
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

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

    # Verifica i file richiesti
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

    log_success "Configuration validation completed"
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
    echo "RWO Storage Class: $STORAGE_RWO_CLASS"
    echo "RWX Storage Class: $STORAGE_RWX_CLASS"
    echo "MongoDB Namespace: $MONGODB_NAMESPACE"
    echo "DB2 Namespace: $DB2_NAMESPACE"
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
    $CONTAINER_ENGINE cp "${SCRIPT_DIR}/kubeconfig" "${CONTAINER_NAME}:/root/.kube/config"
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
    fi

    if [ "$DB2_MANAGE" = "true" ]; then
        cmd="$cmd --db2-manage"
        cmd="$cmd --db2-channel '$DB2_CHANNEL'"
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

    check_prerequisites
    load_config
    validate_config
    display_summary

    # Richiesta di conferma (auto-confermato)
    log_info "Procedendo automaticamente con l'installazione..."

    cleanup_existing
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
