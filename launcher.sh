#!/bin/bash
set -e

# --- NixOS Optimized Advanced Configuration ---
CONFIG_DIR="$HOME/.config/llamacpp-launcher"
CONFIG_FILE="$CONFIG_DIR/configs.json"
mkdir -p "$CONFIG_DIR"
DEBUG=false

# We use a dummy environment name since NixOS uses a global installation
SELECTED_CFG_NAME="nixos_global"

# --- Colors ---
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_PURPLE='\033[0;35m'; C_CYAN='\033[0;36m'

# --- Global Vars ---
SELECTED_MMPROJ_PATH=""
SERVER_BINARY="$HOME/src/flakes/llamacpp-flake/store/global-active/bin/llama-server"
CLI_BINARY="$HOME/src/flakes/llamacpp-flake/store/global-active/bin/llama-cli"
STORE_DIR="$HOME/src/flakes/llamacpp-flake/store"
INVENTORY="$STORE_DIR/inventory.json"
GLOBAL_LINK="$STORE_DIR/global-active"
SERVER_BINARY="$GLOBAL_LINK/bin/llama-server"
CLI_BINARY="$GLOBAL_LINK/bin/llama-cli"
declare -A RUNNING_INSTANCES

# --- Helper Functions ---
info() { echo -e "${C_BLUE}INFO:${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}WARN:${C_RESET} $1"; }
error() { echo -e "${C_RED}ERROR:${C_RESET} $1" >&2; exit 1; }
success() { echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"; }
debug() { if [ "$DEBUG" = true ]; then echo -e "${C_CYAN}DEBUG:${C_RESET} $1" >&2; fi; }
command_exists() { command -v "$1" &> /dev/null; }

resolve_binaries() {
    local pinned; pinned=$(jq -r \
        --arg cfg "$SELECTED_CFG_NAME" \
        --arg key "$SELECTED_MODEL_PATH" \
        '.[$cfg].models[$key].pinned_build // empty' "$CONFIG_FILE")

    if [[ -n "$pinned" ]]; then
        local pinned_path="${STORE_DIR}/${pinned}"
        if [ -e "$pinned_path" ]; then
            SERVER_BINARY="${pinned_path}/bin/llama-server"
            CLI_BINARY="${pinned_path}/bin/llama-cli"
            info "Using pinned build: ${C_GREEN}$pinned${C_RESET}"
        else
            warn "Pinned build '${pinned}' not found in store. Falling back to global-active."
        fi
    else
        SERVER_BINARY="$GLOBAL_LINK/bin/llama-server"
        CLI_BINARY="$GLOBAL_LINK/bin/llama-cli"
        info "Using global active build: ${C_GREEN}$(basename "$(readlink "$GLOBAL_LINK")")${C_RESET}"
    fi
}

get_physical_cores() {
    if command_exists lscpu; then lscpu -b -p=Core,Socket | grep -v '^#' | sort -u | wc -l; else echo 4; fi
}

# Ensure base JSON structure exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo '{"global_settings": {"model_directories":[]}, "nixos_global": {"models": {}}, "launch_presets": {}}' > "$CONFIG_FILE"
else
    # Inject missing keys safely into old config files
    jq '.nixos_global //= {"models": {}} | .launch_presets //= {} | .global_settings.model_directories //=[]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
fi

# --- Process Discovery ---
discover_instances() {
    info "Scanning for active server instances..."
    RUNNING_INSTANCES=()
    while read -r pid cmd; do
        local alias; alias=$(echo "$cmd" | grep -oP '(?<=--alias )[^ ]+' || echo "N/A")
        local port; port=$(echo "$cmd" | grep -oP '(?<=--port )[^ ]+' || echo "N/A")
        local model_path; model_path=$(echo "$cmd" | grep -oP '(?<=-m )[^ ]+' || echo "N/A")
        local model; model=$(basename "$model_path")
        local device="Unknown"; local device_flag
        device_flag=$(echo "$cmd" | grep -oP '(?<=--device )[^ ]+' || echo "")

        if [[ "$device_flag" == "none" ]]; then
            device="CPU (Exclusive)"
        elif [[ -n "$device_flag" ]]; then
            device="$device_flag"
        else
            local ngl; ngl=$(echo "$cmd" | grep -oP '(?<=-ngl )[^ ]+' || echo "0")
            if [[ "$ngl" -gt 0 ]]; then
                local gpu_env; gpu_env=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep '^CUDA_VISIBLE_DEVICES=')
                device=${gpu_env:+${gpu_env#*=}}; device=${device:-"GPU (Implicit)"}
            else device="CPU (Implicit)"; fi
        fi
        RUNNING_INSTANCES[$pid]="Alias: ${alias}, Port: ${port}, Device: ${device}, Model: ${model}"
    done < <(pgrep -af "$SERVER_BINARY" || true)
    info "Discovery complete. Found ${#RUNNING_INSTANCES[@]} running instances."
}

# --- Dependencies ---
check_dependencies() {
    for cmd in curl jq pgrep "$SERVER_BINARY"; do
        command_exists "$cmd" || error "'$cmd' is required but not found in PATH."
    done
    command_exists secret-tool || warn "'secret-tool' not found. Secure token storage disabled."
}

# --- Directory Management ---
manage_and_select_model_dirs() {
    info "--- Select Model Directory/ies ---"
    while true; do
        mapfile -t saved_dirs < <(jq -r '.global_settings.model_directories[]' "$CONFIG_FILE")
        local options=("Use ALL saved directories" "Search for a new model directory...")
        for dir in "${saved_dirs[@]}"; do options+=("Use: $dir"); done
        options+=("CANCEL")

        local last_choice_idx; last_choice_idx=$(jq -r '.global_settings.last_used_model_dir_choice // 1' "$CONFIG_FILE")
        COLUMNS=1
        PS3="Choose an option [${last_choice_idx}]: "
        select choice in "${options[@]}"; do
            choice=${choice:-${options[$((last_choice_idx-1))]}}
            local current_choice_idx; for i in "${!options[@]}"; do if [[ "${options[$i]}" == "$choice" ]]; then current_choice_idx=$((i+1)); break; fi; done
            jq --argjson idx "$current_choice_idx" '.global_settings.last_used_model_dir_choice=$idx' "$CONFIG_FILE" > t && mv t "$CONFIG_FILE"

            case "$choice" in
                "Use ALL saved directories")[ ${#saved_dirs[@]} -gt 0 ] && SEARCH_DIRS=("${saved_dirs[@]}") && return 0
                    warn "No saved directories exist yet."; break;;
                "Search for a new model directory...")
                    read -e -p "Enter path to start searching from [~]: " search_path
                    search_path=${search_path:-$HOME}
                    search_path="${search_path/#\~/$HOME}" # NixOS Expansion Fix

                    info "Searching for directories containing .gguf files under ${C_CYAN}$search_path${C_RESET}..."
                    mapfile -t found_dirs < <(find "$search_path" -type f -name "*.gguf" -printf "%h\n" 2>/dev/null | sort -u || true)

                    [ ${#found_dirs[@]} -eq 0 ] && warn "No directories with .gguf models found." && break
                    local selected_for_add=()
                    for dir in "${found_dirs[@]}"; do
                        read -p "Add directory '${C_CYAN}$dir${C_RESET}'? (y/N/s): " -n 1 -r action; echo
                        if [[ "$action" =~ ^[Yy]$ ]]; then selected_for_add+=("$dir"); fi
                    done

                    if [ ${#selected_for_add[@]} -gt 0 ]; then
                        jq --argjson paths "$(printf '%s\n' "${selected_for_add[@]}" | jq -R . | jq -s .)" '.global_settings.model_directories |= (. + $paths | unique)' "$CONFIG_FILE" > t && mv t "$CONFIG_FILE"
                        success "Directories saved."
                    fi
                    break;;
                "CANCEL") return 1;;
                "") warn "Invalid selection.";;
                *)
                    SEARCH_DIRS=("${choice#Use: }")
                    SEARCH_DIRS[0]="${SEARCH_DIRS[0]/#\~/$HOME}"
                    return 0;;
            esac
        done
    done
}

download_model_from_hf() {
    read -p "Enter Hugging Face repo name (e.g., Qwen/Qwen2.5-7B-Instruct-GGUF): " hf_repo
    [[ -z "$hf_repo" ]] && warn "Repo name cannot be empty." && return 1

    info "Querying repository: ${C_PURPLE}$hf_repo${C_RESET}..."
    local api_url="https://huggingface.co/api/models/${hf_repo}"
    local api_response
    if ! api_response=$(curl -sfL "$api_url"); then error "Failed to query HF API. Check repo name."; return 1; fi

    mapfile -t gguf_files < <(echo "$api_response" | jq -r '.siblings[] | .rfilename | select(endswith(".gguf"))')
    if [ ${#gguf_files[@]} -eq 0 ]; then warn "No .gguf files found."; return 1; fi

    info "Found ${#gguf_files[@]} GGUF files."
    for i in "${!gguf_files[@]}"; do printf "  %s) %s\n" "$((i+1))" "${gguf_files[$i]}"; done
    read -p "Enter the number(s) of the file(s) to download, separated by spaces: " -a selections

    local target_dir="${SEARCH_DIRS[0]}"
    target_dir="${target_dir/#\~/$HOME}"
    mkdir -p "$target_dir"

    for sel in "${selections[@]}"; do
        if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] ||[ "$sel" -gt ${#gguf_files[@]} ]; then warn "Invalid selection '$sel'."; continue; fi
        local file_to_download="${gguf_files[$sel-1]}"
        local download_path="${target_dir}/${file_to_download}"

        info "Downloading ${C_PURPLE}$file_to_download${C_RESET} directly..."
        local download_url="https://huggingface.co/${hf_repo}/resolve/main/${file_to_download}"

        # Using pure curl fixes the hanging llama-server bug
        if ! curl -L -C - --progress-bar "$download_url" -o "$download_path"; then
            error "Download failed for $file_to_download"
        fi

        if [[ "$download_path" == *mmproj* ]]; then
            SELECTED_MMPROJ_PATH="$download_path"
        else
            SELECTED_MODEL_PATH="$download_path"
        fi
    done
    [[ -n "$SELECTED_MODEL_PATH" ]] && return 0 || return 1
}

select_model_from_dirs() {
    info "--- Select a Model ---"
    local -a all_model_paths=()
    local counter=1

    echo; echo -e "${C_GREEN}1)${C_RESET} Download a model from Hugging Face"
    all_model_paths+=("DOWNLOAD"); counter=2

    for dir in "${SEARCH_DIRS[@]}"; do
        dir="${dir/#\~/$HOME}"
        [ ! -d "$dir" ] && continue
        echo; info "Searching in: ${C_CYAN}$dir${C_RESET}"
        mapfile -t models_in_dir < <(find "$dir" -maxdepth 2 -type f -name "*.gguf" ! -name "*mmproj*" ! -name "*.etag" | sort)
        if [ ${#models_in_dir[@]} -gt 0 ]; then
            for model_path in "${models_in_dir[@]}"; do
                echo -e "${C_BLUE}$counter)${C_RESET} $(basename "$model_path")"
                all_model_paths+=("$model_path"); ((counter++))
            done
        else info "No models found in this directory."; fi
    done
    echo
    while true; do
        read -p "Choose an option: " choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge $counter ]; then warn "Invalid selection."; continue; fi
        local selected_index=$((choice - 1))

        if [ "${all_model_paths[$selected_index]}" == "DOWNLOAD" ]; then
            if download_model_from_hf; then return 0; else warn "Download cancelled."; return 1; fi
        else
            SELECTED_MODEL_PATH="${all_model_paths[$selected_index]}"
            info "Selected model: ${C_CYAN}$(basename "$SELECTED_MODEL_PATH")${C_RESET}"
            return 0
        fi
    done
}

# --- Projector / MMProj (Restored) ---
find_or_select_mmproj() {
    local model_dir; model_dir=$(dirname "$SELECTED_MODEL_PATH")
    local model_base_name; model_base_name=$(basename "$SELECTED_MODEL_PATH" .gguf | sed -E 's/-(Q[0-9].*|F[0-9]{2}|IQ[0-9].*)$//i' | sed -E 's/-instruct$//i')

    mapfile -t mmproj_files < <(find "$model_dir" -maxdepth 1 -type f -name "*${model_base_name}*mmproj*.gguf" 2>/dev/null || true)

    if [ ${#mmproj_files[@]} -eq 1 ]; then
        SELECTED_MMPROJ_PATH="${mmproj_files[0]}"
        success "Auto-detected multimodal projector: ${C_CYAN}$(basename "$SELECTED_MMPROJ_PATH")${C_RESET}"
    elif [ ${#mmproj_files[@]} -gt 1 ]; then
        warn "Multiple projectors found:"
        PS3="Select projector: "; select p in "${mmproj_files[@]}" "None"; do
            if [[ "$p" == "None" ]]; then break; fi
            if [[ -n "$p" ]]; then SELECTED_MMPROJ_PATH="$p"; info "Selected: ${C_CYAN}$(basename "$p")${C_RESET}"; break; fi
        done
    else
        read -p "Is this a multimodal model (e.g., LLaVA, Gemma4-Vision)? (y/N) " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            mapfile -t all_p < <(find "$model_dir" -maxdepth 1 -type f -name "*mmproj*.gguf")
            if [ ${#all_p[@]} -eq 0 ]; then warn "No 'mmproj' files found in directory."; return; fi
            warn "Select manually:"
            PS3="Select projector: "; select p in "${all_p[@]}" "None"; do
                if [[ "$p" == "None" ]]; then break; fi
                if [[ -n "$p" ]]; then
                    SELECTED_MMPROJ_PATH="$p"; info "Selected: ${C_CYAN}$(basename "$p")${C_RESET}"
                    jq --arg cfg "$SELECTED_CFG_NAME" --arg key "$SELECTED_MODEL_PATH" --arg mp "$p" '.[$cfg].models[$key].mmproj_path = $mp' "$CONFIG_FILE" > t && mv t "$CONFIG_FILE"
                    break
                fi
            done
        fi
    fi
}

# --- Hardware / Metadata ---
get_gguf_metadata() {
    if command_exists gguf-dump; then gguf-dump --json --no-tensors "$SELECTED_MODEL_PATH" 2>/dev/null; else echo "{}"; fi
}

get_metadata_key() {
    local json_output="$1" search_term="$2" saved_key_var="$3" user_prompt="$4" key=""
    local saved_key
    saved_key=$(jq -r --arg key_name "$saved_key_var" '.global_settings[$key_name] // ""' "$CONFIG_FILE")

    if [[ -n "$saved_key" ]] && [[ $(echo "$json_output" | jq --arg key "$saved_key" -e '.metadata[$key] // null') != "null" ]]; then
        echo "$saved_key"; return 0;
    fi

    local matching_keys_json
    matching_keys_json=$(echo "$json_output" | jq --arg term "$search_term" '[.metadata | to_entries[] | select(.key | contains($term)) | {key: .key, value: .value.value}]')
    mapfile -t matching_keys < <(echo "$matching_keys_json" | jq -r '.[].key')

    if [ ${#matching_keys[@]} -eq 1 ]; then
        key="${matching_keys[0]}"
    elif [ ${#matching_keys[@]} -gt 1 ]; then
        # Smart fallback for Gemma/Gemma4/Qwen etc.
        for k in "${matching_keys[@]}"; do
            if [[ "$k" == *".context_length" ]] && [[ "$search_term" == "context" ]]; then key="$k"; break; fi
            if [[ "$k" == *".block_count" ]] && [[ "$search_term" == "block_count" ]]; then key="$k"; break; fi
        done
        if [[ -z "$key" ]]; then
            warn "Found multiple keys for $user_prompt. Select:" >&2
            local menu_options=("${matching_keys[@]}" "CANCEL")
            PS3="Select key: "
            select key_choice in "${menu_options[@]}"; do
                if [[ "$key_choice" == "CANCEL" ]]; then return 1; fi
                if [[ -n "$key_choice" ]]; then key="$key_choice"; break; fi
            done
        fi
    fi
    if [[ -n "$key" ]]; then
        jq --arg key_name "$saved_key_var" --arg key_val "$key" '.global_settings[$key_name] = $key_val' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        echo "$key"; else return 1
    fi
}

parse_human_readable_size() {
    local input="${1,,}" number; number=$(echo "$input" | sed 's/[kmgtp]$//')
    if [[ ! "$number" =~ ^[0-9]+$ ]]; then echo ""; return; fi
    case "$input" in *k) echo $((number * 1024));; *m) echo $((number * 1024 * 1024));; *) echo "$number";; esac
}

hardware_discovery() {
    info "--- Hardware & Performance Discovery ---"
    local json_output; json_output=$(get_gguf_metadata)

    local ctx_key; ctx_key=$(get_metadata_key "$json_output" "context" "gguf_context_key" "Max Context") || ctx_key="llama.context_length"
    local layer_key; layer_key=$(get_metadata_key "$json_output" "block_count" "gguf_layer_count_key" "Layer Count") || layer_key="llama.block_count"

    local MAX_THEORETICAL_CTX; MAX_THEORETICAL_CTX=$(echo "$json_output" | jq -r --arg key "$ctx_key" '.metadata[$key].value // 4096')
    local max_layers; max_layers=$(echo "$json_output" | jq -r --arg key "$layer_key" '.metadata[$key].value // "-1"')

    success "Model Reports: Context=${C_GREEN}$MAX_THEORETICAL_CTX${C_RESET}, Layers=${C_GREEN}$max_layers${C_RESET}"
    read -p "Enter override context size (max: $MAX_THEORETICAL_CTX) [use max]: " ctx_override
    local effective_max_ctx="$MAX_THEORETICAL_CTX"
    local parsed_ctx=$(parse_human_readable_size "$ctx_override")
    [[ -n "$parsed_ctx" && "$parsed_ctx" -le "$MAX_THEORETICAL_CTX" ]] && effective_max_ctx="$parsed_ctx"

    read -p "Number of GPU layers to test with ('max' for all)[max]: " ngl_input
    local ngl_to_use=0
    [[ "${ngl_input:-max}" == "max" ]] && ngl_to_use=$max_layers || ngl_to_use=$ngl_input

    USABLE_CONTEXT="$effective_max_ctx"
    SAVED_NGL="$ngl_to_use"
    SAVED_THREADS=$(get_physical_cores)

    jq --arg cfg "$SELECTED_CFG_NAME" --arg key "$SELECTED_MODEL_PATH" --argjson ctx "$USABLE_CONTEXT" --argjson ngl "$SAVED_NGL" --arg mmproj "$SELECTED_MMPROJ_PATH" --argjson threads "$SAVED_THREADS" \
       '.[$cfg].models[$key] = {"maximum_context_usable": $ctx, "ngl_for_context": $ngl, "mmproj_path": $mmproj, "optimal_threads": $threads}' "$CONFIG_FILE" > t && mv t "$CONFIG_FILE"
}

get_saved_config() {
    local config_json; config_json=$(jq -r --arg cfg "$SELECTED_CFG_NAME" --arg key "$SELECTED_MODEL_PATH" '.[$cfg].models[$key] // "null"' "$CONFIG_FILE")
    if [ "$config_json" != "null" ]; then
        USABLE_CONTEXT=$(echo "$config_json" | jq -r '.maximum_context_usable // ""')
        SAVED_NGL=$(echo "$config_json" | jq -r '.ngl_for_context // "-1"')
        SELECTED_MMPROJ_PATH=$(echo "$config_json" | jq -r '.mmproj_path // ""')
        SAVED_THREADS=$(echo "$config_json" | jq -r '.optimal_threads // "1"')
    else
        USABLE_CONTEXT=""
    fi
}

execute_terminal() {
    local cmd_args=("$@")
    if command_exists konsole; then konsole --hold -e "$SERVER_BINARY" "${cmd_args[@]}" &
    elif command_exists gnome-terminal; then gnome-terminal -- "$SERVER_BINARY" "${cmd_args[@]}" &
    elif command_exists xterm; then xterm -hold -e "$SERVER_BINARY" "${cmd_args[@]}" &
    else warn "No external terminal found. Running inline..."; "$SERVER_BINARY" "${cmd_args[@]}"; fi
}

# --- Launch Server ---
launch_server() {
    info "--- Prepare to Launch Server ---"

    # Build pin selection
    local current_pin; current_pin=$(jq -r \
        --arg cfg "$SELECTED_CFG_NAME" \
        --arg key "$SELECTED_MODEL_PATH" \
        '.[$cfg].models[$key].pinned_build // empty' "$CONFIG_FILE")

    echo
    if [[ -n "$current_pin" ]]; then
        info "This model is pinned to build: ${C_GREEN}$current_pin${C_RESET}"
    else
        info "This model uses the global active build."
    fi

    local build_options=("Use global active (no pin)")
    if [ -f "$INVENTORY" ]; then
        mapfile -t built_names < <(
            jq -r 'to_entries[] | select(.value.built == true) | .key' "$INVENTORY" 2>/dev/null || true
        )
        for b in "${built_names[@]}"; do build_options+=("Pin to: $b"); done
    fi
    build_options+=("Keep current setting")

    PS3="Select build to use for this model: "
    COLUMNS=1
    select choice in "${build_options[@]}"; do
        case "$choice" in
            "Use global active (no pin)")
                jq --arg cfg "$SELECTED_CFG_NAME" --arg key "$SELECTED_MODEL_PATH" \
                   'del(.[$cfg].models[$key].pinned_build)' \
                   "$CONFIG_FILE" > t && mv t "$CONFIG_FILE"
                resolve_binaries
                break ;;
            "Keep current setting")
                resolve_binaries
                break ;;
            Pin\ to:\ *)
                local pin_name="${choice#Pin to: }"
                jq --arg cfg "$SELECTED_CFG_NAME" --arg key "$SELECTED_MODEL_PATH" --arg pin "$pin_name" \
                   '.[$cfg].models[$key].pinned_build = $pin' \
                   "$CONFIG_FILE" > t && mv t "$CONFIG_FILE"
                resolve_binaries
                break ;;
            "") warn "Invalid selection." ;;
        esac
    done

    local model_alias; model_alias=$(basename "$SELECTED_MODEL_PATH" .gguf)
    read -p "Server Alias [--alias] [$model_alias]: " -e alias_name_input
    local alias_name=${alias_name_input:-$model_alias}

    local last_port; last_port=$(jq -r --arg cfg "$SELECTED_CFG_NAME" --arg key "$SELECTED_MODEL_PATH" '.[$cfg].models[$key].last_port // "8080"' "$CONFIG_FILE")
    read -p "Port to use [--port] [$last_port]: " port; port=${port:-$last_port}

    local last_cache; last_cache=$(jq -r --arg cfg "$SELECTED_CFG_NAME" --arg key "$SELECTED_MODEL_PATH" '.[$cfg].models[$key].last_cache // "q8_0"' "$CONFIG_FILE")
    local cache_options=("q8_0" "q4_0" "q4_1" "iq4_nl" "q5_0" "q5_1")
    local cache_type; local default_idx=1
    for i in "${!cache_options[@]}"; do if [[ "${cache_options[$i]}" == "$last_cache" ]]; then default_idx=$((i+1)); break; fi; done
    PS3="Select cache quantization [${default_idx}]: "; select opt in "${cache_options[@]}"; do cache_type=${opt:-${cache_options[$((default_idx-1))]}}; break; done

    read -p "CPU Threads (-t) [$SAVED_THREADS]: " threads; threads=${threads:-$SAVED_THREADS}
    local last_parallel; last_parallel=$(jq -r --arg cfg "$SELECTED_CFG_NAME" --arg key "$SELECTED_MODEL_PATH" '.[$cfg].models[$key].last_parallel // 1' "$CONFIG_FILE")
    read -p "Parallel slots (-np)[$last_parallel]: " parallel_slots; parallel_slots=${parallel_slots:-$last_parallel}

    local cmd_args=("-m" "$SELECTED_MODEL_PATH" "-c" "$USABLE_CONTEXT" "--host" "0.0.0.0" "--port" "$port" "--alias" "$alias_name" "--props" "-ctk" "$cache_type" "-np" "$parallel_slots" -t "$threads" "-fa" "on")
    [[ -n "$SELECTED_MMPROJ_PATH" ]] && cmd_args+=("--mmproj" "$SELECTED_MMPROJ_PATH")

    # GPU / Tensor Split
    info "Available Devices:"
    "$SERVER_BINARY" --list-devices 2>&1 | grep -v "main" | grep -v "llm_load" || true
    echo "Leave blank for GPU, or type 'CPU Only'"
    read -p "Enter device selection [Auto]: " device_choice

    local final_ngl=$SAVED_NGL
    local tensor_split_str=""
    if [[ "${device_choice,,}" == "cpu only" ]]; then
        cmd_args+=("-ngl" "0" "--device" "none" "--no-mmproj-offload"); final_ngl=0
    else
        cmd_args+=("-ngl" "$SAVED_NGL")
        [[ -n "$device_choice" ]] && cmd_args+=("--device" "$device_choice")

        read -p "Split model across multiple GPUs with --tensor-split? (y/N) " split_choice
        if [[ "$split_choice" =~ ^[Yy]$ ]]; then
            read -p "Enter tensor split ratios (e.g., '1,1' for even split): " tensor_split_str
            [[ -n "$tensor_split_str" ]] && cmd_args+=("--tensor-split" "$tensor_split_str")
        fi
    fi

    jq --arg cfg "$SELECTED_CFG_NAME" --arg key "$SELECTED_MODEL_PATH" --arg p "$port" --arg c "$cache_type" --arg ps "$parallel_slots" '.[$cfg].models[$key].last_port = $p | .[$cfg].models[$key].last_cache = $c | .[$cfg].models[$key].last_parallel = $ps' "$CONFIG_FILE" > t && mv t "$CONFIG_FILE"

    read -p "Save launch as a Preset? (Enter name or leave blank to skip): " preset_name
    if [[ -n "$preset_name" ]]; then
        jq --arg name "$preset_name" --arg model "$SELECTED_MODEL_PATH" --arg alias "$alias_name" --arg port "$port" --arg cache "$cache_type" --arg threads "$threads" --arg parallel "$parallel_slots" --arg ctx "$USABLE_CONTEXT" --arg ngl "$final_ngl" --arg device "$device_choice" --arg mmproj "$SELECTED_MMPROJ_PATH" --arg ts "$tensor_split_str" \
           '.launch_presets[$name] = {model_path: $model, alias: $alias, port: $port, cache_type: $cache, threads: $threads, parallel_slots: $parallel, context: $ctx, ngl: $ngl, device: $device, mmproj_path: $mmproj, tensor_split: $ts}' "$CONFIG_FILE" > t && mv t "$CONFIG_FILE"; success "Preset saved."
    fi

    local launch_term; saved_term=$(jq -r '.global_settings.launch_in_new_terminal // "n"' "$CONFIG_FILE")
    prompt_term=$([[ "$saved_term" == "y" ]] && echo "Y/n" || echo "y/N")
    read -p "Launch in new terminal? [${prompt_term}]: " choice; launch_term=${choice:-$saved_term}; [[ "$launch_term" =~ ^[Yy]$ ]] && launch_term="y" || launch_term="n"
    jq --arg val "$launch_term" '.global_settings.launch_in_new_terminal = $val' "$CONFIG_FILE" >t&&mv t "$CONFIG_FILE"

    if [[ "$launch_term" == "y" ]]; then
        info "Launching via terminal wrapper..."
        execute_terminal "${cmd_args[@]}"
    else
        local log_file="$CONFIG_DIR/${alias_name}_${port}.log"
        info "Launching in background. Log: ${C_CYAN}$log_file${C_RESET}"
        nohup "$SERVER_BINARY" "${cmd_args[@]}" > "$log_file" 2>&1 & disown
        sleep 2; if pgrep -f "$alias_name" >/dev/null; then success "Server started."; else error "Server failed. Check log: $log_file"; fi
    fi
}

configure_and_launch() {
    ! manage_and_select_model_dirs && return
    ! select_model_from_dirs && return
    [ -z "$SELECTED_MODEL_PATH" ] && return

    get_saved_config
    resolve_binaries
    if [[ -z "$SELECTED_MMPROJ_PATH" ]]; then find_or_select_mmproj; fi

    # Conditional Hardware Discovery (Restored behavior)
    if [ -z "$USABLE_CONTEXT" ]; then
        hardware_discovery
    else
        success "Found saved config: Context=${C_GREEN}$USABLE_CONTEXT${C_RESET}, NGL=$SAVED_NGL, Threads=$SAVED_THREADS"
        read -p "Run hardware/context discovery again? (y/N) " c
        if [[ "$c" =~ ^[Yy]$ ]]; then hardware_discovery; fi
    fi
    launch_server
}

launch_from_preset() {
    local preset_name="$1"
    info "Launching preset: ${C_GREEN}$preset_name${C_RESET}"
    local preset; preset=$(jq -c --arg name "$preset_name" '.launch_presets[$name]' "$CONFIG_FILE")

    local model_path=$(echo "$preset" | jq -r '.model_path'); local alias_name=$(echo "$preset" | jq -r '.alias')
    local port=$(echo "$preset" | jq -r '.port'); local cache_type=$(echo "$preset" | jq -r '.cache_type')
    local threads=$(echo "$preset" | jq -r '.threads'); local parallel=$(echo "$preset" | jq -r '.parallel_slots')
    local context=$(echo "$preset" | jq -r '.context'); local ngl=$(echo "$preset" | jq -r '.ngl')
    local device=$(echo "$preset" | jq -r '.device'); local mmproj=$(echo "$preset" | jq -r '.mmproj_path')
    local tensor_split=$(echo "$preset" | jq -r '.tensor_split')

    local cmd_args=("-m" "$model_path" "-c" "$context" "--host" "0.0.0.0" "--port" "$port" "--alias" "$alias_name" "--props" "-ctk" "$cache_type" "-np" "$parallel" -t "$threads" "-fa" "on")
    [[ "$mmproj" != "null" && -n "$mmproj" ]] && cmd_args+=("--mmproj" "$mmproj")
    [[ "$tensor_split" != "null" && -n "$tensor_split" ]] && cmd_args+=("--tensor-split" "$tensor_split")

    if [[ -z "$device" || "${device,,}" == "cpu only" ]]; then cmd_args+=("-ngl" "0" "--device" "none" "--no-mmproj-offload"); else cmd_args+=("-ngl" "$ngl" "--device" "$device"); fi

    local launch_term=$(jq -r '.global_settings.launch_in_new_terminal // "n"' "$CONFIG_FILE")
    if [[ "$launch_term" == "y" ]]; then execute_terminal "${cmd_args[@]}"; else
        local log_file="$CONFIG_DIR/${alias_name}_${port}.log"
        info "Launching in background. Log: ${C_CYAN}$log_file${C_RESET}"
        nohup "$SERVER_BINARY" "${cmd_args[@]}" > "$log_file" 2>&1 & disown; sleep 2
    fi
}

manage_instances() {
    while true; do
        clear; echo -e "${C_PURPLE}--- Manage Running Server Instances ---${C_RESET}"; discover_instances
        if [ ${#RUNNING_INSTANCES[@]} -eq 0 ]; then info "No active instances."; read -n 1 -s -r -p "Press any key..."; return; fi

        echo -e "Active instances:"
        local -a pids_array=(); local i=1
        for pid in $(printf "%s\n" "${!RUNNING_INSTANCES[@]}" | sort -n); do
            echo -e "  ${C_GREEN}[$i]${C_RESET} PID: ${C_CYAN}$pid${C_RESET} | ${RUNNING_INSTANCES[$pid]}"
            pids_array+=($pid); ((i++))
        done
        echo; read -p "Enter number to terminate, or [Q]uit: " choice
        case "$choice" in
            [qQ]) break ;;
            *) if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] &&[ "$choice" -le ${#pids_array[@]} ]; then
                local pid=${pids_array[$((choice-1))]}; info "Terminating PID ${C_RED}$pid${C_RESET}..."
                kill "$pid"; sleep 1; if ! ps -p "$pid" >/dev/null; then success "Terminated."; else warn "Failed."; fi
                read -n 1 -s -r -p "Continue..."
            else warn "Invalid."; sleep 1; fi ;;
        esac
    done
}

main_menu() {
    trap 'echo; info "Exiting..."; exit 0' INT
    while true; do
        discover_instances; clear
        echo -e "${C_PURPLE}--- NixOS Llama.cpp Launcher ---${C_RESET}"
        local options=()
        if jq -e '.launch_presets' "$CONFIG_FILE" > /dev/null 2>&1; then
            mapfile -t presets < <(jq -r '.launch_presets | keys[] | select(.)' "$CONFIG_FILE")
            for preset in "${presets[@]}"; do options+=("Launch Preset: $preset"); done
        fi
        options+=("Configure and launch a new server..." "Manage running instances (${#RUNNING_INSTANCES[@]})" "Exit")

        PS3="Select an option: "
        select choice in "${options[@]}"; do
            case "$choice" in
                "Configure and launch a new server...") configure_and_launch; read -n 1 -s -r -p "Press any key to return to menu..."; break ;;
                "Manage running instances"*) manage_instances; break ;;
                "Exit") info "Exiting. Servers continue in background."; exit 0 ;;
                "") warn "Invalid selection."; break ;;
                *) if [[ "$choice" == "Launch Preset: "* ]]; then
                        launch_from_preset "${choice#Launch Preset: }"
                        read -n 1 -s -r -p "Press any key to return to menu..."; break
                   fi;;
            esac
        done
    done
}

check_dependencies
main_menu "$@"
