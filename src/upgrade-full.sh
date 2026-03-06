#!/bin/bash
# GooseStack Full Upgrade
# Implements full-stack upgrade with backup, merge, LaunchAgent rebuild, and health checks.
set -euo pipefail

# Colors (matching GooseStack style)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly PURPLE='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Globals
DRY_RUN=false
FULL_UPGRADE=false
INJECT_KEYS=false
ANTHROPIC_KEY=""
OPENAI_KEY=""
GOOGLE_KEY=""
GROQ_KEY=""
XAI_KEY=""
BRAVE_KEY=""
TELEGRAM_BOT_TOKEN=""

OPENAI_KEY="${OPENAI_KEY:-}"
GOOGLE_KEY="${GOOGLE_KEY:-}"
GROQ_KEY="${GROQ_KEY:-}"
XAI_KEY="${XAI_KEY:-}"
BRAVE_KEY="${BRAVE_KEY:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
ANTHROPIC_KEY="${ANTHROPIC_KEY:-}"

TEMP_DIR=""
INSTALL_DIR=""
INSTALL_SRC_DIR=""
SCRIPT_DIR=""
GOOSE_REPO="https://github.com/TheBigAndFamousGoose/goosestack"

GOOSE_HOME="$HOME/.openclaw"
WORKSPACE_DIR="$GOOSE_HOME/workspace"
CONFIG_FILE="$GOOSE_HOME/openclaw.json"
LOCK_FILE="$GOOSE_HOME/.upgrade-full.lock"
BACKUP_DIR=""

USER_TZ=""
TELEGRAM_CHAT_ID=""
LESSON_DB_PATH="~/.openclaw/pipeline/data/goosestack.db"
LESSON_RECALL_DEPLOY_OK=false

UPDATED_ITEMS=()
SKIPPED_ITEMS=()

# Logging
log_info() {
    echo -e "${CYAN}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}" >&2
}

log_step() {
    echo -e "\n${BOLD}${PURPLE}🚀 $1${NC}"
}

# Cleanup
cleanup() {
    local exit_code=$?

    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi

    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
    fi

    exit $exit_code
}
trap cleanup EXIT

show_help() {
    cat <<'EOF_HELP'
Usage: upgrade-full.sh --full [OPTIONS]

Required:
  --full                    Run full upgrade workflow

Options:
  --dry-run                 Show what would change without changing anything
  --inject-keys             Enable API key injection (phase 15)
  --anthropic-key <value>   Anthropic API key to inject
  --openai-key <value>      OpenAI API key to inject
  --google-key <value>      Google API key to inject
  --groq-key <value>        Groq API key to inject
  --xai-key <value>         xAI API key to inject
  --brave-key <value>       Brave Search API key to inject
  --telegram-bot-token <v>  Telegram bot token to inject
  -h, --help                Show this help
EOF_HELP
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full)
                FULL_UPGRADE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --inject-keys)
                INJECT_KEYS=true
                shift
                ;;
            --anthropic-key)
                ANTHROPIC_KEY="${2:-}"
                shift 2
                ;;
            --openai-key)
                OPENAI_KEY="${2:-}"
                shift 2
                ;;
            --google-key)
                GOOGLE_KEY="${2:-}"
                shift 2
                ;;
            --groq-key)
                GROQ_KEY="${2:-}"
                shift 2
                ;;
            --xai-key)
                XAI_KEY="${2:-}"
                shift 2
                ;;
            --brave-key)
                BRAVE_KEY="${2:-}"
                shift 2
                ;;
            --telegram-bot-token)
                TELEGRAM_BOT_TOKEN="${2:-}"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [[ "$FULL_UPGRADE" != "true" ]]; then
        log_error "--full is required for this command"
        show_help
        exit 1
    fi
}

add_updated() {
    UPDATED_ITEMS+=("$1")
}

add_skipped() {
    SKIPPED_ITEMS+=("$1")
}

acquire_lock() {
    mkdir -p "$GOOSE_HOME"

    if [[ -f "$LOCK_FILE" ]]; then
        local existing_pid
        existing_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [[ -n "$existing_pid" ]] && ps -p "$existing_pid" >/dev/null 2>&1; then
            log_error "Another full upgrade is already running (PID: $existing_pid)"
            exit 1
        fi
        log_warning "Stale lock file found, replacing it"
    fi

    echo "$$" > "$LOCK_FILE"
    log_info "Lock acquired: $LOCK_FILE"
}

prompt_input() {
    local prompt="$1"
    local default_value="${2:-}"
    local result=""

    if [[ -t 0 && -r /dev/tty && -w /dev/tty ]]; then
        if [[ -n "$default_value" ]]; then
            echo -ne "$prompt [$default_value]: " > /dev/tty
        else
            echo -ne "$prompt: " > /dev/tty
        fi
        read -r result < /dev/tty || result="$default_value"
    else
        result="$default_value"
    fi

    if [[ -z "$result" ]]; then
        result="$default_value"
    fi

    echo "$result"
}

resolve_local_timezone() {
    local tz_path
    tz_path=$(readlink /etc/localtime 2>/dev/null || true)

    if [[ "$tz_path" == *"zoneinfo/"* ]]; then
        echo "${tz_path#*zoneinfo/}"
        return
    fi

    if command -v systemsetup >/dev/null 2>&1; then
        local sys_tz
        sys_tz=$(systemsetup -gettimezone 2>/dev/null | awk -F': ' '{print $2}' || true)
        if [[ -n "$sys_tz" ]]; then
            echo "$sys_tz"
            return
        fi
    fi

    echo "UTC"
}

resolve_openclaw_entry() {
    local openclaw_bin
    openclaw_bin=$(command -v openclaw)

    if [[ -L "$openclaw_bin" ]]; then
        local link_target
        link_target=$(readlink "$openclaw_bin")
        if [[ "$link_target" != /* ]]; then
            echo "$(cd "$(dirname "$openclaw_bin")" && cd "$(dirname "$link_target")" && pwd)/$(basename "$link_target")"
        else
            echo "$link_target"
        fi
    else
        echo "$openclaw_bin"
    fi
}

# Phase 1: Preflight checks.
phase_1_preflight() {
    log_step "Phase 1: Preflight checks"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Missing config: $CONFIG_FILE"
        exit 1
    fi

    local required_cmds=(node npm brew sqlite3)
    local cmd
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done

    if ! command -v openclaw >/dev/null 2>&1; then
        log_warning "openclaw binary not found in PATH (some phases may be skipped)"
    fi

    # Check for Xcode Command Line Tools (required for native npm packages like better-sqlite3)
    if ! xcode-select -p >/dev/null 2>&1; then
        log_warning "Xcode Command Line Tools not found — required for native npm packages"
        log_info "Installing Xcode Command Line Tools (this may take a few minutes)..."
        if [[ "$DRY_RUN" != "true" ]]; then
            xcode-select --install 2>/dev/null || true
            # Wait for installation to complete
            log_info "Please complete the Xcode CLT installation dialog, then re-run this script."
            exit 0
        else
            log_info "[DRY RUN] Would: xcode-select --install"
        fi
    else
        log_info "Xcode Command Line Tools: $(xcode-select -p)"
    fi

    add_updated "Preflight checks passed"
}

# Phase 2: Back up workspace + config to a timestamped folder.
phase_2_backup() {
    log_step "Phase 2: Backup workspace and configuration"

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    BACKUP_DIR="$HOME/.openclaw-backup-upgrade-$timestamp"

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$BACKUP_DIR"
        if [[ -d "$WORKSPACE_DIR" ]]; then
            cp -R "$WORKSPACE_DIR" "$BACKUP_DIR/workspace"
        fi
        cp "$CONFIG_FILE" "$BACKUP_DIR/openclaw.json"
        log_success "Backup saved to $BACKUP_DIR"
    else
        log_info "[DRY RUN] Would: mkdir -p $BACKUP_DIR"
        log_info "[DRY RUN] Would: copy $WORKSPACE_DIR -> $BACKUP_DIR/workspace"
        log_info "[DRY RUN] Would: copy $CONFIG_FILE -> $BACKUP_DIR/openclaw.json"
    fi

    add_updated "Backup phase completed"
}

# Phase 3: Fetch latest GooseStack from GitHub.
phase_3_fetch_latest() {
    log_step "Phase 3: Fetch latest GooseStack"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

    if [[ "$DRY_RUN" != "true" ]]; then
        TEMP_DIR=$(mktemp -d)
        if command -v git >/dev/null 2>&1; then
            git clone --depth 1 --branch "${GOOSE_BRANCH:-main}" "$GOOSE_REPO" "$TEMP_DIR/goosestack-latest"
        else
            mkdir -p "$TEMP_DIR/goosestack-latest"
            curl -fsSL "$GOOSE_REPO/archive/main.tar.gz" | tar -xz --strip-components=1 -C "$TEMP_DIR/goosestack-latest"
        fi
        INSTALL_DIR="$TEMP_DIR/goosestack-latest"
    else
        log_info "[DRY RUN] Would: clone latest GooseStack from $GOOSE_REPO"
        INSTALL_DIR="$SCRIPT_DIR"
    fi

    INSTALL_SRC_DIR="$INSTALL_DIR/src"

    if [[ ! -d "$INSTALL_SRC_DIR" ]]; then
        log_error "Fetched GooseStack is missing src/"
        exit 1
    fi

    add_updated "Fetched latest GooseStack"
}

# Phase 4: Interactive config wizard for timezone/chat ID/DB path.
phase_4_interactive_config() {
    log_step "Phase 4: Interactive config wizard"

    local detected_tz
    detected_tz=$(resolve_local_timezone)

    local existing_chat_id
    existing_chat_id=$(python3 - <<'PY' "$CONFIG_FILE" 2>/dev/null || true
import json,sys
p=sys.argv[1]
try:
    data=json.load(open(p))
    print(data.get("plugins",{}).get("entries",{}).get("lesson-recall",{}).get("config",{}).get("telegramChatId",""))
except Exception:
    print("")
PY
)

    local existing_db_path
    existing_db_path=$(python3 - <<'PY' "$CONFIG_FILE" 2>/dev/null || true
import json,sys
p=sys.argv[1]
try:
    data=json.load(open(p))
    print(data.get("plugins",{}).get("entries",{}).get("lesson-recall",{}).get("config",{}).get("dbPath",""))
except Exception:
    print("")
PY
)

    USER_TZ="$(prompt_input "Timezone" "${detected_tz:-UTC}")"
    TELEGRAM_CHAT_ID="$(prompt_input "Telegram chat ID (optional)" "$existing_chat_id")"
    LESSON_DB_PATH="$(prompt_input "Lesson DB path" "${existing_db_path:-~/.openclaw/pipeline/data/goosestack.db}")"

    log_info "Captured timezone: $USER_TZ"
    if [[ -n "$TELEGRAM_CHAT_ID" ]]; then
        log_info "Captured Telegram chat ID"
    else
        log_info "Telegram chat ID left empty"
    fi
    log_info "Captured lesson DB path: $LESSON_DB_PATH"

    add_updated "Interactive config collected"
}

# Phase 5: Update OpenClaw globally via npm.
phase_5_update_openclaw() {
    log_step "Phase 5: Update OpenClaw"

    if ! command -v npm >/dev/null 2>&1; then
        log_warning "npm not found, skipping OpenClaw update"
        add_skipped "OpenClaw update (npm missing)"
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        npm update -g openclaw
        log_success "OpenClaw updated"
    else
        log_info "[DRY RUN] Would: npm update -g openclaw"
    fi

    add_updated "OpenClaw refreshed"
}

# Phase 6: Refresh GooseStack scripts into ~/.openclaw/goosestack.
phase_6_refresh_scripts() {
    log_step "Phase 6: Refresh GooseStack scripts"

    local persist_dir="$GOOSE_HOME/goosestack"

    if [[ "$DRY_RUN" != "true" ]]; then
        rm -rf "$persist_dir"
        cp -R "$INSTALL_DIR" "$persist_dir"
        chmod -R 755 "$persist_dir/src"
        log_success "Refreshed scripts in $persist_dir"
    else
        log_info "[DRY RUN] Would: rm -rf $persist_dir"
        log_info "[DRY RUN] Would: copy $INSTALL_DIR -> $persist_dir"
        log_info "[DRY RUN] Would: chmod -R 755 $persist_dir/src"
    fi

    add_updated "GooseStack scripts refreshed"
}

# Phase 7: Refresh CLI wrapper based on architecture/Homebrew path.
phase_7_cli_refresh() {
    log_step "Phase 7: CLI refresh"

    local arch
    arch=$(uname -m)

    local cli_dest
    if [[ "$arch" == "arm64" ]]; then
        cli_dest="/opt/homebrew/bin/goosestack"
    else
        cli_dest="/usr/local/bin/goosestack"
    fi

    local cli_src="$INSTALL_SRC_DIR/templates/goosestack-cli.sh"
    if [[ ! -f "$cli_src" ]]; then
        log_warning "CLI template not found: $cli_src"
        add_skipped "CLI refresh (template missing)"
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        if cp "$cli_src" "$cli_dest" 2>/dev/null; then
            if chmod +x "$cli_dest" 2>/dev/null || sudo chmod +x "$cli_dest"; then
                log_success "CLI refreshed at $cli_dest"
                add_updated "CLI refreshed"
            else
                log_warning "Failed to set executable bit on $cli_dest; skipping"
                add_skipped "CLI refresh (chmod failed)"
            fi
        else
            log_warning "Copy to $cli_dest failed without sudo; retrying with sudo"
            if sudo cp "$cli_src" "$cli_dest" && (chmod +x "$cli_dest" 2>/dev/null || sudo chmod +x "$cli_dest"); then
                log_success "CLI refreshed at $cli_dest"
                add_updated "CLI refreshed"
            else
                log_warning "No permission to write $cli_dest; skipping"
                add_skipped "CLI refresh (permission denied)"
            fi
        fi
    else
        log_info "[DRY RUN] Would: cp $cli_src $cli_dest"
        log_info "[DRY RUN] Would: chmod +x $cli_dest"
        add_updated "CLI refresh planned"
    fi
}

write_default_learning_script() {
    local destination="$1"
    local script_name="$2"

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > "$destination" <<EOF_JS
#!/usr/bin/env node
// Auto-generated by GooseStack full upgrade.
console.log("${script_name} executed", new Date().toISOString());
EOF_JS
        chmod +x "$destination"
    else
        log_info "[DRY RUN] Would: write fallback script $destination"
        log_info "[DRY RUN] Would: chmod +x $destination"
    fi
}

# Phase 8: Deploy learning pipeline scripts and schema.
phase_8_deploy_learning_pipeline() {
    log_step "Phase 8: Deploy learning pipeline"

    local pipeline_dir="$GOOSE_HOME/pipeline"
    local data_dir="$pipeline_dir/data"
    local pipeline_src="$INSTALL_SRC_DIR/pipeline"

    if [[ ! -d "$pipeline_src" ]]; then
        log_warning "Pipeline source directory missing (expected: $pipeline_src); skipping phase"
        add_skipped "Learning pipeline deploy (source missing)"
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$pipeline_dir" "$data_dir"
    else
        log_info "[DRY RUN] Would: mkdir -p $pipeline_dir $data_dir"
    fi

    local files=("learn-daily.js" "learn-scoring.js" "learn-extract-all.js" "package.json")
    local f
    local missing_required=false
    for f in "${files[@]}"; do
        local src="$pipeline_src/$f"
        local dst="$pipeline_dir/$f"

        if [[ -f "$src" ]]; then
            if [[ "$DRY_RUN" != "true" ]]; then
                cp "$src" "$dst"
                if [[ "$f" == *.js ]]; then
                    chmod +x "$dst"
                fi
            else
                log_info "[DRY RUN] Would: copy $src -> $dst"
                if [[ "$f" == *.js ]]; then
                    log_info "[DRY RUN] Would: chmod +x $dst"
                fi
            fi
        else
            if [[ "$f" == *.js ]]; then
                log_warning "Missing $src, creating fallback $dst"
                write_default_learning_script "$dst" "$f"
            else
                log_warning "Missing required pipeline file (expected: $src); skipping phase"
                add_skipped "Learning pipeline file missing: $f"
                missing_required=true
            fi
        fi
    done

    if [[ "$missing_required" == "true" ]]; then
        return
    fi

    local seed_files=("seed-schema.sql" "seed-lessons.sql")
    for f in "${seed_files[@]}"; do
        local seed_src="$INSTALL_SRC_DIR/templates/$f"
        local seed_dst="$data_dir/$f"
        if [[ ! -f "$seed_src" ]]; then
            log_warning "Missing seed template: $seed_src"
            add_skipped "Seed copy ($f missing)"
            continue
        fi

        if [[ "$DRY_RUN" != "true" ]]; then
            cp "$seed_src" "$seed_dst"
        else
            log_info "[DRY RUN] Would: copy $seed_src -> $seed_dst"
        fi
    done

    local seed_schema_path="$data_dir/seed-schema.sql"
    local seed_lessons_path="$data_dir/seed-lessons.sql"

    if [[ "$DRY_RUN" != "true" ]]; then
        (
            cd "$pipeline_dir"
            npm install --production 2>&1 || {
                log_warning 'Prebuilt binary failed, rebuilding from source...'
                npm rebuild better-sqlite3 --build-from-source
            }
        )
        if [[ -f "$seed_schema_path" && -f "$seed_lessons_path" ]]; then
            sqlite3 "$data_dir/goosestack.db" < "$seed_schema_path"
            sqlite3 "$data_dir/goosestack.db" < "$seed_lessons_path"
        else
            log_warning "Skipping DB initialization because seed SQL files are missing"
            add_skipped "Pipeline DB initialization (seed files missing)"
        fi
    else
        log_info "[DRY RUN] Would: cd $pipeline_dir && npm install --production"
        log_info "[DRY RUN] Would: sqlite3 $data_dir/goosestack.db < $seed_schema_path"
        log_info "[DRY RUN] Would: sqlite3 $data_dir/goosestack.db < $seed_lessons_path"
    fi

    add_updated "Learning pipeline deployed"
}

# Phase 9: Deploy lesson-recall plugin under ~/.openclaw/extensions/lesson-recall.
phase_9_deploy_plugin() {
    log_step "Phase 9: Deploy lesson-recall plugin"

    local plugin_dir="$GOOSE_HOME/extensions/lesson-recall"
    local plugin_src="$INSTALL_SRC_DIR/extensions/lesson-recall"

    if [[ ! -d "$plugin_src" ]]; then
        log_warning "Plugin source directory missing (expected: $plugin_src); skipping phase"
        add_skipped "lesson-recall plugin deploy (source missing)"
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$plugin_dir"
    else
        log_info "[DRY RUN] Would: mkdir -p $plugin_dir"
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        if ! compgen -G "$plugin_src/*" >/dev/null; then
            log_warning "Plugin source has no files (expected content under: $plugin_src); skipping phase"
            add_skipped "lesson-recall plugin deploy (source empty)"
            return
        fi

        cp -R "$plugin_src"/* "$plugin_dir/"
        chmod -R 755 "$plugin_dir"
        if ! (cd "$plugin_dir" && npm install --production 2>&1); then
            log_warning 'lesson-recall npm install failed; skipping plugin config'
            add_skipped 'lesson-recall plugin (npm install failed)'
            return
        fi
        LESSON_RECALL_DEPLOY_OK=true
    else
        log_info "[DRY RUN] Would: copy $plugin_src/* -> $plugin_dir/"
        log_info "[DRY RUN] Would: chmod -R 755 $plugin_dir"
        log_info "[DRY RUN] Would: cd $plugin_dir && npm install --production"
        LESSON_RECALL_DEPLOY_OK=true
    fi

    add_updated "lesson-recall plugin deployed"
}

# Phase 10: Deploy dashboard and install dependencies.
phase_10_deploy_dashboard() {
    log_step "Phase 10: Deploy dashboard"

    local dashboard_dir="$GOOSE_HOME/dashboard"
    local dashboard_src="$INSTALL_SRC_DIR/dashboard"
    local launch_dir="$HOME/Library/LaunchAgents"
    local dashboard_tmpl="$INSTALL_SRC_DIR/templates/ai.openclaw.dashboard.plist.tmpl"
    local dashboard_out="$launch_dir/ai.openclaw.dashboard.plist"
    local node_path
    node_path=$(command -v node)
    local npm_root
    npm_root=$(npm root -g)
    local openclaw_entry=""

    if command -v openclaw >/dev/null 2>&1; then
        openclaw_entry=$(resolve_openclaw_entry)
    fi

    if [[ ! -d "$dashboard_src" ]]; then
        log_warning "Dashboard source directory missing (expected: $dashboard_src); skipping phase"
        add_skipped "Dashboard deploy (source missing)"
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        if ! compgen -G "$dashboard_src/*" >/dev/null; then
            log_warning "Dashboard source has no files (expected content under: $dashboard_src); skipping phase"
            add_skipped "Dashboard deploy (source empty)"
            return
        fi

        mkdir -p "$dashboard_dir" "$launch_dir"
        cp -R "$dashboard_src"/* "$dashboard_dir/"
        chmod -R 755 "$dashboard_dir"
        (
            cd "$dashboard_dir"
            npm install --production 2>&1 || {
                log_warning 'Prebuilt binary failed, rebuilding from source...'
                npm rebuild better-sqlite3 --build-from-source
            }
        )

        if [[ -f "$dashboard_tmpl" ]]; then
            render_plist_template "$dashboard_tmpl" "$dashboard_out" "$GOOSE_HOME" "$node_path" "$npm_root" "$openclaw_entry"
            if plutil -lint "$dashboard_out" >/dev/null 2>&1; then
                log_success "Validated $(basename "$dashboard_out")"
            else
                log_error "Invalid plist generated: $dashboard_out"
                exit 1
            fi
        else
            log_warning "Dashboard plist template missing: $dashboard_tmpl"
            add_skipped "Dashboard LaunchAgent (template missing)"
        fi
    else
        log_info "[DRY RUN] Would: mkdir -p $dashboard_dir $launch_dir"
        log_info "[DRY RUN] Would: copy $dashboard_src/* -> $dashboard_dir/"
        log_info "[DRY RUN] Would: chmod -R 755 $dashboard_dir"
        log_info "[DRY RUN] Would: cd $dashboard_dir && npm install --production"
        if [[ -f "$dashboard_tmpl" ]]; then
            log_info "[DRY RUN] Would: render $dashboard_tmpl -> $dashboard_out"
            log_info "[DRY RUN] Would: plutil -lint $dashboard_out"
        else
            log_warning "Dashboard plist template missing: $dashboard_tmpl"
            add_skipped "Dashboard LaunchAgent (template missing)"
        fi
    fi

    add_updated "Dashboard deployed"
}

# Phase 11: Merge workspace (append-only for selected files + overwrite templates).
phase_11_workspace_merge() {
    log_step "Phase 11: Workspace merge"

    local helper="$INSTALL_SRC_DIR/upgrade-workspace.sh"
    if [[ ! -f "$helper" ]]; then
        helper="$SCRIPT_DIR/src/upgrade-workspace.sh"
    fi

    if [[ ! -f "$helper" ]]; then
        log_warning "Workspace helper not found, skipping merge"
        add_skipped "Workspace merge (helper missing)"
        return
    fi

    # shellcheck source=/dev/null
    source "$helper"

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$WORKSPACE_DIR"
    else
        log_info "[DRY RUN] Would: mkdir -p $WORKSPACE_DIR"
    fi

    local soul_template="$INSTALL_SRC_DIR/templates/SOUL.md"
    if [[ ! -f "$soul_template" ]]; then
        soul_template="$INSTALL_SRC_DIR/templates/SOUL-partner.md"
    fi

    local append_sources=(
        "$soul_template"
        "$INSTALL_SRC_DIR/templates/MEMORY.md"
        "$INSTALL_SRC_DIR/templates/USER.md.tmpl"
        "$INSTALL_SRC_DIR/templates/IDENTITY.md"
    )
    local append_targets=(
        "$WORKSPACE_DIR/SOUL.md"
        "$WORKSPACE_DIR/MEMORY.md"
        "$WORKSPACE_DIR/USER.md"
        "$WORKSPACE_DIR/IDENTITY.md"
    )

    local idx
    for ((idx=0; idx<${#append_sources[@]}; idx++)); do
        local src="${append_sources[$idx]}"
        local dst="${append_targets[$idx]}"

        if [[ ! -f "$src" ]]; then
            log_warning "Missing template for append merge: $src"
            continue
        fi

        if [[ "$DRY_RUN" != "true" ]]; then
            local rc=0
            append_missing_sections "$src" "$dst" "GooseStack full upgrade" || rc=$?
            if [[ $rc -eq 2 ]]; then
                log_success "Appended missing sections to $(basename "$dst")"
            else
                log_info "No new sections needed for $(basename "$dst")"
            fi
        else
            log_info "[DRY RUN] Would: append missing ## sections from $src to $dst"
        fi
    done

    local overwrite_files=("AGENTS.md" "HEARTBEAT.md" "TOOLS.md")
    local name
    for name in "${overwrite_files[@]}"; do
        local from="$INSTALL_SRC_DIR/templates/$name"
        local to="$WORKSPACE_DIR/$name"
        if [[ ! -f "$from" ]]; then
            log_warning "Template missing for overwrite: $from"
            continue
        fi

        if [[ "$DRY_RUN" != "true" ]]; then
            cp "$from" "$to"
            log_success "Overwrote $name from template"
        else
            log_info "[DRY RUN] Would: overwrite $to from $from"
        fi
    done

    add_updated "Workspace merge completed"
}

render_plist_template() {
    local tmpl="$1"
    local out="$2"
    local goose_home="$3"
    local node_path="$4"
    local npm_root="$5"
    local openclaw_entry="$6"

    local path_value
    path_value="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

    sed \
        -e "s|__GOOSE_HOME__|$goose_home|g" \
        -e "s|__GOOSE_NODE_PATH__|$node_path|g" \
        -e "s|__GOOSE_NPM_ROOT__|$npm_root|g" \
        -e "s|__GOOSE_OPENCLAW_ENTRY__|$openclaw_entry|g" \
        -e "s|__GOOSE_USER_HOME__|$HOME|g" \
        -e "s|__GOOSE_PATH__|$path_value|g" \
        "$tmpl" > "$out"
}

# Phase 12: Rebuild LaunchAgent plists from .tmpl files and validate.
phase_12_rebuild_launchagents() {
    log_step "Phase 12: Rebuild LaunchAgents"

    local launch_dir="$HOME/Library/LaunchAgents"
    local node_path
    node_path=$(command -v node)
    local npm_root
    npm_root=$(npm root -g)
    local openclaw_entry=""

    if command -v openclaw >/dev/null 2>&1; then
        openclaw_entry=$(resolve_openclaw_entry)
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$launch_dir"
    else
        log_info "[DRY RUN] Would: mkdir -p $launch_dir"
    fi

    local templates=(
        "ai.openclaw.gateway.plist.tmpl"
        "ai.openclaw.watchdog.plist.tmpl"
        "ai.openclaw.learn-daily.plist.tmpl"
        "ai.openclaw.dashboard.plist.tmpl"
    )

    local t
    for t in "${templates[@]}"; do
        local tmpl_path="$INSTALL_SRC_DIR/templates/$t"
        local out_path="$launch_dir/${t%.tmpl}"

        if [[ ! -f "$tmpl_path" ]]; then
            log_warning "Missing plist template: $tmpl_path"
            add_skipped "LaunchAgent template missing: $t"
            continue
        fi

        if [[ "$DRY_RUN" != "true" ]]; then
            render_plist_template "$tmpl_path" "$out_path" "$GOOSE_HOME" "$node_path" "$npm_root" "$openclaw_entry"
            if plutil -lint "$out_path" >/dev/null 2>&1; then
                log_success "Validated $(basename "$out_path")"
            else
                log_error "Invalid plist generated: $out_path"
                exit 1
            fi
        else
            log_info "[DRY RUN] Would: render $tmpl_path -> $out_path"
            log_info "[DRY RUN] Would: plutil -lint $out_path"
        fi
    done

    # Load non-gateway LaunchAgents (gateway is managed by openclaw gateway start)
    if [[ "$DRY_RUN" != "true" ]]; then
        for plist_file in "$launch_dir"/ai.openclaw.*.plist; do
            [[ -f "$plist_file" ]] || continue
            local plist_name
            plist_name=$(basename "$plist_file" .plist)
            # Skip gateway — managed by openclaw itself
            [[ "$plist_name" == "ai.openclaw.gateway" ]] && continue
            # Unload first (idempotent)
            launchctl bootout "gui/$(id -u)/$plist_name" 2>/dev/null || true
            if launchctl bootstrap "gui/$(id -u)" "$plist_file" 2>/dev/null || launchctl load "$plist_file" 2>/dev/null; then
                log_success "Loaded LaunchAgent: $plist_name"
            else
                log_warning "Failed to load LaunchAgent: $plist_name"
            fi
        done
    fi

    add_updated "LaunchAgents rebuilt"
}

cron_job_exists() {
    local key="$1"
    local list_output="$2"
    echo "$list_output" | grep -Fqi "$key"
}

add_daily_memory_curator_cron() {
    local existing_list="$1"
    local name="daily-memory-curator"

    if cron_job_exists "$name" "$existing_list"; then
        log_info "Cron already exists, skipping: $name"
        add_skipped "Cron: $name (already exists)"
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        if openclaw cron add \
            --name "$name" \
            --cron "30 3 * * *" \
            --tz "$USER_TZ" \
            --session isolated \
            --message "Read HEARTBEAT.md if it exists (workspace context). Follow it strictly." \
            --model haiku \
            --thinking low \
            --timeout-seconds 120 \
            --no-deliver 2>/dev/null; then
            log_success "Cron added: $name"
        else
            log_warning "Failed to add cron job: $name"
            add_skipped "Cron: $name (add failed)"
            return
        fi
    else
        log_info "[DRY RUN] Would: openclaw cron add --name '$name' --cron '30 3 * * *' --tz '$USER_TZ' --session isolated --message 'Read HEARTBEAT.md if it exists (workspace context). Follow it strictly.' --model haiku --thinking low --timeout-seconds 120 --no-deliver"
    fi

    add_updated "Cron: $name"
}

add_lesson_review_cron() {
    local existing_list="$1"
    local name="lesson-review"

    if cron_job_exists "$name" "$existing_list"; then
        log_info "Cron already exists, skipping: $name"
        add_skipped "Cron: $name (already exists)"
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        if openclaw cron add \
            --name "$name" \
            --cron "30 4 * * *" \
            --tz "$USER_TZ" \
            --session main \
            --system-event "LESSON_REVIEW_TRIGGER: Check for awaiting_approval lessons and send to User for review." \
            2>/dev/null; then
            log_success "Cron added: $name"
        else
            log_warning "Failed to add cron job: $name"
            add_skipped "Cron: $name (add failed)"
            return
        fi
    else
        log_info "[DRY RUN] Would: openclaw cron add --name '$name' --cron '30 4 * * *' --tz '$USER_TZ' --session main --system-event 'LESSON_REVIEW_TRIGGER: Check for awaiting_approval lessons and send to User for review.'"
    fi

    add_updated "Cron: $name"
}

install_cron_jobs_post_gateway() {
    log_info "Installing cron jobs after gateway restart"

    local existing_list=""
    existing_list=$(openclaw cron list 2>/dev/null || true)

    add_daily_memory_curator_cron "$existing_list"
    add_lesson_review_cron "$existing_list"
}

# Phase 13: Install cron jobs for daily memory curation and lesson review.
phase_13_install_cron() {
    log_step "Phase 13: Cron jobs deferred"
    log_info "Cron jobs will be installed after gateway restart (Phase 16)"
}

# Phase 14: Patch openclaw.json with lesson-recall plugin config (safe JSON merge via python3).
phase_14_patch_config() {
    log_step "Phase 14: Patch openclaw.json for lesson-recall"

    if [[ "$LESSON_RECALL_DEPLOY_OK" != "true" ]]; then
        log_warning "lesson-recall deploy not ready; skipping config patch"
        add_skipped "openclaw.json patch for lesson-recall (plugin deploy failed)"
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        python3 - <<'PY' "$CONFIG_FILE" "$LESSON_DB_PATH"
import json
import sys

config_path, db_path = sys.argv[1:3]
with open(config_path, "r", encoding="utf-8") as f:
    data = json.load(f)

plugins = data.setdefault("plugins", {})
entries = plugins.setdefault("entries", {})
lesson = entries.setdefault("lesson-recall", {})
lesson["enabled"] = True
cfg = lesson.setdefault("config", {})
cfg["enabled"] = True
cfg["dbPath"] = db_path
cfg.setdefault("ollamaUrl", "http://localhost:11434")
cfg.setdefault("embeddingModel", "nomic-embed-text")
cfg.setdefault("topK", 5)
cfg.setdefault("minSimilarity", 0.45)
cfg.setdefault("maxChars", 2000)

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
        log_success "Patched lesson-recall plugin config"

        local plugin_dir="$GOOSE_HOME/extensions/lesson-recall"
        local better_sqlite_dir="$plugin_dir/node_modules/better-sqlite3"
        if [[ ! -d "$better_sqlite_dir" ]]; then
            log_warning "lesson-recall missing better-sqlite3; running npm install --production"
            (
                cd "$plugin_dir"
                npm install --production 2>&1
            ) || log_warning "lesson-recall npm install retry failed"
        fi

        if ! openclaw status 2>&1 | grep -q 'lesson-recall.*loaded'; then
            log_warning "lesson-recall plugin did not report loaded status after config patch"
        fi
    else
        log_info "[DRY RUN] Would: patch $CONFIG_FILE with lesson-recall plugin config"
        log_info "[DRY RUN] Would: verify $GOOSE_HOME/extensions/lesson-recall/node_modules/better-sqlite3 exists"
        log_info "[DRY RUN] Would: openclaw status | grep 'lesson-recall.*loaded'"
    fi

    add_updated "openclaw.json patched for lesson-recall"
}

# Phase 15: Optionally inject API keys.
phase_15_inject_keys() {
    log_step "Phase 15: Optional API key injection"

    if [[ "$INJECT_KEYS" != "true" ]]; then
        log_info "--inject-keys not set; skipping key injection"
        add_skipped "API key injection (not requested)"
        return
    fi

    if [[ -z "$ANTHROPIC_KEY$OPENAI_KEY$GOOGLE_KEY$GROQ_KEY$XAI_KEY$BRAVE_KEY$TELEGRAM_BOT_TOKEN" ]]; then
        log_warning "--inject-keys set but no key values were provided"
        add_skipped "API key injection (no values provided)"
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        python3 - <<'PY' "$CONFIG_FILE" "$ANTHROPIC_KEY" "$OPENAI_KEY" "$GOOGLE_KEY" "$GROQ_KEY" "$XAI_KEY" "$BRAVE_KEY" "$TELEGRAM_BOT_TOKEN"
import json
import sys

config_path, anthropic, openai, google, groq, xai, brave, telegram = sys.argv[1:9]
with open(config_path, "r", encoding="utf-8") as f:
    data = json.load(f)

auth_profiles = data.setdefault("auth", {}).setdefault("profiles", {})

if anthropic:
    p = auth_profiles.setdefault("anthropic:default", {"provider": "anthropic", "mode": "api_key"})
    p["apiKey"] = anthropic
if openai:
    p = auth_profiles.setdefault("openai:default", {"provider": "openai", "mode": "api_key"})
    p["apiKey"] = openai
if google:
    p = auth_profiles.setdefault("google:default", {"provider": "google", "mode": "api_key"})
    p["apiKey"] = google
if groq:
    p = auth_profiles.setdefault("groq:default", {"provider": "groq", "mode": "api_key"})
    p["apiKey"] = groq
if xai:
    p = auth_profiles.setdefault("xai:default", {"provider": "xai", "mode": "api_key"})
    p["apiKey"] = xai
if brave:
    data.setdefault("tools", {}).setdefault("web", {}).setdefault("search", {})["apiKey"] = brave
if telegram:
    tg = data.setdefault("channels", {}).setdefault("telegram", {})
    tg["enabled"] = True
    tg["botToken"] = telegram

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
        log_success "API keys injected into configuration"
    else
        log_info "[DRY RUN] Would: inject provided API keys into $CONFIG_FILE"
    fi

    add_updated "API keys injected"
}

# Phase 16: Restart gateway and run health checks.
phase_16_restart_and_healthcheck() {
    log_step "Phase 16: Restart gateway and healthcheck"

    if ! command -v openclaw >/dev/null 2>&1; then
        log_warning "openclaw not found; skipping restart/healthcheck"
        add_skipped "Gateway restart + healthcheck (openclaw missing)"
        add_skipped "Cron setup (openclaw missing)"
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        if openclaw gateway restart 2>/dev/null || openclaw gateway start 2>/dev/null; then
            log_success "Gateway restarted"
        else
            log_warning "Gateway restart failed"
        fi

        if [[ -f "$INSTALL_SRC_DIR/healthcheck.sh" ]]; then
            (
                export GOOSE_WORKSPACE_DIR="$WORKSPACE_DIR"
                export GOOSE_ARCH="$(uname -m)"
                # shellcheck source=/dev/null
                source "$INSTALL_SRC_DIR/healthcheck.sh"
            ) || log_warning "Healthcheck reported issues"
        else
            log_warning "healthcheck.sh not found; skipped"
        fi
    else
        log_info "[DRY RUN] Would: openclaw gateway restart"
        log_info "[DRY RUN] Would: run healthcheck script"
    fi

    install_cron_jobs_post_gateway
    add_updated "Gateway restart + healthcheck phase completed"
}

# Phase 17: Print an explicit summary of actions performed and skipped.
phase_17_summary() {
    log_step "Phase 17: Upgrade summary"

    if [[ ${#UPDATED_ITEMS[@]} -gt 0 ]]; then
        log_success "Completed/planned actions:"
        local item
        for item in "${UPDATED_ITEMS[@]}"; do
            echo "  ✅ $item"
        done
    fi

    if [[ ${#SKIPPED_ITEMS[@]} -gt 0 ]]; then
        echo
        log_warning "Skipped actions:"
        local skipped
        for skipped in "${SKIPPED_ITEMS[@]}"; do
            echo "  ⚠️  $skipped"
        done
    fi

    echo
    if [[ "$DRY_RUN" == "true" ]]; then
        log_success "Dry run complete: no changes were made"
    else
        log_success "Full upgrade complete"
    fi
}

main() {
    parse_args "$@"
    acquire_lock

    phase_1_preflight
    phase_2_backup
    phase_3_fetch_latest
    phase_4_interactive_config
    phase_5_update_openclaw
    phase_6_refresh_scripts
    phase_7_cli_refresh
    phase_8_deploy_learning_pipeline
    phase_9_deploy_plugin
    phase_10_deploy_dashboard
    phase_11_workspace_merge
    phase_12_rebuild_launchagents
    phase_13_install_cron
    phase_14_patch_config
    phase_15_inject_keys
    phase_16_restart_and_healthcheck
    phase_17_summary
}

main "$@"
