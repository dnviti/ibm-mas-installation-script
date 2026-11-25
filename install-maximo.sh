#!/usr/bin/env bash

# Script di Installazione Maximo Application Suite
# Script di installazione configurabile tramite configurazione YAML
#
# Fasi: preflight (controlli in sola lettura), cluster (Longhorn, StorageClass di default,
# image registry), install (mas install). Tutti i comandi oc/helm girano DENTRO il
# container MAS CLI: sull'host servono solo podman/docker e il file kubeconfig.

set -e

# Directory dello script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"

# Fasi disponibili (nell'ordine di esecuzione)
ALL_PHASES="preflight cluster install"

# Opzioni da riga di comando
ONLY_PHASES=""
SKIP_PHASES=""
SELECTED_PHASES=""
OPT_CLEAN=false
OPT_YES=false

# Stato del container (rimosso all'uscita se la fase install non è partita)
CONTAINER_STARTED=false
KEEP_CONTAINER=false
LONGHORN_STATE=""

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

# Funzione per mostrare l'help
usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Installs IBM Maximo Application Suite on OpenShift. The only inputs needed on the host are
a container engine (podman/docker) and the kubeconfig file configured in config.yaml:
every oc/helm command runs inside the MAS CLI container.

Phases (run in this order, all enabled by default):
  preflight   read-only cluster checks (version, nodes, resources, DNS, permissions, operators)
  cluster     Longhorn (Helm), Longhorn settings, default StorageClass, image registry
  install     mas install (Db2, MongoDB, SLS, MAS Core, Manage)

Options:
  --only <list>   run only the given comma-separated phases (e.g. --only preflight,cluster)
  --skip <list>   skip the given comma-separated phases (applied after --only)
  --clean         delete existing MAS namespaces before cluster/install (destructive);
                  asks to type the instance id unless --yes is given
  --yes           do not ask for confirmation (required by --clean when stdin is not a terminal)
  -h, --help      show this help
EOF
}

# Verifica un elenco di fasi separate da virgola
# $1 = nome dell'opzione, $2 = elenco
validate_phase_list() {
    local option=$1 list=$2 item
    local -a items
    IFS=',' read -r -a items <<< "$list"
    if [ ${#items[@]} -eq 0 ]; then
        log_error "Option $option requires a non-empty list of phases (valid: ${ALL_PHASES// /, })"
        exit 2
    fi
    for item in "${items[@]}"; do
        case "$item" in
            preflight|cluster|install) ;;
            *)
                log_error "Invalid phase '$item' for $option (valid: ${ALL_PHASES// /, })"
                exit 2
                ;;
        esac
    done
}

# Analizza gli argomenti e calcola le fasi selezionate
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --only|--skip)
                if [ $# -lt 2 ]; then
                    log_error "Option $1 requires an argument"
                    exit 2
                fi
                validate_phase_list "$1" "$2"
                if [ "$1" = "--only" ]; then ONLY_PHASES="$2"; else SKIP_PHASES="$2"; fi
                shift 2
                ;;
            --only=*|--skip=*)
                validate_phase_list "${1%%=*}" "${1#*=}"
                if [ "${1%%=*}" = "--only" ]; then ONLY_PHASES="${1#*=}"; else SKIP_PHASES="${1#*=}"; fi
                shift
                ;;
            --clean)
                OPT_CLEAN=true
                shift
                ;;
            --yes)
                OPT_YES=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage >&2
                exit 2
                ;;
        esac
    done

    local phase
    for phase in $ALL_PHASES; do
        if [ -n "$ONLY_PHASES" ] && [[ ",$ONLY_PHASES," != *",$phase,"* ]]; then
            continue
        fi
        if [[ ",$SKIP_PHASES," == *",$phase,"* ]]; then
            continue
        fi
        SELECTED_PHASES="${SELECTED_PHASES:+$SELECTED_PHASES }$phase"
    done

    if [ -z "$SELECTED_PHASES" ]; then
        log_error "No phase left to run after applying --only/--skip"
        exit 2
    fi

    if [ "$OPT_CLEAN" = "true" ] && ! phase_enabled cluster && ! phase_enabled install; then
        log_error "--clean only makes sense together with the cluster or install phase"
        exit 2
    fi

    if [ "$OPT_CLEAN" = "true" ] && [ "$OPT_YES" != "true" ] && [ ! -t 0 ]; then
        log_error "--clean needs a confirmation: run from a terminal or pass --yes"
        exit 2
    fi
}

# Restituisce 0 se la fase è tra quelle selezionate
phase_enabled() {
    [[ " $SELECTED_PHASES " == *" $1 "* ]]
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

    # Pre-configurazione del cluster (sezione "cluster" di config.yaml)
    CLUSTER_CONFIGURE="${cluster_configure:-true}"
    CLUSTER_DEFAULT_STORAGE_CLASS="${cluster_default_storage_class:-$storage_rwo_class}"
    HELM_VERSION="${cluster_helm_version:-3.19.0}"
    LONGHORN_INSTALL="${cluster_longhorn_install:-true}"
    LONGHORN_VERSION="${cluster_longhorn_version:-1.13.0}"
    LONGHORN_NAMESPACE="${cluster_longhorn_namespace:-longhorn-system}"
    LONGHORN_REPLICA_COUNT="${cluster_longhorn_replica_count:-1}"
    LONGHORN_OAUTH_PROXY_TAG="$cluster_longhorn_oauth_proxy_tag"
    # Se vuote, le impostazioni Longhorn corrispondenti non vengono toccate
    LONGHORN_PRIORITY_CLASS="$cluster_longhorn_settings_priority_class"
    LONGHORN_MIN_AVAILABLE_PERCENT="$cluster_longhorn_settings_storage_minimal_available_percentage"
    PREFLIGHT_MIN_CPU="${cluster_preflight_min_cpu:-16}"
    PREFLIGHT_MIN_MEMORY_GIB="${cluster_preflight_min_memory_gib:-48}"
    PREFLIGHT_CHECK_DNS="${cluster_preflight_check_dns:-true}"

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

    log_success "Configuration loaded successfully"
}

# Funzione per verificare i prerequisiti (sull'host servono solo il container engine e il kubeconfig)
check_prerequisites() {
    log_info "Checking prerequisites..."

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

    log_success "Prerequisites check completed"
}

# Funzione per validare la configurazione
validate_config() {
    log_info "Validating configuration..."

    # Il kubeconfig serve a tutte le fasi
    if [ ! -f "$KUBECONFIG_PATH" ]; then
        log_error "Kubeconfig file not found: $KUBECONFIG_PATH"
        exit 1
    fi

    # Segreti e file di licenza servono solo a mas install
    if phase_enabled install; then
        if [ -z "$IBM_ENTITLEMENT_KEY" ]; then
            log_error "IBM entitlement key not set: save it in $ENTITLEMENT_KEY_PATH (or use IBM_ENTITLEMENT_KEY / ibm.entitlement_key)"
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

        # Le applicazioni opzionali non sono ancora gestite dallo script
        local app
        for app in iot monitor predict optimizer assist visual_inspection facilities; do
            local var="applications_${app}"
            if [ "${!var}" = "true" ]; then
                log_warning "applications.${app} is set to true but is not supported by this script: it will NOT be installed"
            fi
        done
    fi

    # Valori della sezione cluster (usati dalle fasi preflight e cluster)
    if phase_enabled preflight || phase_enabled cluster; then
        local number='^[0-9]+(\.[0-9]+)?$'
        if ! [[ "$PREFLIGHT_MIN_CPU" =~ $number ]] || ! [[ "$PREFLIGHT_MIN_MEMORY_GIB" =~ $number ]]; then
            log_error "cluster.preflight.min_cpu and min_memory_gib must be numbers"
            exit 1
        fi
        if [ "$PREFLIGHT_CHECK_DNS" != "true" ] && [ "$PREFLIGHT_CHECK_DNS" != "false" ]; then
            log_error "cluster.preflight.check_dns must be true or false"
            exit 1
        fi
    fi

    if phase_enabled cluster; then
        local semver='^[0-9]+\.[0-9]+\.[0-9]+$'
        if ! [[ "$HELM_VERSION" =~ $semver ]] || ! [[ "$LONGHORN_VERSION" =~ $semver ]]; then
            log_error "cluster.helm_version and cluster.longhorn.version must look like 1.2.3"
            exit 1
        fi
        if ! [[ "$LONGHORN_REPLICA_COUNT" =~ ^[1-9][0-9]*$ ]]; then
            log_error "cluster.longhorn.replica_count must be a positive integer"
            exit 1
        fi
        if ! [[ "$LONGHORN_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
            log_error "cluster.longhorn.namespace is not a valid namespace name: $LONGHORN_NAMESPACE"
            exit 1
        fi
        if [ -n "$LONGHORN_PRIORITY_CLASS" ] && ! [[ "$LONGHORN_PRIORITY_CLASS" =~ ^[A-Za-z0-9._-]+$ ]]; then
            log_error "cluster.longhorn.settings.priority_class contains invalid characters"
            exit 1
        fi
        if [ -n "$LONGHORN_MIN_AVAILABLE_PERCENT" ] &&
           { ! [[ "$LONGHORN_MIN_AVAILABLE_PERCENT" =~ ^[0-9]+$ ]] || [ "$LONGHORN_MIN_AVAILABLE_PERCENT" -gt 100 ]; }; then
            log_error "cluster.longhorn.settings.storage_minimal_available_percentage must be an integer between 0 and 100"
            exit 1
        fi
        if [ -z "$CLUSTER_DEFAULT_STORAGE_CLASS" ]; then
            log_error "No default StorageClass configured (cluster.default_storage_class / storage.rwo_class)"
            exit 1
        fi
    fi

    log_success "Configuration validation completed"
}

# Esegue un comando dentro il container MAS CLI con il kubeconfig copiato nel container
# (unico punto di accesso al cluster: sull'host non serve oc). Lo stdin è inoltrato.
container_exec() {
    $CONTAINER_ENGINE exec -i -e KUBECONFIG=/root/.kube/config "$CONTAINER_NAME" "$@"
}

# Attende che un comando abbia successo
# $1 = descrizione, $2 = tentativi, $3 = intervallo (s), resto = comando (stdout/stderr scartati)
wait_for() {
    local desc=$1 attempts=$2 interval=$3 i
    shift 3
    log_info "Waiting for $desc..."
    for i in $(seq 1 "$attempts"); do
        if "$@" > /dev/null 2>&1; then
            log_success "$desc: ready"
            return 0
        fi
        sleep "$interval"
    done
    log_error "Timed out after $((attempts * interval))s waiting for $desc"
    return 1
}

# Versione OpenShift del cluster (es. 4.22.14)
get_cluster_version() {
    container_exec oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null
}

# Fase preflight: controlli in SOLA LETTURA sul cluster
run_preflight() {
    log_info "Running preflight checks (read-only)..."
    local failures=0

    # 1. Versione del cluster
    local cv_version cv_available
    cv_version=$(get_cluster_version) || cv_version=""
    if [ -z "$cv_version" ]; then
        log_error "Cannot read the ClusterVersion (is the kubeconfig valid and cluster-admin?)"
        failures=$((failures + 1))
    else
        cv_available=$(container_exec oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null) || cv_available=""
        if [ "$cv_available" = "True" ]; then
            log_success "OpenShift version $cv_version (ClusterVersion Available)"
        else
            log_error "ClusterVersion $cv_version is not Available (Available=${cv_available:-unknown})"
            failures=$((failures + 1))
        fi
    fi

    # 2. Nodi Ready e risorse allocabili
    local node_rows node_summary total ready cpu mem notready
    node_rows=$(container_exec oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.allocatable.cpu}{"\t"}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null) || node_rows=""
    node_summary=$(awk -F'\t' '
        function cpu(v) { if (v ~ /m$/) { sub(/m$/, "", v); return v / 1000 } return v + 0 }
        function mem(v,  n) {
            n = v + 0
            if (v ~ /Ki$/) return n / 1048576
            if (v ~ /Mi$/) return n / 1024
            if (v ~ /Gi$/) return n
            if (v ~ /Ti$/) return n * 1024
            if (v ~ /[kK]$/) return n * 1000 / 1073741824
            if (v ~ /M$/) return n * 1000000 / 1073741824
            if (v ~ /G$/) return n * 1000000000 / 1073741824
            return n / 1073741824
        }
        NF >= 4 {
            total++
            if ($2 == "True") { ready++; c += cpu($3); m += mem($4) }
            else { names = names (names == "" ? "" : ",") $1 }
        }
        END { printf "%d %d %.2f %.2f %s\n", total, ready, c, m, (names == "" ? "-" : names) }
    ' <<< "$node_rows")
    read -r total ready cpu mem notready <<< "$node_summary"
    if [ "${total:-0}" -eq 0 ]; then
        log_error "No node found in the cluster"
        failures=$((failures + 1))
    else
        if [ "$ready" -eq "$total" ]; then
            log_success "Nodes Ready: $ready/$total"
        else
            log_error "Nodes not Ready ($ready/$total Ready): $notready"
            failures=$((failures + 1))
        fi
        if awk -v a="$cpu" -v b="$PREFLIGHT_MIN_CPU" 'BEGIN { exit !(a + 0 >= b + 0) }'; then
            log_success "Allocatable CPU: $cpu (minimum $PREFLIGHT_MIN_CPU)"
        else
            log_error "Allocatable CPU $cpu is below the minimum $PREFLIGHT_MIN_CPU (cluster.preflight.min_cpu)"
            failures=$((failures + 1))
        fi
        if awk -v a="$mem" -v b="$PREFLIGHT_MIN_MEMORY_GIB" 'BEGIN { exit !(a + 0 >= b + 0) }'; then
            log_success "Allocatable memory: ${mem} GiB (minimum $PREFLIGHT_MIN_MEMORY_GIB)"
        else
            log_error "Allocatable memory ${mem} GiB is below the minimum $PREFLIGHT_MIN_MEMORY_GIB (cluster.preflight.min_memory_gib)"
            failures=$((failures + 1))
        fi
    fi

    # 3. DNS: api.<dominio> e un host *.apps tramite l'ingress domain del cluster
    if [ "$PREFLIGHT_CHECK_DNS" = "true" ]; then
        local server api_host apps_domain host
        server=$(container_exec oc whoami --show-server 2>/dev/null) || server=""
        api_host="${server#*://}"
        api_host="${api_host%%[:/]*}"
        apps_domain=$(container_exec oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null) || apps_domain=""
        if ! container_exec bash -c 'command -v getent' > /dev/null 2>&1; then
            log_warning "getent not available in the container: DNS checks skipped"
        else
            if [ -z "$api_host" ]; then
                log_error "Cannot determine the API server host from the kubeconfig"
                failures=$((failures + 1))
            elif [[ "$api_host" =~ ^[0-9.]+$ ]] || [[ "$api_host" == *:* ]]; then
                log_info "API server is an IP address ($api_host): DNS check skipped"
            elif container_exec getent hosts "$api_host" > /dev/null 2>&1; then
                log_success "DNS resolves $api_host"
            else
                log_error "DNS does not resolve the API host: $api_host"
                failures=$((failures + 1))
            fi
            if [ -z "$apps_domain" ]; then
                log_error "Cannot read the ingress domain (ingresses.config.openshift.io/cluster)"
                failures=$((failures + 1))
            else
                host="mas-preflight-check.${apps_domain}"
                if container_exec getent hosts "$host" > /dev/null 2>&1; then
                    log_success "DNS resolves *.${apps_domain} (tested $host)"
                else
                    log_error "DNS does not resolve $host: the wildcard *.${apps_domain} must point to the cluster ingress"
                    failures=$((failures + 1))
                fi
            fi
        fi
    else
        log_info "DNS checks disabled (cluster.preflight.check_dns=false)"
    fi

    # 4. Permessi cluster-admin
    local can_admin
    can_admin=$(container_exec oc auth can-i '*' '*' 2>/dev/null) || can_admin=""
    if [ "$can_admin" = "yes" ]; then
        log_success "Current user has cluster-admin permissions"
    else
        log_error "Current user cannot do '*' on '*' (cluster-admin required)"
        failures=$((failures + 1))
    fi

    # 5. ClusterOperator non degradati / non disponibili
    local co_rows co_bad
    if co_rows=$(container_exec oc get clusteroperators -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Degraded")].status}{"\t"}{.status.conditions[?(@.type=="Available")].status}{"\n"}{end}' 2>/dev/null) && [ -n "$co_rows" ]; then
        co_bad=$(awk -F'\t' '$2 == "True" || $3 == "False" { printf "%s%s", (n++ ? ", " : ""), $1 }' <<< "$co_rows")
        if [ -z "$co_bad" ]; then
            log_success "All ClusterOperators are Available and not Degraded"
        else
            log_error "ClusterOperators degraded or not available: $co_bad"
            failures=$((failures + 1))
        fi
    else
        log_error "Cannot list ClusterOperators"
        failures=$((failures + 1))
    fi

    if [ "$failures" -gt 0 ]; then
        log_error "Preflight failed: $failures check(s) did not pass"
        exit 1
    fi
    log_success "Preflight checks passed"
}

# Installa Helm 3 nel container se manca (release fissata, sha256 verificato dal file pubblicato)
ensure_helm() {
    if container_exec bash -c 'command -v helm' > /dev/null 2>&1; then
        log_info "helm already available in the container: $(container_exec helm version --short 2>/dev/null || echo unknown)"
        return 0
    fi

    log_info "helm not found in the container: downloading Helm v${HELM_VERSION} from get.helm.sh (sha256 verified)"
    local script
    script=$(cat <<'EOF'
set -euo pipefail
v="$1"
case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
if command -v curl > /dev/null; then
    dl() { curl -fsSL -o "$2" "$1"; }
elif command -v wget > /dev/null; then
    dl() { wget -q -O "$2" "$1"; }
else
    echo "Neither curl nor wget is available in the container" >&2
    exit 1
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
f="helm-v${v}-linux-${arch}.tar.gz"
dl "https://get.helm.sh/${f}" "$f"
dl "https://get.helm.sh/${f}.sha256sum" "${f}.sha256sum"
expected=$(awk '{print $1; exit}' "${f}.sha256sum")
if ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Invalid published checksum for ${f}" >&2
    exit 1
fi
echo "${expected}  ${f}" | sha256sum -c - > /dev/null
tar -xzf "$f" "linux-${arch}/helm"
mv "linux-${arch}/helm" /usr/local/bin/helm
chmod 0755 /usr/local/bin/helm
EOF
)
    if ! container_exec bash -c "$script" bash "$HELM_VERSION"; then
        log_error "Could not install Helm v${HELM_VERSION} in the container"
        exit 1
    fi
    log_success "Helm installed in the container: $(container_exec helm version --short 2>/dev/null || echo unknown)"
}

# Stato di Longhorn nel namespace configurato. Fail closed: un errore API o una release Helm
# in stato anomalo interrompono lo script invece di essere scambiati per "non installato".
# Imposta LONGHORN_STATE: helm (release deployed), external (DaemonSet senza release Helm), absent
longhorn_detect() {
    local ns="$LONGHORN_NAMESPACE" statuses daemonsets
    if ! statuses=$(container_exec oc get secrets -n "$ns" -l owner=helm,name=longhorn -o jsonpath='{range .items[*]}{.metadata.labels.status}{"\n"}{end}'); then
        log_error "Cannot query the Helm release secrets in '$ns': refusing to guess whether Longhorn is installed"
        exit 1
    fi
    statuses=$(tr -s '[:space:]' '\n' <<< "$statuses" | sed '/^$/d')

    if grep -qx deployed <<< "$statuses"; then
        LONGHORN_STATE=helm
        return 0
    fi
    if [ -n "$statuses" ]; then
        log_error "Helm release 'longhorn' in '$ns' is not in 'deployed' state (found: $(tr '\n' ' ' <<< "$statuses"))"
        log_error "Fix it first (inside the container: 'helm -n $ns status longhorn', then rollback or uninstall) and rerun"
        exit 1
    fi

    if ! daemonsets=$(container_exec oc get daemonsets -n "$ns" -o name); then
        log_error "Cannot list the DaemonSets in '$ns': refusing to guess whether Longhorn is installed"
        exit 1
    fi
    if grep -qx 'daemonset.apps/longhorn-manager' <<< "$daemonsets"; then
        LONGHORN_STATE=external
    else
        LONGHORN_STATE=absent
    fi
}

# Longhorn pronto: CSI driver, deployment (longhorn-ui escluso) e daemonset al completo, nodi Longhorn Ready
longhorn_ready() {
    local ns="$LONGHORN_NAMESPACE" out
    container_exec oc get csidriver driver.longhorn.io > /dev/null 2>&1 || return 1
    container_exec oc get deployment csi-provisioner -n "$ns" > /dev/null 2>&1 || return 1

    out=$(container_exec oc get deployments -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.readyReplicas}{"/"}{.spec.replicas}{"\n"}{end}' 2>/dev/null) || return 1
    awk '$1 != "longhorn-ui" { n++; split($2, a, "/"); if ((a[1] + 0) != (a[2] + 0)) bad = 1 } END { exit (bad || n == 0) }' <<< "$out" || return 1

    out=$(container_exec oc get daemonsets -n "$ns" -o jsonpath='{range .items[*]}{.status.numberReady}{"/"}{.status.desiredNumberScheduled}{"\n"}{end}' 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    awk -F/ '($1 + 0) != ($2 + 0) { bad = 1 } END { exit bad }' <<< "$out" || return 1

    out=$(container_exec oc get nodes.longhorn.io -n "$ns" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    awk '$1 != "True" { bad = 1 } END { exit bad }' <<< "$out"
}

# Installa Longhorn con Helm (valori per SNO). Un'installazione esistente non viene mai aggiornata.
install_longhorn() {
    if [ "$LONGHORN_INSTALL" != "true" ]; then
        log_info "Skipping Longhorn installation and settings (cluster.longhorn.install=false)"
        return 0
    fi

    longhorn_detect
    case "$LONGHORN_STATE" in
        helm)
            log_info "Longhorn already installed via Helm in '$LONGHORN_NAMESPACE': skipping helm install (an existing install is never upgraded)"
            ;;
        external)
            log_warning "Longhorn is present in '$LONGHORN_NAMESPACE' but not managed by a Helm release 'longhorn': skipping helm install"
            ;;
        absent)
            local tag="$LONGHORN_OAUTH_PROXY_TAG"
            if [ -z "$tag" ]; then
                local cv
                cv=$(get_cluster_version) || cv=""
                tag=$(cut -d. -f1,2 <<< "$cv")
                if ! [[ "$tag" =~ ^[0-9]+\.[0-9]+$ ]]; then
                    log_error "Cannot derive the oauth-proxy tag from the cluster version ('$cv'): set cluster.longhorn.oauth_proxy_tag"
                    exit 1
                fi
                log_info "oauth-proxy image tag derived from the cluster version: $tag"
            fi

            ensure_helm

            log_info "Installing Longhorn v${LONGHORN_VERSION} in '$LONGHORN_NAMESPACE' (replicas: $LONGHORN_REPLICA_COUNT)..."
            local default_class=false
            if [ "$CLUSTER_DEFAULT_STORAGE_CLASS" = "longhorn" ]; then
                default_class=true
            fi
            # Le impostazioni vanno nei values: una patch diretta verrebbe riportata al valore
            # del chart (ConfigMap longhorn-default-setting) a ogni riavvio di longhorn-manager
            local extra_settings=""
            if [ -n "$LONGHORN_PRIORITY_CLASS" ]; then
                extra_settings="${extra_settings}"$'\n'"  priorityClass: \"${LONGHORN_PRIORITY_CLASS}\""
            fi
            if [ -n "$LONGHORN_MIN_AVAILABLE_PERCENT" ]; then
                extra_settings="${extra_settings}"$'\n'"  storageMinimalAvailablePercentage: ${LONGHORN_MIN_AVAILABLE_PERCENT}"
            fi
            container_exec bash -c 'cat > /tmp/longhorn-values.yaml' <<EOF
openshift:
  enabled: true
image:
  openshift:
    oauthProxy:
      registry: quay.io
      repository: openshift/origin-oauth-proxy
      tag: "${tag}"
persistence:
  defaultClass: ${default_class}
  defaultClassReplicaCount: ${LONGHORN_REPLICA_COUNT}
defaultSettings:
  defaultReplicaCount: '{"v1":"${LONGHORN_REPLICA_COUNT}","v2":"${LONGHORN_REPLICA_COUNT}"}'${extra_settings}
EOF
            if ! container_exec helm repo add longhorn https://charts.longhorn.io --force-update ||
               ! container_exec helm repo update longhorn ||
               ! container_exec helm install longhorn longhorn/longhorn \
                    --version "$LONGHORN_VERSION" \
                    --namespace "$LONGHORN_NAMESPACE" --create-namespace \
                    --values /tmp/longhorn-values.yaml; then
                log_error "Helm installation of Longhorn failed"
                exit 1
            fi
            container_exec rm -f /tmp/longhorn-values.yaml
            LONGHORN_STATE=installed
            log_success "Longhorn Helm release installed"
            ;;
    esac

    wait_for "Longhorn workloads and nodes" 90 10 longhorn_ready || {
        container_exec oc get pods -n "$LONGHORN_NAMESPACE" || true
        exit 1
    }

    # La UI non blocca l'installazione: solo un avviso
    local ui_ready
    ui_ready=$(container_exec oc get deployment longhorn-ui -n "$LONGHORN_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || ui_ready=""
    if [ "${ui_ready:-0}" -lt 1 ] 2>/dev/null; then
        log_warning "longhorn-ui is not ready yet (not required for the installation to proceed)"
    fi
}

# Avvisa se la ConfigMap longhorn-default-setting (valori del chart Helm) ha un valore diverso:
# longhorn-manager la risincronizza a ogni riavvio e annullerebbe la patch
# $1 = setting Longhorn, $2 = valore desiderato, $3 = chiave Helm in defaultSettings
warn_if_chart_default_differs() {
    local name=$1 value=$2 helm_key=$3 cm chart_value
    cm=$(container_exec oc get configmap longhorn-default-setting -n "$LONGHORN_NAMESPACE" -o jsonpath='{.data.default-setting\.yaml}' 2>/dev/null) || return 0
    chart_value=$(sed -n "s/^${name}:[[:space:]]*//p" <<< "$cm" | head -n 1 | tr -d "\"'")
    if [ -n "$chart_value" ] && [ "$chart_value" != "$value" ]; then
        log_warning "ConfigMap longhorn-default-setting has $name='$chart_value': it will REVERT the patch at the next longhorn-manager restart"
        log_warning "  Make it permanent (inside the container): helm upgrade longhorn longhorn/longhorn -n $LONGHORN_NAMESPACE --version <installed-version> --reuse-values --set-string defaultSettings.${helm_key}=${value}"
    fi
}

# Imposta una setting Longhorn solo se il valore è diverso
# $1 = nome della setting, $2 = valore desiderato, $3 = chiave Helm in defaultSettings
set_longhorn_setting() {
    local name=$1 value=$2 helm_key=$3 current
    if ! current=$(container_exec oc get settings.longhorn.io "$name" -n "$LONGHORN_NAMESPACE" -o jsonpath='{.value}' 2>/dev/null); then
        log_warning "Longhorn setting '$name' not found in '$LONGHORN_NAMESPACE': skipped"
        return 0
    fi
    if [ "$current" = "$value" ]; then
        log_info "Longhorn setting $name already '$value'"
    elif container_exec oc patch settings.longhorn.io "$name" -n "$LONGHORN_NAMESPACE" --type merge -p "{\"value\":\"${value}\"}" > /dev/null; then
        log_success "Longhorn setting $name: '$current' -> '$value'"
    else
        log_warning "Could not set Longhorn setting $name to '$value' (Longhorn may require all volumes detached): left at '$current'"
        return 0
    fi
    warn_if_chart_default_differs "$name" "$value" "$helm_key"
}

# Allinea le impostazioni Longhorn configurate (mai con cluster.longhorn.install=false)
configure_longhorn_settings() {
    if [ "$LONGHORN_INSTALL" != "true" ]; then
        return 0
    fi

    if [ "$LONGHORN_STATE" = "installed" ]; then
        log_info "Longhorn settings applied through the Helm values at install time"
    else
        if [ -n "$LONGHORN_PRIORITY_CLASS" ]; then
            set_longhorn_setting priority-class "$LONGHORN_PRIORITY_CLASS" priorityClass
        fi
        if [ -n "$LONGHORN_MIN_AVAILABLE_PERCENT" ]; then
            set_longhorn_setting storage-minimal-available-percentage "$LONGHORN_MIN_AVAILABLE_PERCENT" storageMinimalAvailablePercentage
        fi
    fi

    # I parametri della StorageClass sono immutabili: avvisa se il numero di repliche non coincide
    local sc_replicas
    sc_replicas=$(container_exec oc get storageclass longhorn -o jsonpath='{.parameters.numberOfReplicas}' 2>/dev/null) || sc_replicas=""
    if [ -n "$sc_replicas" ] && [ "$sc_replicas" != "$LONGHORN_REPLICA_COUNT" ]; then
        log_warning "StorageClass 'longhorn' has numberOfReplicas=$sc_replicas but cluster.longhorn.replica_count=$LONGHORN_REPLICA_COUNT (parameters are immutable: recreate the StorageClass before creating PVCs)"
    fi
}

# Garantisce che la StorageClass configurata sia l'UNICA di default
ensure_default_storage_class() {
    local sc="$CLUSTER_DEFAULT_STORAGE_CLASS"
    wait_for "StorageClass '$sc'" 30 10 container_exec oc get storageclass "$sc" || {
        log_error "StorageClass '$sc' does not exist"
        exit 1
    }

    local main_key="storageclass.kubernetes.io/is-default-class"
    local beta_key="storageclass.beta.kubernetes.io/is-default-class"

    if [ "$(container_exec oc get storageclass "$sc" -o jsonpath="{.metadata.annotations.${main_key//./\\.}}" 2>/dev/null)" != "true" ]; then
        container_exec oc patch storageclass "$sc" --type merge \
            -p "{\"metadata\":{\"annotations\":{\"${main_key}\":\"true\"}}}" > /dev/null
        log_success "StorageClass '$sc' is now the default"
    else
        log_info "StorageClass '$sc' is already the default"
    fi

    local key name others
    for key in "$main_key" "$beta_key"; do
        others=$(container_exec oc get storageclass -o jsonpath="{range .items[?(@.metadata.annotations.${key//./\\.}==\"true\")]}{.metadata.name}{\"\\n\"}{end}" 2>/dev/null) || others=""
        for name in $others; do
            if [ "$name" = "$sc" ]; then
                continue
            fi
            container_exec oc patch storageclass "$name" --type merge \
                -p "{\"metadata\":{\"annotations\":{\"${key}\":\"false\"}}}" > /dev/null
            log_success "StorageClass '$name' is no longer default"
        done
    done
}

# ClusterOperator image-registry Available=True e Progressing=False
registry_operator_ready() {
    [ "$(container_exec oc get co image-registry -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" = "True" ] &&
    [ "$(container_exec oc get co image-registry -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')" = "False" ]
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
    state=$(container_exec oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}')
    if [ "$state" = "Managed" ]; then
        log_success "Image registry already enabled (managementState=Managed)"
        return 0
    fi

    log_info "Image registry is '$state': enabling it with a ${REGISTRY_SIZE} PVC on '$REGISTRY_STORAGE_CLASS'"

    if ! container_exec oc get pvc image-registry-storage -n openshift-image-registry &> /dev/null; then
        cat <<EOF | container_exec oc apply -f -
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
    container_exec oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
        -p '{"spec":{"managementState":"Managed","replicas":1,"rolloutStrategy":"Recreate","storage":{"pvc":{"claim":"image-registry-storage"}}}}'

    # L'operatore riporta Available=True anche con il registry Removed: si attende il rollout del deployment
    wait_for "image registry deployment rollout" 60 10 \
        container_exec oc rollout status deployment/image-registry -n openshift-image-registry --timeout=10s || {
        log_error "Image registry did not roll out within 10 minutes"
        container_exec oc get co image-registry || true
        exit 1
    }
    wait_for "image registry operator (Available, not Progressing)" 60 10 registry_operator_ready || {
        log_error "Image registry operator did not settle within 10 minutes"
        container_exec oc get co image-registry || true
        exit 1
    }
    log_success "Image registry configured"
    return 0
}

# Fase cluster: Longhorn, StorageClass di default, image registry
configure_cluster() {
    log_info "Configuring the cluster..."

    if [ "$CLUSTER_CONFIGURE" = "true" ]; then
        install_longhorn
        configure_longhorn_settings
        ensure_default_storage_class
    else
        log_info "Skipping Longhorn and default StorageClass (cluster.configure=false)"
    fi

    configure_image_registry

    log_success "Cluster configuration completed"
}

# Funzione per visualizzare il riepilogo della configurazione
display_summary() {
    echo ""
    echo "======================================"
    echo "Installazione Maximo Application Suite"
    echo "======================================"
    echo "Phases: $SELECTED_PHASES"
    echo "Clean existing namespaces: $OPT_CLEAN"
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
    if phase_enabled install; then
        echo "Entitlement Key: from $ENTITLEMENT_KEY_SOURCE"
    fi
    echo "Kubeconfig: $KUBECONFIG_PATH"
    if phase_enabled cluster; then
        echo "Configure Longhorn/default StorageClass: $CLUSTER_CONFIGURE (install=$LONGHORN_INSTALL v${LONGHORN_VERSION}, ns=$LONGHORN_NAMESPACE, replicas=$LONGHORN_REPLICA_COUNT, default SC=$CLUSTER_DEFAULT_STORAGE_CLASS)"
        echo "Configure Image Registry: $REGISTRY_CONFIGURE (${REGISTRY_SIZE} on ${REGISTRY_STORAGE_CLASS})"
    fi
    echo "======================================"
    echo ""
}

# Funzione per ripulire le installazioni esistenti (solo con --clean)
cleanup_existing() {
    log_info "Looking for existing MAS namespaces to clean up..."

    # Solo i namespace di questa istanza e delle sue dipendenze (regex ancorata)
    local pattern="^(mas-${MAS_INSTANCE_ID}-.+|${MONGODB_NAMESPACE}|${DB2_NAMESPACE}|ibm-sls)\$"
    local all_namespaces namespaces ns
    # Un errore nell'elenco NON deve essere scambiato per "nessun namespace"
    if ! all_namespaces=$(container_exec oc get namespaces -o name); then
        log_error "Cannot list namespaces: cleanup aborted"
        exit 1
    fi
    namespaces=$(cut -d'/' -f2 <<< "$all_namespaces" | grep -E "$pattern" || true)

    if [ -z "$namespaces" ]; then
        log_info "No existing MAS namespaces found"
        return 0
    fi

    log_warning "The following namespaces and everything in them will be DELETED:"
    for ns in $namespaces; do
        echo "  - $ns"
    done

    if [ "$OPT_YES" != "true" ]; then
        local answer
        read -r -p "Type the instance id ($MAS_INSTANCE_ID) to confirm: " answer
        if [ "$answer" != "$MAS_INSTANCE_ID" ]; then
            log_error "Confirmation does not match: aborting without deleting anything"
            exit 1
        fi
    fi

    log_info "Deleting existing namespaces..."
    local -a pids=() pid_ns=()
    local i
    for ns in $namespaces; do
        log_info "  Deleting namespace: $ns"
        container_exec oc delete namespace "$ns" --timeout=300s &
        pids+=($!)
        pid_ns+=("$ns")
    done
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}"; then
            log_warning "Deleting namespace '${pid_ns[$i]}' did not complete cleanly"
        fi
    done

    # Verifica finale: nessun namespace deve essere rimasto (anche in Terminating)
    local remaining
    if ! all_namespaces=$(container_exec oc get namespaces -o name); then
        log_error "Cannot list namespaces to verify the cleanup"
        exit 1
    fi
    remaining=$(cut -d'/' -f2 <<< "$all_namespaces" | grep -E "$pattern" || true)
    if [ -n "$remaining" ]; then
        log_error "These namespaces still exist (possibly Terminating, stuck on finalizers):"
        for ns in $remaining; do
            echo "  - $ns"
        done
        log_error "Remove the blocking finalizers or wait for the deletion, then rerun"
        exit 1
    fi

    log_success "Cleanup completed"
}

# Rimuove il container all'uscita, salvo che la fase install sia partita (resta per il troubleshooting)
cleanup_on_exit() {
    if [ "$CONTAINER_STARTED" = "true" ] && [ "$KEEP_CONTAINER" != "true" ]; then
        $CONTAINER_ENGINE rm -f "$CONTAINER_NAME" &> /dev/null || true
    fi
}

# Funzione per configurare il container
setup_container() {
    log_info "Setting up MAS CLI container..."

    # Scarica l'immagine
    log_info "Pulling IBM MAS CLI image: $CONTAINER_IMAGE"
    $CONTAINER_ENGINE pull "$CONTAINER_IMAGE"

    # Rimuove un container rimasto da un'esecuzione precedente
    if $CONTAINER_ENGINE container inspect "$CONTAINER_NAME" &> /dev/null; then
        log_info "Removing previous container: $CONTAINER_NAME"
        $CONTAINER_ENGINE rm -f "$CONTAINER_NAME" &> /dev/null || true
    fi

    # Avvia il container
    log_info "Starting container: $CONTAINER_NAME"
    if [ "$CONTAINER_ENGINE" = "podman" ]; then
        # Opzioni specifiche di Podman per migliore connettività OpenShift
        CONTAINER_ID=$($CONTAINER_ENGINE run -dit --name "$CONTAINER_NAME" --network host --privileged "$CONTAINER_IMAGE" bash)
    else
        # Opzioni Docker
        CONTAINER_ID=$($CONTAINER_ENGINE run -dit --name "$CONTAINER_NAME" --network "$CONTAINER_NETWORK" "$CONTAINER_IMAGE" bash)
    fi
    CONTAINER_STARTED=true
    log_info "Container started: $CONTAINER_ID"

    # Configura le directory
    $CONTAINER_ENGINE exec "$CONTAINER_NAME" mkdir -p /root/.kube /mascli/masconfig

    # Copia i file
    log_info "Copying configuration files to container..."
    $CONTAINER_ENGINE cp "$KUBECONFIG_PATH" "${CONTAINER_NAME}:/root/.kube/config"
    if phase_enabled install; then
        $CONTAINER_ENGINE cp "$PULL_SECRET_PATH" "${CONTAINER_NAME}:/mascli/masconfig/pull-secret"
        $CONTAINER_ENGINE cp "$LICENSE_PATH" "${CONTAINER_NAME}:/mascli/masconfig/license.dat"
    fi

    # Testa la connettività
    log_info "Testing OpenShift connectivity from container..."
    if ! container_exec oc get nodes &> /dev/null; then
        log_error "Cannot connect to OpenShift from container"
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
    # Verifica la storage class (con la fase cluster può essere stata creata appena prima)
    if ! container_exec oc get storageclass "$STORAGE_RWO_CLASS" &> /dev/null; then
        log_error "Storage class '$STORAGE_RWO_CLASS' not found"
        log_info "Available storage classes:"
        container_exec oc get storageclass
        return 1
    fi

    log_info "Starting MAS installation..."
    log_info "This will take approximately 60-120 minutes to complete."

    # Da qui il container resta attivo per il troubleshooting
    KEEP_CONTAINER=true

    local install_cmd=$(build_install_command)

    log_info "Installation command:"
    echo "$install_cmd"
    echo ""

    # Esegui l'installazione (stdin chiuso: mas install gira con --no-confirm)
    container_exec bash -c "
        export IBM_ENTITLEMENT_KEY='$IBM_ENTITLEMENT_KEY'
        $install_cmd
    " < /dev/null

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

    if [ "$KEEP_CONTAINER" = "true" ]; then
        log_info "Container '$CONTAINER_NAME' is still running for troubleshooting"
        log_info "To access: $CONTAINER_ENGINE exec -it $CONTAINER_NAME bash"
        log_info "To remove: $CONTAINER_ENGINE rm -f $CONTAINER_NAME"
    fi
}

# Esecuzione principale
main() {
    parse_args "$@"

    echo "IBM Maximo Application Suite - Script di Installazione Configurabile"
    echo "============================================================="

    load_config
    check_prerequisites
    validate_config
    display_summary

    # Ogni accesso al cluster passa dal container MAS CLI
    trap cleanup_on_exit EXIT
    setup_container

    if phase_enabled preflight; then
        run_preflight
    fi

    if [ "$OPT_CLEAN" = "true" ]; then
        cleanup_existing
    fi

    if phase_enabled cluster; then
        configure_cluster
    fi

    if phase_enabled install; then
        if run_installation; then
            display_completion 0
            exit 0
        else
            display_completion $?
            exit 1
        fi
    fi

    log_success "Completed phases: $SELECTED_PHASES"
}

# Esegui la funzione principale
main "$@"
