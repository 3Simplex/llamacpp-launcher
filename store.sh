#!/usr/bin/env bash
set -euo pipefail

# --- Store Configuration ---
STORE_DIR="$HOME/src/flakes/llamacpp-flake/store"
FLAKE_DIR="$HOME/src/flakes/llamacpp-flake"
INVENTORY="$STORE_DIR/inventory.json"
GLOBAL_LINK="$STORE_DIR/global-active"

mkdir -p "$STORE_DIR"
if [ ! -f "$INVENTORY" ]; then echo '{}' > "$INVENTORY"; fi

# --- Colors ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_PURPLE='\033[0;35m'
C_CYAN='\033[0;36m'

# --- Helpers ---
info()    { echo -e "${C_BLUE}INFO:${C_RESET} $1"; }
warn()    { echo -e "${C_YELLOW}WARN:${C_RESET} $1"; }
error()   { echo -e "${C_RED}ERROR:${C_RESET} $1" >&2; }
success() { echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"; }

# --- Inventory Helpers ---
inventory_get() {
    # inventory_get <name> <field>   — returns raw value or empty string
    local name="$1" field="$2"
    jq -r --arg n "$name" --arg f "$field" '.[$n][$f] // empty' "$INVENTORY"
}

inventory_names() {
    jq -r 'keys[]' "$INVENTORY" 2>/dev/null || true
}

inventory_count() {
    jq 'length' "$INVENTORY"
}

# ─────────────────────────────────────────────
# FLOW: Add / Build a new target
# ─────────────────────────────────────────────
flow_add_and_build() {
    clear
    echo -e "${C_PURPLE}--- Add & Build a llama.cpp Target ---${C_RESET}"
    echo

    # 1. Name
    read -p "Enter a short name for this build (e.g. 'main-latest', 'fast-v1'): " build_name
    if [[ -z "$build_name" ]]; then warn "Name cannot be empty."; return 1; fi

    # Warn if overwriting
    if jq -e --arg n "$build_name" '.[$n]' "$INVENTORY" > /dev/null 2>&1; then
        read -p "A build named '${C_CYAN}$build_name${C_RESET}' already exists. Overwrite? (y/N) " ow
        [[ ! "$ow" =~ ^[Yy]$ ]] && return 0
    fi

    # 2. Source repo
    echo
    info "Source repository"
    echo -e "  Default upstream: ${C_CYAN}ggml-org/llama.cpp${C_RESET}"
    read -p "Enter GitHub repo (user/repo) [ggml-org/llama.cpp]: " repo_input
    local repo="${repo_input:-ggml-org/llama.cpp}"

    # 3. Ref type
    echo
    echo -e "${C_GREEN}What kind of ref do you want to build from?${C_RESET}"
    local ref_type
    PS3="Select ref type: "
    select rt in "Branch" "Tag / Release" "Commit hash" "Latest HEAD (default branch)"; do
        ref_type="$rt"; break
    done

    local ref_value=""
    case "$ref_type" in
        "Branch")
            echo
            # Offer to list remote branches
            read -p "Fetch branch list from GitHub? (y/N) " fetch_branches
            if [[ "$fetch_branches" =~ ^[Yy]$ ]]; then
                info "Fetching branches for ${C_CYAN}$repo${C_RESET}..."
                mapfile -t branches < <(
                    curl -sfL "https://api.github.com/repos/${repo}/branches?per_page=50" \
                    | jq -r '.[].name' 2>/dev/null || true
                )
                if [ ${#branches[@]} -gt 0 ]; then
                    PS3="Select branch: "
                    select b in "${branches[@]}" "Enter manually"; do
                        if [[ "$b" == "Enter manually" ]]; then
                            read -p "Branch name: " ref_value
                        else
                            ref_value="$b"
                        fi
                        break
                    done
                else
                    warn "Could not fetch branches. Enter manually."
                    read -p "Branch name: " ref_value
                fi
            else
                read -p "Branch name: " ref_value
            fi
            ;;

        "Tag / Release")
            echo
            read -p "Fetch tag list from GitHub? (y/N) " fetch_tags
            if [[ "$fetch_tags" =~ ^[Yy]$ ]]; then
                info "Fetching tags for ${C_CYAN}$repo${C_RESET}..."
                mapfile -t tags < <(
                    curl -sfL "https://api.github.com/repos/${repo}/tags?per_page=50" \
                    | jq -r '.[].name' 2>/dev/null || true
                )
                if [ ${#tags[@]} -gt 0 ]; then
                    PS3="Select tag: "
                    select t in "${tags[@]}" "Enter manually"; do
                        if [[ "$t" == "Enter manually" ]]; then
                            read -p "Tag name: " ref_value
                        else
                            ref_value="$t"
                        fi
                        break
                    done
                else
                    warn "Could not fetch tags. Enter manually."
                    read -p "Tag name: " ref_value
                fi
            else
                read -p "Tag name (e.g. b5280): " ref_value
            fi
            ;;

        "Commit hash")
            echo
            read -p "Enter full or short commit hash: " ref_value
            ;;

        "Latest HEAD (default branch)")
            ref_value=""
            ;;
    esac

    # 4. Construct the Nix flake URL
    local flake_url
    if [[ -n "$ref_value" ]]; then
        flake_url="github:${repo}/${ref_value}"
    else
        flake_url="github:${repo}"
    fi

    echo
    info "Flake URL: ${C_CYAN}$flake_url${C_RESET}"
    echo

    # 5. Confirm & build
    read -p "Build now? (Y/n) " do_build
    if [[ "${do_build:-y}" =~ ^[Yy]$ ]]; then
        _run_build "$build_name" "$repo" "$ref_value" "$flake_url"
    else
        # Save to inventory without building
        local tmp
        tmp=$(jq -c \
            --arg n "$build_name" \
            --arg repo "$repo" \
            --arg ref "$ref_value" \
            --arg url "$flake_url" \
            '.[$n] = {"repo": $repo, "ref": $ref, "url": $url, "built": false, "build_date": ""}' \
            "$INVENTORY")
        echo "$tmp" > "$INVENTORY"
        success "Saved '${build_name}' to inventory (not yet built)."
    fi
}

_run_build() {
    local build_name="$1" repo="$2" ref_value="$3" flake_url="$4"
    local out_link="${STORE_DIR}/${build_name}"

    info "Building ${C_CYAN}$build_name${C_RESET} from ${C_PURPLE}$flake_url${C_RESET}..."
    info "This may take a while. Nix will reuse cached layers where possible."
    echo

    if ( cd "$FLAKE_DIR" && nix build .#default \
            --override-input llama-cpp "$flake_url" \
            -o "$out_link" ); then
        local build_date; build_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local tmp
        tmp=$(jq -c \
            --arg n "$build_name" \
            --arg repo "$repo" \
            --arg ref "$ref_value" \
            --arg url "$flake_url" \
            --arg date "$build_date" \
            '.[$n] = {"repo": $repo, "ref": $ref, "url": $url, "built": true, "build_date": $date}' \
            "$INVENTORY")
        echo "$tmp" > "$INVENTORY"
        success "Build complete → ${C_CYAN}$out_link${C_RESET}"
        echo
        read -p "Set '${build_name}' as the global active build now? (Y/n) " set_global
        if [[ "${set_global:-y}" =~ ^[Yy]$ ]]; then
            _set_global "$build_name"
        fi
    else
        error "Build failed for '$build_name'."
        return 1
    fi
}

# ─────────────────────────────────────────────
# FLOW: Rebuild an existing inventory entry
# ─────────────────────────────────────────────
flow_rebuild() {
    clear
    echo -e "${C_PURPLE}--- Rebuild an Existing Target ---${C_RESET}"
    echo

    mapfile -t names < <(inventory_names)
    if [ ${#names[@]} -eq 0 ]; then
        warn "Inventory is empty. Add a build first."
        return
    fi

    local options=()
    for n in "${names[@]}"; do
        local repo; repo=$(inventory_get "$n" "repo")
        local ref; ref=$(inventory_get "$n" "ref")
        local built; built=$(inventory_get "$n" "built")
        local marker; [[ "$built" == "true" ]] && marker="${C_GREEN}[built]${C_RESET}" || marker="${C_YELLOW}[not built]${C_RESET}"
        options+=("$n  —  ${repo}@${ref:-HEAD}  $marker")
    done
    options+=("CANCEL")

    PS3="Select target to rebuild: "
    COLUMNS=1
    select choice in "${options[@]}"; do
        [[ "$choice" == "CANCEL" ]] && return
        [[ -z "$choice" ]] && warn "Invalid selection." && continue
        # Extract the name (first word before spaces)
        local build_name="${choice%%  *}"
        local url; url=$(inventory_get "$build_name" "url")
        local repo; repo=$(inventory_get "$build_name" "repo")
        local ref; ref=$(inventory_get "$build_name" "ref")
        _run_build "$build_name" "$repo" "$ref" "$url"
        break
    done
}

# ─────────────────────────────────────────────
# FLOW: Switch global active build
# ─────────────────────────────────────────────
_set_global() {
    local build_name="$1"
    local out_link="${STORE_DIR}/${build_name}"

    if [ ! -e "$out_link" ]; then
        error "'${build_name}' has not been built yet. Build it first."
        return 1
    fi

    ln -sfn "$out_link" "$GLOBAL_LINK"
    success "Global active build set to: ${C_GREEN}$build_name${C_RESET}"
    info "Launcher will now use: ${C_CYAN}${GLOBAL_LINK}/bin/llama-server${C_RESET}"
}

flow_switch_active() {
    clear
    echo -e "${C_PURPLE}--- Switch Active Build ---${C_RESET}"
    echo

    # Determine current active
    local current_active=""
    if [ -L "$GLOBAL_LINK" ]; then
        current_active=$(basename "$(readlink "$GLOBAL_LINK")")
    fi

    # Collect only built entries
    mapfile -t names < <(inventory_names)
    local built_names=()
    for n in "${names[@]}"; do
        local out_link="${STORE_DIR}/${n}"
        # Check both inventory flag and that the symlink/path actually exists
        if [ -e "$out_link" ]; then
            built_names+=("$n")
        fi
    done

    if [ ${#built_names[@]} -eq 0 ]; then
        warn "No built targets found. Build something first."
        return
    fi

    echo -e "Current active: ${C_GREEN}${current_active:-none}${C_RESET}"
    echo

    local options=()
    for n in "${built_names[@]}"; do
        local repo; repo=$(inventory_get "$n" "repo")
        local ref; ref=$(inventory_get "$n" "ref")
        local date; date=$(inventory_get "$n" "build_date")
        local active_marker=""
        [[ "$n" == "$current_active" ]] && active_marker=" ${C_GREEN}← active${C_RESET}"
        options+=("$n  —  ${repo}@${ref:-HEAD}  (built: ${date:-unknown})${active_marker}")
    done
    options+=("CANCEL")

    PS3="Select build to activate: "
    COLUMNS=1
    select choice in "${options[@]}"; do
        [[ "$choice" == "CANCEL" ]] && return
        [[ -z "$choice" ]] && warn "Invalid selection." && continue
        local build_name="${choice%%  *}"
        _set_global "$build_name"
        break
    done
}

# ─────────────────────────────────────────────
# FLOW: List all builds
# ─────────────────────────────────────────────
flow_list() {
    clear
    echo -e "${C_PURPLE}--- llama.cpp Build Store ---${C_RESET}"
    echo

    local current_active=""
    if [ -L "$GLOBAL_LINK" ]; then
        current_active=$(basename "$(readlink "$GLOBAL_LINK")")
        echo -e "Global Active: ${C_GREEN}$current_active${C_RESET}"
    else
        echo -e "Global Active: ${C_YELLOW}none set${C_RESET}"
    fi

    echo
    local count; count=$(inventory_count)
    if [ "$count" -eq 0 ]; then
        warn "Inventory is empty."
        return
    fi

    echo -e "${C_CYAN}Name                  Repo                        Ref/Hash               Built   Date${C_RESET}"
    echo    "─────────────────────────────────────────────────────────────────────────────────────"

    mapfile -t names < <(inventory_names)
    for n in "${names[@]}"; do
        local repo; repo=$(inventory_get "$n" "repo")
        local ref; ref=$(inventory_get "$n" "ref")
        local built; built=$(inventory_get "$n" "built")
        local date; date=$(inventory_get "$n" "build_date")
        local active_marker=""
        [[ "$n" == "$current_active" ]] && active_marker=" ${C_GREEN}●${C_RESET}"

        local built_str
        [[ "$built" == "true" ]] && built_str="${C_GREEN}yes${C_RESET}" || built_str="${C_YELLOW}no${C_RESET} "

        printf "%-22s %-28s %-22s %-8b %s%b\n" \
            "$n" \
            "$repo" \
            "${ref:-HEAD}" \
            "$built_str" \
            "${date:-—}" \
            "$active_marker"
    done
    echo
}

# ─────────────────────────────────────────────
# FLOW: Remove a build
# ─────────────────────────────────────────────
flow_remove() {
    clear
    echo -e "${C_PURPLE}--- Remove a Build ---${C_RESET}"
    echo

    mapfile -t names < <(inventory_names)
    if [ ${#names[@]} -eq 0 ]; then
        warn "Inventory is empty."
        return
    fi

    local current_active=""
    [ -L "$GLOBAL_LINK" ] && current_active=$(basename "$(readlink "$GLOBAL_LINK")")

    local options=()
    for n in "${names[@]}"; do
        local repo; repo=$(inventory_get "$n" "repo")
        local ref; ref=$(inventory_get "$n" "ref")
        local active_marker=""
        [[ "$n" == "$current_active" ]] && active_marker=" [ACTIVE]"
        options+=("$n  —  ${repo}@${ref:-HEAD}${active_marker}")
    done
    options+=("CANCEL")

    PS3="Select build to remove: "
    COLUMNS=1
    select choice in "${options[@]}"; do
        [[ "$choice" == "CANCEL" ]] && return
        [[ -z "$choice" ]] && warn "Invalid selection." && continue
        local build_name="${choice%%  *}"

        if [[ "$build_name" == "$current_active" ]]; then
            warn "'${build_name}' is currently the active build!"
            read -p "Remove anyway? This will clear the global-active link. (y/N) " confirm
            [[ ! "$confirm" =~ ^[Yy]$ ]] && return
            rm -f "$GLOBAL_LINK"
        fi

        rm -f "${STORE_DIR}/${build_name}"
        local tmp; tmp=$(jq -c --arg n "$build_name" 'del(.[$n])' "$INVENTORY")
        echo "$tmp" > "$INVENTORY"
        success "Removed '${build_name}'."
        break
    done
}

# ─────────────────────────────────────────────
# Main Menu
# ─────────────────────────────────────────────
main_menu() {
    trap 'echo; info "Exiting store..."; exit 0' INT

    while true; do
        clear
        echo -e "${C_PURPLE}--- llama.cpp Build Store ---${C_RESET}"

        # Status line
        if [ -L "$GLOBAL_LINK" ]; then
            local active; active=$(basename "$(readlink "$GLOBAL_LINK")")
            echo -e "Active build: ${C_GREEN}$active${C_RESET}"
        else
            echo -e "Active build: ${C_YELLOW}none${C_RESET}"
        fi

        local count; count=$(inventory_count)
        echo -e "Inventory: ${C_CYAN}$count${C_RESET} target(s)"
        echo

        local options=(
            "Add & build a new target..."
            "Rebuild an existing target..."
            "Switch active build (launcher will use this)"
            "List all builds"
            "Remove a build"
            "Exit"
        )

        PS3="Select an option: "
        select choice in "${options[@]}"; do
            case "$choice" in
                "Add & build a new target...")
                    flow_add_and_build
                    read -n 1 -s -r -p "Press any key to return to menu..."
                    break
                    ;;
                "Rebuild an existing target...")
                    flow_rebuild
                    read -n 1 -s -r -p "Press any key to return to menu..."
                    break
                    ;;
                "Switch active build (launcher will use this)")
                    flow_switch_active
                    read -n 1 -s -r -p "Press any key to return to menu..."
                    break
                    ;;
                "List all builds")
                    flow_list
                    read -n 1 -s -r -p "Press any key to return to menu..."
                    break
                    ;;
                "Remove a build")
                    flow_remove
                    read -n 1 -s -r -p "Press any key to return to menu..."
                    break
                    ;;
                "Exit")
                    info "Exiting."
                    exit 0
                    ;;
                "")
                    warn "Invalid selection."
                    break
                    ;;
            esac
        done
    done
}

# ─────────────────────────────────────────────
# Entry — support both TUI and CLI modes
# ─────────────────────────────────────────────
if [ $# -eq 0 ]; then
    main_menu
else
    # Thin CLI passthrough for scripting / store.sh set-global fast-baseline etc.
    case "$1" in
        add)    flow_add_and_build ;;
        rebuild) flow_rebuild ;;
        switch|set-global) flow_switch_active ;;
        list)   flow_list; echo ;;
        remove) flow_remove ;;
        *)      echo "Usage: llamacpp-store [add|rebuild|switch|list|remove]"
                echo "Run with no arguments for interactive mode." ;;
    esac
fi
