#!/bin/bash
#=============================================
# Gascan Onboarding Wrapper Script (Mostly was done with Cursor AI)
#=============================================
# Automates onboarding:
# - Installs gascan binary
# - Configures and verifies SN inventory (with up to 3 retries, then prompt)
# - Configures external PMM server if detected
# - Adds default PMM DB creds to vault on fresh onboarding (pmm/password)
# - Configures passwordless sudo for gascan execution
# - Sets up environment and customizations
# - Handles /tmp noexec by exporting TMPDIR to an exec-capable dir
# - Detects SELinux and, upon confirmation, sets runtime permissive and persists permissive
# - Supports --resume to continue from the step saved in ~/.config/gascan/.onboarding_step
# - On a failed playbook step (interactive TTY): prompt to [r]etry, [s]kip, or [q]uit; skipped
#   steps are summarized at the end with exact gascan commands to run for full recovery
# - Non-TTY: failed playbook step exits immediately (no prompt; safe for automation)
#=============================================

#=============================================
# TABLE OF CONTENTS
#=============================================
# 1. CONFIGURATION & CONSTANTS
# 2. UTILITY FUNCTIONS
# 3. PRECHECK FUNCTIONS
# 4. CONFIG/VALIDATION FUNCTIONS
# 5. PMM CONFIGURATION FUNCTIONS
# 6. INSTALL/SETUP FUNCTIONS
# 7. SUDO PASSWORD HANDLING
# 8. ONBOARDING STEP RUNNER
# 9. MAIN EXECUTION
#=============================================
set -euo pipefail
#=============================================
# 1. CONFIGURATION & CONSTANTS
#=============================================
readonly DEFAULT_GASCAN_VERSION="v1.24.0"
readonly GASCAN_BIN=~/bin/gascan
readonly GASCAN_BUNDLE_DIR=~/gascan_bundle
readonly GASCAN_CONFIG_FILE=~/.config/gascan/config.yml
readonly GASCAN_SN_CONFIG_FILE=~/.config/gascan/inventory-config.json
readonly ONBOARDING_PROGRESS_FILE=~/.config/gascan/.onboarding_step
readonly REQUIRED_KEY_LENGTH=64
RESUME_MODE=0
ONBOARDING_STEPS_WERE_SKIPPED=0
inventory_output=""
[ -n "${GASCAN_USER+x}" ] || GASCAN_USER=$(whoami)
readonly GASCAN_USER
readonly RED="\033[0;31m"
readonly GREEN="\033[0;32m"
readonly YELLOW="\033[1;33m"
readonly CYAN="\033[0;36m"
readonly RESET="\033[0m"

#=============================================
# 2. UTILITY FUNCTIONS
#=============================================
print_info()   { echo -e "${CYAN}[INFO]${RESET} $1"; }
print_success(){ echo -e "${GREEN}[SUCCESS]${RESET} $1"; }
print_warning(){ echo -e "${YELLOW}[WARNING]${RESET} $1" >&2; }
print_error()  { echo -e "${RED}[ERROR]${RESET} $1" >&2; }

get_tmp_mount_options() {
    if command -v findmnt &>/dev/null; then
        findmnt -no OPTIONS /tmp 2>/dev/null || true
    else
        awk '$2=="/tmp"{print $4}' /proc/mounts 2>/dev/null || true
    fi
}

# Try a command as the current user, fall back to sudo
run_or_sudo() { "$@" 2>/dev/null || sudo "$@" 2>/dev/null; }

try_apt_update() {
    if command -v apt >/dev/null 2>&1 || command -v apt-get >/dev/null 2>&1; then
        print_info "Refreshing apt package metadata..."
        if ! { sudo apt update -qq >/dev/null 2>&1 || sudo apt-get update -qq >/dev/null 2>&1; }; then
            print_warning "apt update failed. Package metadata may be stale."
        fi
    fi
}

setup_tmpdir_workaround() {
    local tmp_options
    tmp_options="$(get_tmp_mount_options)"

    if [[ "$tmp_options" == *noexec* ]]; then
        print_warning "/tmp is mounted with noexec. Using alternate TMPDIR."
        local alt_tmp="$HOME/tmp"
        mkdir -p "$alt_tmp" 2>/dev/null || true
        chmod 1777 "$alt_tmp" 2>/dev/null || true

        export TMPDIR="$alt_tmp"
        print_info "TMPDIR set to $TMPDIR"
    fi
}

validate_input() {
    local input="$1"; local name="$2"

    if [[ -z "$input" ]]; then
        print_error "$name cannot be empty. Please try again."
        return 1
    fi
    
    if [[ ${#input} -ne $REQUIRED_KEY_LENGTH ]]; then
        print_error "$name must be exactly $REQUIRED_KEY_LENGTH characters. Please try again."
        return 1
    fi
    
    if [[ "$input" =~ [\$\`\\] ]]; then
        print_error "$name contains invalid characters (\$, \`, \\). Please try again."
        return 1
    fi
    
    return 0
}


validate_pmm_input() {
    local input="$1"; local name="$2"
    if [[ -z "$input" ]]; then
        print_error "$name cannot be empty. Please try again."
        return 1
    fi
    return 0
}

#=============================================
# 3. PRECHECK FUNCTIONS
#=============================================
check_disk_space() {
    local min_space_gb=100
    local check_paths=("$HOME" "/")
    local checked_mounts=()
    local low_space_found=0

    print_info "Checking available disk space for PMM-server (pmm-data)..."

    for path in "${check_paths[@]}"; do
        [[ -d "$path" ]] || continue

        local mount_point
        if command -v findmnt &>/dev/null; then
            mount_point="$(findmnt -no TARGET --target "$path" 2>/dev/null || echo "/")"
        else
            mount_point="$(df "$path" 2>/dev/null | awk 'NR==2{print $NF}' || echo "/")"
        fi

        local already_checked=0
        for m in ${checked_mounts[@]+"${checked_mounts[@]}"}; do
            if [[ "$m" == "$mount_point" ]]; then
                already_checked=1
                break
            fi
        done
        [[ "$already_checked" -eq 1 ]] && continue
        checked_mounts+=("$mount_point")

        local avail_kb
        avail_kb="$(df -k "$path" 2>/dev/null | awk 'NR==2{print $4}')"
        [[ -z "$avail_kb" || "$avail_kb" == "0" ]] && continue

        local avail_gb=$((avail_kb / 1024 / 1024))

        if [[ "$avail_gb" -lt "$min_space_gb" ]]; then
            print_warning "Low disk space on ${mount_point}: ${avail_gb}GB available (recommended minimum: ${min_space_gb}GB)."
            print_warning "PMM-server (pmm-data) may require significant storage for metrics and query analytics data."
            low_space_found=1
        else
            print_success "Disk space OK on ${mount_point}: ${avail_gb}GB available."
        fi
    done

    if [[ "$low_space_found" -eq 1 ]]; then
        print_warning "Insufficient disk space detected. Consider extending volumes, or checking 'lsblk' for available disks to mount."
        read -p "Continue onboarding despite low disk space? [y/N]: " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            print_error "Aborted by user due to insufficient disk space."
            exit 1
        fi
        print_warning "Continuing with low disk space as requested by user."
    fi
}

#=============================================
# 4. CONFIG/VALIDATION FUNCTIONS
#=============================================
detect_os_and_set_url() {
    # Expects /etc/os-release to be sourced already (ID, VERSION_ID set).
    print_info "Detecting operating system..."

    case "${ID,,}-${VERSION_ID}" in
        centos-9*|rhel-9*|ol-9*|rocky-9*)
            url="https://cdba.percona.com/downloads/gascan/${gascan_version}/linux/amd64/centos-stream9/gascan-py3.9"
            ;;
        ubuntu-22*)
            url="https://cdba.percona.com/downloads/gascan/${gascan_version}/linux/amd64/ubuntu-jammy/gascan-py3.10"
            ;;
        ubuntu-24*)
            url="https://cdba.percona.com/downloads/gascan/${gascan_version}/linux/amd64/ubuntu-noble/gascan-py3.12"
            ;;
        debian-11)
            url="https://cdba.percona.com/downloads/gascan/${gascan_version}/linux/amd64/debian-bullseye/gascan-py3.9"
            ;;
        debian-12)
            url="https://cdba.percona.com/downloads/gascan/${gascan_version}/linux/amd64/debian-bookworm/gascan-py3.11"
            ;;
        debian-13)
            url="https://cdba.percona.com/downloads/gascan/${gascan_version}/linux/amd64/debian-trixie/gascan-py3.13"
            ;;
        *)
            print_error "Unsupported OS: ${ID,,}-${VERSION_ID}"
            exit 2
            ;;
    esac

    print_success "Detected OS: ${ID,,} ${VERSION_ID}"
}

get_user_input() {
    print_info "Starting gascan onboarding setup..."

    # Allow env var overrides (supports both uppercase and legacy lowercase names).
    gascan_version="${GASCAN_VERSION:-${gascan_version:-}}"
    monitor_node="${MONITOR_NODE:-${monitor_node:-}}"
    client_identifier="${CLIENT_IDENTIFIER:-${client_identifier:-}}"
    api_key="${API_KEY:-${api_key:-}}"

    if [[ -n "$gascan_version" ]]; then
        print_info "Using gascan version from environment: $gascan_version"
    else
        read -p "Enter gascan version to install [${DEFAULT_GASCAN_VERSION}]: " gascan_version
        gascan_version="${gascan_version:-$DEFAULT_GASCAN_VERSION}"
    fi

    if [[ -n "$monitor_node" ]]; then
        print_info "Using monitor node name from environment: $monitor_node"
    else
        while [[ -z "$monitor_node" ]]; do
            read -p "Enter monitor node name (as created in SN): " monitor_node
            monitor_node="$(tr -d '[:cntrl:]' <<< "$monitor_node")"
            if [[ -z "$monitor_node" ]]; then
                print_error "Monitor node name cannot be empty. Please try again."
            fi
        done
    fi

    while true; do
        local using_env_credentials=true

        if [[ -z "$client_identifier" ]]; then
            using_env_credentials=false
            read -p "$(echo -e "Enter ${CYAN}client_identifier${RESET} from SN: ")" client_identifier
        fi
        if [[ -z "$api_key" ]]; then
            using_env_credentials=false
            read -p "$(echo -e "Enter ${CYAN}api_key${RESET} from SN: ")" api_key
        fi

        if ! validate_input "$client_identifier" "Client identifier"; then
            if [[ "$using_env_credentials" == true ]]; then
                print_error "Invalid CLIENT_IDENTIFIER/client_identifier provided via environment."
                exit 1
            fi
            client_identifier=""
            api_key=""
            continue
        fi

        if ! validate_input "$api_key" "API key"; then
            if [[ "$using_env_credentials" == true ]]; then
                print_error "Invalid API_KEY/api_key provided via environment."
                exit 1
            fi
            client_identifier=""
            api_key=""
            continue
        fi

        if [[ "$client_identifier" == "$api_key" ]]; then
            if [[ "$using_env_credentials" == true ]]; then
                print_error "API_KEY/api_key must be different from CLIENT_IDENTIFIER/client_identifier."
                exit 1
            fi
            print_error "API key should be different from client identifier. Please try again."
            client_identifier=""
            api_key=""
            continue
        fi
        break
    done
}

check_existing_config() {
    if [[ -f "$GASCAN_SN_CONFIG_FILE" ]]; then
        print_info "Checking for existing configuration..."
        print_warning "Found existing inventory configuration at: $GASCAN_SN_CONFIG_FILE"
        
        read -p "Do you want to reconfigure the inventory settings? [y/N]: " reconfigure
        if [[ "$reconfigure" =~ ^[Yy]$ ]]; then
            print_info "Proceeding with reconfiguration..."
            return 0
        else
            print_info "Using existing configuration. Skipping SN setup."
            return 1
        fi
    fi
    return 0
}

setup_sn_configuration() {
    print_info "Setting up SN inventory configuration..."

    mkdir -p "$(dirname "$GASCAN_SN_CONFIG_FILE")"

    # Load-balance between cdba endpoints
    local cdba_endpoints=("cdba" "cdba2")
    local selected_endpoint="${cdba_endpoints[$RANDOM % ${#cdba_endpoints[@]}]}"
    local inventory_uri="https://${selected_endpoint}.percona.com/ng/inventory"

    cat > "$GASCAN_SN_CONFIG_FILE" <<EOF
{
  "headers": {
    "CDBAng-Auth-Id": "$client_identifier",
    "CDBAng-Auth-Token": "$api_key",
    "CDBAng-Monitor-Name": "$monitor_node",
    "Content-type": "application/json"
  },
  "key_file": "$HOME/.config/gascan/.vault-key",
  "retry_attempts": 3,
  "retry_wait_seconds": 10,
  "uri": "$inventory_uri"
}
EOF

    print_success "SN configuration updated at $GASCAN_SN_CONFIG_FILE"
}

validate_inventory_connection() {
    print_info "Testing gascan inventory connection..."

    local total_attempts=0
    local batch_attempt=0
    local max_auto_retries=3

    while true; do
        total_attempts=$((total_attempts + 1))
        batch_attempt=$((batch_attempt + 1))

        local rc=0
        inventory_output=$("$GASCAN_BIN" -refresh -get-inventory 2>&1) || rc=$?

        local failed=0
        if [[ "$rc" -ne 0 ]]; then
            failed=1
        elif echo "$inventory_output" | grep -q '\[WARNING\]: Skipping'; then
            failed=1
        fi

        if [[ "$failed" -eq 0 ]]; then
            print_success "Gascan inventory test passed."
            return 0
        fi

        print_warning "Gascan inventory test attempt $total_attempts failed."

        if [[ "$batch_attempt" -lt "$max_auto_retries" ]]; then
            print_info "Retrying in 2 seconds... ($batch_attempt/$max_auto_retries)"
            sleep 2
            continue
        fi

        read -p "Automatic retries exhausted after $max_auto_retries attempts. Try another $max_auto_retries attempts? [y/N]: " try_more
        if [[ "$try_more" =~ ^[Yy]$ ]]; then
            batch_attempt=0
            print_info "Retrying in 2 seconds..."
            sleep 2
            continue
        fi

        print_error "Gascan inventory test failed after $total_attempts attempts. Please re-enter monitor node, client identifier, and API key."
        return 1
    done
}

#=============================================
# 5. PMM CONFIGURATION FUNCTIONS
#=============================================
remove_monitor_ansible_host_from_vault() {
    # If the inventory defines ansible_host for the monitor node, remove it from
    # the vault so the pmm-client playbook connects to the monitor instance locally
    # during the initial onboarding run.
    if ! command -v jq &>/dev/null; then
        print_warning "jq not found, skipping ansible_host check for monitor node."
        return 0
    fi

    local ansible_host
    ansible_host="$(echo "$inventory_output" \
        | jq -r "._meta.hostvars[\"$monitor_node\"].ansible_host // empty" 2>/dev/null || true)"

    if [[ -z "$ansible_host" ]]; then
        print_info "No ansible_host set for $monitor_node in inventory. Nothing to remove."
        return 0
    fi

    print_info "ansible_host ($ansible_host) detected for $monitor_node in inventory."
    print_info "Removing ansible_host from vault so pmm-client playbook runs locally on the monitor."

    local yq_expression="del(.all.hosts.\"$monitor_node\".ansible_host)"
    update_vault_file "$yq_expression" "ansible_host removal for $monitor_node"
}

check_and_handle_external_pmm_server() {
    if ! command -v jq &>/dev/null; then
        print_warning "jq not found, skipping external PMM server detection."
        return 0
    fi

    pmm_server_host=$(jq -r "._meta.hostvars[\"$monitor_node\"].pmm_server_host // empty" <<<"$inventory_output" 2>/dev/null || true)
    pmm_server_port=$(jq -r "._meta.hostvars[\"$monitor_node\"].pmm_server_port // empty" <<<"$inventory_output" 2>/dev/null || true)

    if [[ -n "$pmm_server_host" && -n "$pmm_server_port" ]]; then
        print_info "External PMM server detected: $pmm_server_host:$pmm_server_port"
        handle_pmm_credentials
    fi
    return 0
}

handle_pmm_credentials() {
    print_info "PMM server credentials are required for: $pmm_server_host:$pmm_server_port"
    
    while true; do
        read -p "Enter PMM admin username: " pmm_user
        if ! validate_pmm_input "$pmm_user" "PMM username"; then
            continue
        fi
        
        read -s -p "Enter PMM admin password: " pmm_password; echo
        if ! validate_pmm_input "$pmm_password" "PMM password"; then
            continue
        fi
        
        if validate_pmm_credentials; then
            store_pmm_credentials "$pmm_user" "$pmm_password"
            pmm_password=""
            break
        else
            print_error "PMM authentication failed. Please try again."
            pmm_password=""
        fi
    done
}

validate_pmm_credentials() {
    print_info "Validating PMM credentials..."
    response_code=$(curl -k -s -o /dev/null -w "%{http_code}" -u "$pmm_user:$pmm_password" "https://$pmm_server_host:$pmm_server_port/v1/version" 2>/dev/null)
    
    if [[ "$response_code" == "200" ]]; then
        print_success "PMM credentials validated successfully."
        return 0
    else
        print_error "PMM authentication failed (HTTP $response_code)."
        return 1
    fi
}

# Unified function to update vault file with yq
update_vault_file() {
    local yq_expression="$1"
    local operation_description="$2"
    local vault_file=~/.config/gascan/secrets.yaml
    
    if ! command -v yq &>/dev/null; then
        install_yq
        if ! command -v yq &>/dev/null; then
            print_error "Failed to install yq. Cannot update vault file."
            return 1
        fi
    fi
    
    if [[ ! -f "$vault_file" ]]; then
        if ! echo "{}" > "$vault_file"; then
            print_error "Failed to create vault file at $vault_file"
            return 1
        fi
    fi
    
    if grep -q '^\$ANSIBLE_VAULT' "$vault_file"; then
        print_warning "Vault file is encrypted. Skipping $operation_description update."
        return 0
    fi
    
    local backup_file="$vault_file.bak.$(date +%s)"
    if ! run_or_sudo cp "$vault_file" "$backup_file"; then
        print_error "Failed to create backup of $vault_file"
        return 1
    fi
    run_or_sudo chmod u+r "$backup_file" || true
    if [[ "$(stat -c '%U' "$backup_file" 2>/dev/null || stat -f '%Su' "$backup_file")" != "$GASCAN_USER" ]]; then
        sudo chown "$GASCAN_USER:$GASCAN_USER" "$backup_file" 2>/dev/null || true
    fi

    # Resolve yq path; check ~/bin explicitly to handle PATH gaps
    local yq_cmd
    yq_cmd="$(command -v yq 2>/dev/null || true)"
    if [[ -z "$yq_cmd" && -x "$HOME/bin/yq" ]]; then
        yq_cmd="$HOME/bin/yq"
    fi
    : "${yq_cmd:=yq}"

    # Process via temp files in TMPDIR to avoid snap confinement on hidden paths
    local tmp_in tmp_out
    tmp_in="${TMPDIR:-/tmp}/secrets.yaml.back.$$.$RANDOM"
    tmp_out="${TMPDIR:-/tmp}/secrets.yaml.$$.$RANDOM"
    if ! run_or_sudo cp "$backup_file" "$tmp_in"; then
        print_error "Failed to stage backup for yq processing"
        rm -f "$tmp_in" "$tmp_out" 2>/dev/null || true
        return 1
    fi
    run_or_sudo chmod u+rw "$tmp_in" || true
    if ! "$yq_cmd" eval "$yq_expression" "$tmp_in" > "$tmp_out"; then
        rm -f "$tmp_in" "$tmp_out" 2>/dev/null || true
        print_error "Failed to update $operation_description in vault file"
        return 1
    fi
    rm -f "$tmp_in" 2>/dev/null || true

    if ! run_or_sudo mv "$tmp_out" "$vault_file"; then
        rm -f "$tmp_out" 2>/dev/null || true
        print_error "Failed to write updated vault file"
        return 1
    fi

    # Fix ownership only if current user doesn't own the file
    if [[ "$(stat -c '%U' "$vault_file" 2>/dev/null || stat -f '%Su' "$vault_file")" != "$GASCAN_USER" ]]; then
        sudo chown "$GASCAN_USER:$GASCAN_USER" "$vault_file" 2>/dev/null || print_warning "Failed to change ownership of $vault_file"
    fi
    chmod 600 "$vault_file" 2>/dev/null || { print_error "Failed to set permissions on $vault_file"; return 1; }

    print_success "$operation_description stored in $vault_file (with backup at $backup_file)"
}

store_pmm_credentials() {
    local pmm_user="$1"
    local pmm_password="$2"
    PMM_CREDS="${pmm_user}:${pmm_password}" MON="$monitor_node" \
        update_vault_file '.all.hosts[strenv(MON)].pmm_admin_credentials = strenv(PMM_CREDS)' \
        "PMM credentials under host $monitor_node"
    unset PMM_CREDS MON
}

ensure_default_pmm_db_credentials() {
    # Set defaults only if missing: pmm_db_username, pmm_db_password under all.vars;
    # ensure inventory-style group stubs under all.children (pmm_clients.children null, etc.)
    local yq_expression
    yq_expression='.all = (.all // {}) | .all.vars = (.all.vars // {}) | .all.vars.pmm_db_username = (.all.vars.pmm_db_username // "percona") | .all.vars.pmm_db_password = (.all.vars.pmm_db_password // "Percona1234") | .all.children = (.all.children // {}) | .all.children.pmm_clients = (.all.children.pmm_clients // {}) | .all.children.pmm_clients.children = (.all.children.pmm_clients.children // {}) | .all.children.pmm_clients.children.monitors = (.all.children.pmm_clients.children.monitors // null) | .all.children.pmm_clients.children.dbservers = (.all.children.pmm_clients.children.dbservers // null) | .all.children.pmm_clients.children.ha = (.all.children.pmm_clients.children.ha // null)'
    update_vault_file "$yq_expression" "default PMM DB credentials and all.children inventory stubs"
}

#=============================================
# 6. INSTALL/SETUP FUNCTIONS
#=============================================
install_gascan() {
    print_info "Installing gascan binary..."

    if ! mkdir -p ~/bin; then
        print_error "Failed to create ~/bin directory"
        return 1
    fi

    print_info "Downloading gascan from: $url"
    if ! curl -fsSL "$url" -o "$GASCAN_BIN"; then
        print_error "Failed to download gascan binary from $url"
        return 1
    fi

    if ! chmod u=rwx,go= "$GASCAN_BIN"; then
        print_error "Failed to set permissions on $GASCAN_BIN"
        return 1
    fi

    print_success "Gascan binary downloaded to $GASCAN_BIN"

    local extract_log
    if ! extract_log=$("$GASCAN_BIN" --monitor="$monitor_node" --extract-bundle --extract-path="$HOME" 2>&1); then
        print_error "Failed to extract gascan bundle"
        echo "$extract_log" | tail -n 20 >&2
        return 1
    fi

    print_success "Gascan bundle extracted to $HOME"
}

setup_environment() {
    print_info "Setting up environment..."

    gascan_passwordless_sudo=0

    # Clear any cached sudo credentials and test fresh
    sudo -k >/dev/null 2>&1

    if sudo -n true 2>/dev/null; then
        print_success "Passwordless sudo is enabled."
        gascan_passwordless_sudo=1
    else
        print_warning "Passwordless sudo is not enabled for this user."
        get_sudo_password
        store_sudo_password
    fi

    if ! grep -q "SSH_MS_NAME" ~/.bashrc; then
        cat <<EOF >> ~/.bashrc
# GAScan customizations

RESET="\[\033[0m\]"
COLOR_USER="\[\033[0;36m\]"
COLOR_HOST="\[\033[1;31m\]"
COLOR_DIR="\[\033[0;33m\]"
COLOR_CMD="\[\033[0;37;00m\]"
COLOR_CLIENT="\[\033[1;32m\]"
SSH_MS_NAME="$monitor_node"

# Useful aliases
alias avv="ansible-vault view ~/.config/gascan/secrets.yaml"
# db_tree, db/ssh_connect will work after gas_tools installation
alias db_tree='PEX_SCRIPT=db_tree.py ~/bin/gas-tools'
alias amtool_wrapper='PEX_SCRIPT=amtool_wrapper.py ~/bin/gas-tools'
alias db_connect='PEX_SCRIPT=connect.py ~/bin/gas-tools --connect-type dbc'
alias ssh_connect='PEX_SCRIPT=connect.py ~/bin/gas-tools'

export ANSIBLE_VAULT_PASSWORD_FILE='~/.config/gascan/.vault-key'
export GASCAN_DEFAULT_INVENTORY=0
export GASCAN_INVENTORY_CONFIG_FILE="$HOME/.config/gascan/inventory-config.json"
export PATH=\$PATH:~/bin
export HISTTIMEFORMAT="%F %T "

amtool() {
  if [[ "\$1" == "alert" ]]; then
    shift
    command amtool alert query alertname!="Percona_MS_DeadManSnitch" "\$@"
  else
    command amtool "\$@"
  fi
}

export PS1="[\${COLOR_CLIENT}\${SSH_MS_NAME}\${RESET}] \${COLOR_USER}\u\${RESET}@\${COLOR_HOST}monitor-gascan\${RESET}: \${COLOR_DIR}\W \${RESET}\\$ \${COLOR_CMD}"

EOF

        print_success ".bashrc updated with monitor node info and GAScan customizations."
    else
        print_info ".bashrc already contains GAScan customizations."
    fi

    # Insert GASCAN_FLAG_PASSWORDLESS_SUDO before ANSIBLE_VAULT_PASSWORD_FILE if needed
    if [[ "$gascan_passwordless_sudo" == "1" ]] || [[ "$sudo_password_stored_in_vault" == "1" ]]; then
        grep -qxF 'export GASCAN_FLAG_PASSWORDLESS_SUDO=1' ~/.bashrc || \
            sed -i "/^export ANSIBLE_VAULT_PASSWORD_FILE=/i export GASCAN_FLAG_PASSWORDLESS_SUDO=1" ~/.bashrc
    fi

    # Insert TMPDIR after PATH if /tmp is noexec
    if [[ "$(get_tmp_mount_options)" == *noexec* ]]; then
        local alt_tmp="${TMPDIR:-$HOME/tmp}"
        grep -q '^export TMPDIR=' ~/.bashrc || \
            sed -i "/^export PATH=.*:~\/bin/a export TMPDIR=\"$alt_tmp\"" ~/.bashrc
    fi
}

check_and_handle_selinux() {
    # Detect SELinux and optionally set it to permissive (runtime and persist in config)
    if command -v getenforce &>/dev/null || command -v sestatus &>/dev/null; then
        local status="" current="Unknown"
        if command -v getenforce &>/dev/null; then
            status="$(getenforce 2>/dev/null || true)"
        else
            status="$(sestatus 2>/dev/null | awk -F: '/Current mode|SELinux status/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | paste -sd ' ' - || true)"
        fi

        case "${status,,}" in
            enforcing*) current="Enforcing" ;;
            permissive*) current="Permissive" ;;
            disabled*) current="Disabled" ;;
            *) current="Unknown" ;;
        esac

        if [[ "$current" == "Enforcing" || "$current" == "Permissive" ]]; then
            print_warning "SELinux is $current. Some operations may be blocked."
            read -p "Set SELinux to permissive now and persist in /etc/selinux/config? [y/N]: " set_perm
            if [[ "$set_perm" =~ ^[Yy]$ ]]; then
                if command -v setenforce &>/dev/null; then
                    if sudo setenforce 0 2>/dev/null; then
                        print_success "SELinux runtime set to permissive."
                    else
                        print_warning "Failed to set SELinux to permissive at runtime."
                    fi
                fi

                local cfg="/etc/selinux/config"
                if [[ -f "$cfg" ]]; then
                    if sudo sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$cfg"; then
                        print_success "Updated $cfg to set SELINUX=permissive (no reboot performed)."
                    else
                        print_warning "Failed to update $cfg."
                    fi
                elif [[ -d "/etc/selinux" ]]; then
                    if echo -e "SELINUX=permissive\nSELINUXTYPE=targeted" | sudo tee "$cfg" >/dev/null; then
                        print_success "Created $cfg with SELINUX=permissive."
                    else
                        print_warning "Failed to create $cfg."
                    fi
                else
                    print_warning "/etc/selinux not found; cannot persist SELinux setting."
                fi
            else
                print_info "SELinux left as $current by user choice."
            fi
        else
            print_info "SELinux status: $current."
        fi
    else
        print_info "SELinux tools not found; skipping SELinux handling."
    fi
}

setup_linger() {
    if ! command -v loginctl &>/dev/null; then
        print_warning "loginctl not available on this system."
        return 0
    fi

    if loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q '=yes'; then
        print_info "Linger already enabled for $USER."
        return 0
    fi

    print_info "Setting up linger for background services..."
    sudo loginctl enable-linger "$USER"
    print_success "Linger enabled for $USER."
}

install_yq() {
    print_info "Installing yq..."

    local yq_version="v4.44.1"
    local yq_url="https://github.com/mikefarah/yq/releases/download/${yq_version}/yq_linux_amd64"
    local user_yq_bin="$HOME/bin/yq"
    mkdir -p "$HOME/bin" >/dev/null 2>&1 || true
    if curl -fsSL "$yq_url" -o "$user_yq_bin" >/dev/null 2>&1 && \
       chmod +x "$user_yq_bin" >/dev/null 2>&1 && \
       "$user_yq_bin" --version >/dev/null 2>&1; then
        print_success "yq installed successfully to $user_yq_bin."
        if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
            export PATH="$HOME/bin:$PATH"
        fi
        return 0
    fi

    print_error "Failed to install yq into $HOME/bin. Please install it manually."
    print_info "Manual install: curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 -o ~/bin/yq && chmod +x ~/bin/yq"
    return 1
}

#=============================================
# 7. SUDO PASSWORD HANDLING
#=============================================
get_sudo_password() {
    print_info "Passwordless sudo is not enabled. We need to store your sudo password for Ansible operations."
    print_warning "Your sudo password will be stored in ~/.config/gascan/secrets.yaml (Unencrypted till first automation run)"

    while true; do
        read -s -p "Enter your sudo password: " sudo_password; echo

        if echo "$sudo_password" | sudo -S true 2>/dev/null; then
            print_success "Sudo password verified successfully."
            return 0
        else
            print_error "Sudo password verification failed. Please try again."
            continue
        fi
    done
}

store_sudo_password() {
    if SUDO_PW="$sudo_password" update_vault_file \
        '.all.vars.ansible_become_pass = strenv(SUDO_PW)' "sudo password"; then
        sudo_password_stored_in_vault=1
    fi
    unset SUDO_PW
}

#=============================================
# 8. ONBOARDING STEP RUNNER
#=============================================
readonly -a ONBOARDING_STEPS=(
    "Initializing PMM-server|--limit=monitors --playbook=pmm-server.yaml"
    "Installing pmm-client on monitor node|--limit=monitors --playbook=pmm-client.yaml"
    "Installing tools on monitor node|--limit=monitors --playbook=tools.yaml"
    "Installing configuration files on monitor node|--playbook configs.yaml --tags=connect,netrc --limit=monitors"
)

save_onboarding_progress() {
    mkdir -p "$(dirname "$ONBOARDING_PROGRESS_FILE")" 2>/dev/null || true
    echo "$1" > "$ONBOARDING_PROGRESS_FILE"
}

clear_onboarding_progress() {
    rm -f "$ONBOARDING_PROGRESS_FILE" 2>/dev/null || true
}

# Prints one of: retry, skip, quit (stdout). Interactive only; caller must gate on -t 0.
prompt_onboarding_step_failure() {
    local choice
    while true; do
        read -r -p "[r]etry / [s]kip this step / [q]uit: " choice || { echo quit; return 0; }
        case "$choice" in
            [rR]|[rR]etry) echo retry; return 0 ;;
            [sS]|[sS]kip) echo skip; return 0 ;;
            [qQ]|[qQ]uit) echo quit; return 0 ;;
            *)
                print_warning "Invalid choice. Enter r, s, or q."
                ;;
        esac
    done
}

run_onboarding_steps() {
    local start_step=0
    local total=${#ONBOARDING_STEPS[@]}
    local i
    local -a skipped_descriptions=()
    local -a skipped_gascan_args=()

    ONBOARDING_STEPS_WERE_SKIPPED=0

    if [[ "$RESUME_MODE" -eq 1 && -f "$ONBOARDING_PROGRESS_FILE" ]]; then
        start_step="$(cat "$ONBOARDING_PROGRESS_FILE" 2>/dev/null || echo 0)"
        if [[ "$start_step" -ge "$total" ]]; then
            print_info "All onboarding steps were already completed. Starting fresh."
            start_step=0
        else
            print_info "Resuming onboarding from step $((start_step + 1))/${total}."
        fi
    elif [[ "$RESUME_MODE" -eq 1 ]]; then
        print_warning "No progress file found. Starting onboarding from the beginning."
    fi

    print_info "Running gascan onboarding (${total} steps)..."

    i=$start_step
    while (( i < total )); do
        local entry="${ONBOARDING_STEPS[$i]}"
        local description="${entry%%|*}"
        local gascan_args="${entry#*|}"

        save_onboarding_progress "$i"

        print_info "[Step $((i + 1))/${total}] ${description}..."
        print_info "  gascan ${gascan_args}"

        if "$GASCAN_BIN" $gascan_args; then
            print_success "[Step $((i + 1))/${total}] ${description} — done."
            ((i++)) || true
            continue
        fi

        print_error "Step $((i + 1))/${total} failed: ${description}"

        if [[ ! -t 0 ]]; then
            print_info "Fix the issue and re-run the script with --resume to continue:"
            print_info "  $0 --resume"
            exit 10
        fi

        local action
        action="$(prompt_onboarding_step_failure)"
        case "$action" in
            retry)
                continue
                ;;
            skip)
                skipped_descriptions+=("$description")
                skipped_gascan_args+=("$gascan_args")
                ONBOARDING_STEPS_WERE_SKIPPED=1
                print_warning "Skipped step $((i + 1))/${total}: ${description}"
                ((i++)) || true
                ;;
            quit)
                print_info "Fix the issue and re-run the script with --resume to continue:"
                print_info "  $0 --resume"
                exit 10
                ;;
        esac
    done

    if [[ "${#skipped_descriptions[@]}" -gt 0 ]]; then
        print_warning "Later steps may depend on skipped playbooks; run recovery commands in order when ready."
        print_info "Recovery — run these gascan commands to complete skipped steps:"
        local idx
        for idx in "${!skipped_descriptions[@]}"; do
            print_info "  # ${skipped_descriptions[$idx]}"
            print_info "  gascan ${skipped_gascan_args[$idx]}"
        done
    fi

    clear_onboarding_progress
}

confirm_automation_start() {
    if [[ "${GASCAN_CONFIRM_AUTOMATION:-}" =~ ^([Yy]|[Yy][Ee][Ss]|1|[Tt][Rr][Uu][Ee])$ ]]; then
        print_info "Automation start pre-approved by GASCAN_CONFIRM_AUTOMATION."
        return 0
    fi

    if [[ ! -t 0 ]]; then
        print_error "Gascan onboarding automation requires confirmation before starting."
        print_info "Set GASCAN_CONFIRM_AUTOMATION=1 to approve automation in a non-interactive run."
        exit 11
    fi

    print_warning "The next phase will run gascan onboarding automation."
    print_info "No automation commands have started yet."
    print_info "The following automations will run in order:"

    local idx
    for idx in "${!ONBOARDING_STEPS[@]}"; do
        local entry="${ONBOARDING_STEPS[$idx]}"
        local description="${entry%%|*}"
        local gascan_args="${entry#*|}"
        print_info "  $((idx + 1)). ${description}"
        print_info "     Command: gascan ${gascan_args}"
    done

    local proceed
    read -r -p "Proceed with gascan onboarding automation? [y/N]: " proceed
    if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
        print_warning "Gascan onboarding automation aborted by user before start."
        exit 0
    fi
}

#=============================================
# 9. MAIN EXECUTION
#=============================================
run_fresh_setup() {
    if [[ ! -f /etc/os-release ]]; then
        print_error "/etc/os-release not found. Cannot determine OS."
        exit 2
    fi
    . /etc/os-release

    try_apt_update
    setup_tmpdir_workaround
    check_disk_space

    if ! check_existing_config; then
        print_info "Using existing configuration..."
        return 0
    fi

    get_user_input

    if ! detect_os_and_set_url; then
        print_error "Failed to detect OS or set download URL"
        exit 2
    fi

    if ! install_gascan; then
        print_error "Failed to install gascan binary"
        exit 3
    fi

    if ! setup_sn_configuration; then
        print_error "Failed to setup SN configuration"
        exit 4
    fi

    ensure_default_pmm_db_credentials || true

    while ! validate_inventory_connection; do
        print_info "Retrying with new credentials..."
        get_user_input
        if ! setup_sn_configuration; then
            print_error "Failed to setup SN configuration during retry"
            exit 4
        fi
    done

    remove_monitor_ansible_host_from_vault

    print_info "Checking for External PMM server variables in inventory output..."
    if ! check_and_handle_external_pmm_server; then
        print_error "Failed to check for external PMM server variables"
        exit 5
    fi

    if ! setup_environment; then
        print_error "Failed to setup environment"
        exit 5
    fi
}

main() {
    for arg in "$@"; do
        case "$arg" in
            --resume) RESUME_MODE=1 ;;
            --help|-h)
                echo "Usage: $0 [--resume]"
                echo ""
                echo "Options:"
                echo "  --resume   Resume from the step index in ~/.config/gascan/.onboarding_step"
                echo "  --help     Show this help message"
                echo ""
                echo "Environment variables (override interactive prompts):"
                echo "  GASCAN_VERSION     gascan version to install (default: ${DEFAULT_GASCAN_VERSION})"
                echo "  MONITOR_NODE       monitor node name as created in SN"
                echo "  CLIENT_IDENTIFIER  SN client identifier (${REQUIRED_KEY_LENGTH} chars)"
                echo "  API_KEY            SN API key (${REQUIRED_KEY_LENGTH} chars)"
                echo "  GASCAN_USER        user that owns gascan config/vault (default: current user)"
                echo ""
                echo "During playbook steps, if a step fails in an interactive terminal, you can:"
                echo "  r — retry the same step (e.g. after fixing the issue)"
                echo "  s — skip this step and continue (not recommended if later steps depend on it)"
                echo "  q — quit; re-run with --resume to continue from the saved step"
                echo ""
                echo "If you skipped any steps, the script prints a recovery section listing the exact"
                echo "'gascan ...' commands to run later for a fully complete onboarding."
                echo "Non-interactive runs (no TTY on stdin) exit on failure without prompting."
                exit 0
                ;;
            *)
                print_error "Unknown option: $arg"
                echo "Usage: $0 [--resume]"
                exit 1
                ;;
        esac
    done

    print_info "Starting Gascan Onboarding Process"
    print_info "=================================="

    if [[ "$RESUME_MODE" -eq 1 ]]; then
        print_info "Resume mode: skipping setup, continuing from last failed step."
    else
        run_fresh_setup
    fi

    # Idempotent — safe to run on resume too.
    check_and_handle_selinux
    setup_linger

    # Always needed, including on --resume
    export ANSIBLE_VAULT_PASSWORD_FILE="$HOME/.config/gascan/.vault-key"
    export GASCAN_DEFAULT_INVENTORY=0
    export GASCAN_INVENTORY_CONFIG_FILE="$HOME/.config/gascan/inventory-config.json"
    grep -q '^export GASCAN_FLAG_PASSWORDLESS_SUDO=1' ~/.bashrc 2>/dev/null && export GASCAN_FLAG_PASSWORDLESS_SUDO=1

    confirm_automation_start
    run_onboarding_steps

    if [[ "$ONBOARDING_STEPS_WERE_SKIPPED" -eq 1 ]]; then
        print_warning "Gascan onboarding finished with skipped playbook steps (see recovery commands above)."
    else
        print_success "Gascan onboarding complete!"
    fi
    print_info "=================================="

    read -p "Open a new shell with updated environment? [Y/n]: " open_shell
    if [[ ! "$open_shell" =~ ^[Nn]$ ]]; then
        exec bash --login
    else
        print_info "Run 'source ~/.bashrc' or open a new terminal to apply environment changes."
    fi
}

# ---------------------------------------------
# MONITOR ONBOARDING SCRIPT START
# ---------------------------------------------
main "$@"