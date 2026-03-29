#!/bin/bash

# --- NixOS Optimized Configuration ---
CONFIG_DIR="$HOME/.config/llamacpp-launcher"
CONFIG_FILE="$CONFIG_DIR/configs.json"
mkdir -p "$CONFIG_DIR"

C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_PURPLE='\033[0;35m'

info() { echo -e "${C_BLUE}INFO:${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}WARN:${C_RESET} $1"; }
error() { echo -e "${C_RED}ERROR:${C_RESET} $1" >&2; exit 1; }
success() { echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"; }
get_physical_cores() { lscpu -b -p=Core,Socket | grep -v '^#' | sort -u | wc -l; }

SERVER_BINARY="llama-server"

manage_and_select_model_dirs() {
    if [ ! -f "$CONFIG_FILE" ]; then echo '{"global_settings": {"model_directories": []}}' > "$CONFIG_FILE"; fi
    mapfile -t saved_dirs < <(jq -r '.global_settings.model_directories[]' "$CONFIG_FILE")
    if [ ${#saved_dirs[@]} -eq 0 ]; then
        read -r -e -p "Enter path to start searching from [~]: " search_path; search_path=${search_path:-$HOME}
        jq --arg p "$search_path" '.global_settings.model_directories += [$p]' "$CONFIG_FILE" > t && mv t "$CONFIG_FILE"
        SEARCH_DIRS=("$search_path")
    else SEARCH_DIRS=("${saved_dirs[@]}"); fi
}

download_model_from_hf() {
    read -r -p "Enter Hugging Face repo name: " hf_repo; [[ -z "$hf_repo" ]] && return 1
    info "Querying repository: ${C_PURPLE}$hf_repo${C_RESET}..."; local api_url="https://huggingface.co/api/models/${hf_repo}"
    local api_response
    if ! api_response=$(curl -sfL "$api_url"); then error "Failed to query HF API."; fi
    mapfile -t gguf_files < <(echo "$api_response" | jq -r '.siblings[] | .rfilename | select(endswith(".gguf"))')
    for i in "${!gguf_files[@]}"; do printf "  %s) %s\n" "$((i+1))" "${gguf_files[i]}"; done
    read -r -p "Enter number to download: " sel
    local file_to_download="${gguf_files[sel-1]}"
    local target_dir="${SEARCH_DIRS[0]}"; mkdir -p "$target_dir"
    info "Downloading ${C_PURPLE}$file_to_download${C_RESET}..."; "$SERVER_BINARY" --hf-repo "$hf_repo" --hf-file "$file_to_download" -m "$target_dir/$file_to_download" -c 1 >/dev/null || true
    SELECTED_MODEL_PATH="$target_dir/$file_to_download"
}

select_model_from_dirs() {
    info "--- Select a Model ---"; local -a all_model_paths=(); local counter=1
    echo -e "${C_BLUE}1)${C_RESET} DOWNLOAD from Hugging Face"; all_model_paths+=("DOWNLOAD"); counter=2
    for dir in "${SEARCH_DIRS[@]}"; do
        mapfile -t models_in_dir < <(find "$dir" -maxdepth 2 -type f -name "*.gguf" ! -name "*mmproj*" | sort)
        for model_path in "${models_in_dir[@]}"; do 
            echo -e "${C_BLUE}$counter)${C_RESET} $(basename "$model_path")"
            all_model_paths+=("$model_path")
            counter=$((counter + 1))
        done
    done
    read -r -p "Choose an option: " choice
    if [ "${all_model_paths[choice-1]}" == "DOWNLOAD" ]; then download_model_from_hf; else SELECTED_MODEL_PATH="${all_model_paths[choice-1]}"; fi
}

hardware_discovery() {
    info "--- Hardware Discovery ---"
    local metadata; metadata=$(gguf-dump --json --no-tensors "$SELECTED_MODEL_PATH" 2>/dev/null)
    local train_ctx; train_ctx=$(echo "$metadata" | jq -r '.metadata["llama.context_length"].value // .metadata["nemotron_h.context_length"].value // 4096')
    local layers; layers=$(echo "$metadata" | jq -r '.metadata["llama.block_count"].value // .metadata["nemotron_h.block_count"].value // 0')
    success "Max Context=$train_ctx, Layers=$layers"
    read -r -p "Context to allocate [$train_ctx]: " ctx_in; USABLE_CONTEXT=${ctx_in:-$train_ctx}
    read -r -p "GPU Layers (ngl) [$layers]: " ngl_in; SAVED_NGL=${ngl_in:-$layers}
    SAVED_THREADS=$(get_physical_cores)
}

launch_server() {
    local alias_name; alias_name=$(basename "$SELECTED_MODEL_PATH" .gguf)
    read -r -p "Alias [$alias_name]: " alias_in; alias_name=${alias_in:-$alias_name}
    read -r -p "Port [8080]: " port; port=${port:-8080}
    read -r -p "Parallel Slots (-np) [1]: " np; np=${np:-1}
    local cmd_args=("-m" "$SELECTED_MODEL_PATH" "-c" "$USABLE_CONTEXT" "--port" "$port" "--alias" "$alias_name" "-ngl" "$SAVED_NGL" "-t" "$SAVED_THREADS" "-np" "$np" "-fa" "on")
    read -r -p "Multi-GPU Tensor Split (e.g. 1,1) [None]: " ts
    [[ -n "$ts" ]] && cmd_args+=("--tensor-split" "$ts")
    info "Launching hardware-accelerated server..."
    read -r -p "Launch in new Konsole? (y/N): " use_konsole
    if [[ "$use_konsole" =~ ^[Yy]$ ]]; then
        konsole --hold -e "$SERVER_BINARY" "${cmd_args[@]}" &
    else
        "$SERVER_BINARY" "${cmd_args[@]}"
    fi
}

manage_and_select_model_dirs
select_model_from_dirs
hardware_discovery
launch_server
