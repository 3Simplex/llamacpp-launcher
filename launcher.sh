#!/bin/bash

# --- NixOS Optimized Configuration ---
CONFIG_DIR="$HOME/.config/llamacpp-launcher"
CONFIG_FILE="$CONFIG_DIR/configs.json"
mkdir -p "$CONFIG_DIR"

C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'

info() { echo -e "${C_BLUE}INFO:${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}WARN:${C_RESET} $1"; }
error() { echo -e "${C_RED}ERROR:${C_RESET} $1" >&2; exit 1; }
success() { echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"; }
get_physical_cores() { lscpu -b -p=Core,Socket | grep -v '^#' | sort -u | wc -l; }

# NixOS specific: Binary names are fixed
SERVER_BINARY="llama-server"

manage_and_select_model_dirs() {
    if [ ! -f "$CONFIG_FILE" ]; then echo '{"global_settings": {"model_directories": []}}' > "$CONFIG_FILE"; fi
    mapfile -t saved_dirs < <(jq -r '.global_settings.model_directories[]' "$CONFIG_FILE")
    
    if [ ${#saved_dirs[@]} -eq 0 ]; then
        read -r -e -p "Enter path to your models folder: " start_path
        jq --arg p "$start_path" '.global_settings.model_directories += [$p]' "$CONFIG_FILE" > t && mv t "$CONFIG_FILE"
        SEARCH_DIRS=("$start_path")
    else
        SEARCH_DIRS=("${saved_dirs[@]}")
    fi
}

select_model_from_dirs() {
    info "--- Select a Model ---"; local -a all_model_paths=(); local counter=1
    for dir in "${SEARCH_DIRS[@]}"; do
        mapfile -t models_in_dir < <(find "$dir" -maxdepth 2 -type f -name "*.gguf" ! -name "*mmproj*" | sort) 
        for model_path in "${models_in_dir[@]}"; do 
            echo "$counter) $(basename "$model_path")"
            all_model_paths+=("$model_path")
            counter=$((counter + 1))
        done
    done
    read -r -p "Choose a model number: " choice
    SELECTED_MODEL_PATH="${all_model_paths[$((choice-1))]}"
}

hardware_discovery() {
    info "--- Hardware Discovery ---"
    local metadata
    metadata=$(gguf-dump --json --no-tensors "$SELECTED_MODEL_PATH" 2>/dev/null)
    local ctx
    ctx=$(echo "$metadata" | jq -r '.metadata["llama.context_length"].value // .metadata["nemotron_h.context_length"].value // 4096')
    local layers
    layers=$(echo "$metadata" | jq -r '.metadata["llama.block_count"].value // .metadata["nemotron_h.block_count"].value // 0')
    
    success "Model Stats: Context=$ctx, Layers=$layers"
    USABLE_CONTEXT=$ctx
    SAVED_NGL=$layers
    SAVED_THREADS=$(get_physical_cores)
}

launch_server() {
    local alias_name
    alias_name=$(basename "$SELECTED_MODEL_PATH" .gguf)
    read -r -p "Port [8080]: " port
    port=${port:-8080}
    
    local cmd_args=("-m" "$SELECTED_MODEL_PATH" "-c" "$USABLE_CONTEXT" "--port" "$port" "--alias" "$alias_name" "-ngl" "$SAVED_NGL" "-t" "$SAVED_THREADS" "-fa" "on")
    
    info "Launching hardware-accelerated server..."
    "$SERVER_BINARY" "${cmd_args[@]}"
}

# Main Loop
manage_and_select_model_dirs
select_model_from_dirs
hardware_discovery
launch_server
