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
BRAVE_KEY=""
TELEGRAM_BOT_TOKEN=""

TEMP_DIR=""
INSTALL_DIR=""
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
  --inject-keys             Enable API key injection (phase 14)
  --anthropic-key <value>   Anthropic API key to inject
  --openai-key <value>      OpenAI API key to inject
  --google-key <value>      Google API key to inject
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

    local required_cmds=(node npm brew)
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
            git clone --depth 1 "$GOOSE_REPO" "$TEMP_DIR/goosestack-latest"
        else
            mkdir -p "$TEMP_DIR/goosestack-latest"
            curl -fsSL "$GOOSE_REPO/archive/main.tar.gz" | tar -xz --strip-components=1 -C "$TEMP_DIR/goosestack-latest"
        fi
        INSTALL_DIR="$TEMP_DIR/goosestack-latest"
    else
        log_info "[DRY RUN] Would: clone latest GooseStack from $GOOSE_REPO"
        INSTALL_DIR="$SCRIPT_DIR"
    fi

    if [[ ! -d "$INSTALL_DIR/src" ]]; then
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

    local cli_target
    if [[ "$arch" == "arm64" ]]; then
        cli_target="/opt/homebrew/bin/goosestack"
    else
        cli_target="/usr/local/bin/goosestack"
    fi

    local cli_src="$INSTALL_DIR/src/templates/goosestack-cli.sh"
    if [[ ! -f "$cli_src" ]]; then
        log_warning "CLI template not found: $cli_src"
        add_skipped "CLI refresh (template missing)"
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        if cp "$cli_src" "$cli_target" 2>/dev/null; then
            chmod +x "$cli_target"
            log_success "CLI refreshed at $cli_target"
            add_updated "CLI refreshed"
        else
            log_warning "No permission to write $cli_target; skipping"
            add_skipped "CLI refresh (permission denied)"
        fi
    else
        log_info "[DRY RUN] Would: cp $cli_src $cli_target"
        log_info "[DRY RUN] Would: chmod +x $cli_target"
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

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$pipeline_dir" "$data_dir"
    else
        log_info "[DRY RUN] Would: mkdir -p $pipeline_dir $data_dir"
    fi

    local files=("learn-daily.js" "learn-scoring.js" "learn-extract-all.js")
    local f
    for f in "${files[@]}"; do
        local src="$INSTALL_DIR/src/pipeline/$f"
        local dst="$pipeline_dir/$f"

        if [[ -f "$src" ]]; then
            if [[ "$DRY_RUN" != "true" ]]; then
                cp "$src" "$dst"
                chmod +x "$dst"
            else
                log_info "[DRY RUN] Would: copy $src -> $dst"
                log_info "[DRY RUN] Would: chmod +x $dst"
            fi
        else
            log_warning "Missing $src, creating fallback $dst"
            write_default_learning_script "$dst" "$f"
        fi
    done

    local schema_src="$INSTALL_DIR/src/templates/seed-schema.sql"
    local schema_dst="$data_dir/seed-schema.sql"
    if [[ -f "$schema_src" ]]; then
        if [[ "$DRY_RUN" != "true" ]]; then
            cp "$schema_src" "$schema_dst"
        else
            log_info "[DRY RUN] Would: copy $schema_src -> $schema_dst"
        fi
    else
        add_skipped "Seed schema copy (template missing)"
    fi

    add_updated "Learning pipeline deployed"
}

# Phase 9: Deploy lesson-recall plugin under ~/.openclaw/extensions/lesson-recall.
phase_9_deploy_plugin() {
    log_step "Phase 9: Deploy lesson-recall plugin"

    local plugin_dir="$GOOSE_HOME/extensions/lesson-recall"
    local plugin_src="$INSTALL_DIR/src/extensions/lesson-recall"

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$plugin_dir"
    else
        log_info "[DRY RUN] Would: mkdir -p $plugin_dir"
    fi

    if [[ -d "$plugin_src" ]]; then
        if [[ "$DRY_RUN" != "true" ]]; then
            cp -R "$plugin_src"/* "$plugin_dir/"
            chmod -R 755 "$plugin_dir"
        else
            log_info "[DRY RUN] Would: copy $plugin_src/* -> $plugin_dir/"
            log_info "[DRY RUN] Would: chmod -R 755 $plugin_dir"
        fi
    else
        if [[ "$DRY_RUN" != "true" ]]; then
            cat > "$plugin_dir/README.md" <<'EOF_PLUGIN'
# lesson-recall
Managed by GooseStack full upgrade.
EOF_PLUGIN
            cat > "$plugin_dir/index.js" <<'EOF_PLUGIN_JS'
#!/usr/bin/env node
console.log("lesson-recall plugin placeholder loaded");
EOF_PLUGIN_JS
            chmod +x "$plugin_dir/index.js"
        else
            log_info "[DRY RUN] Would: create placeholder lesson-recall plugin files"
        fi
    fi

    add_updated "lesson-recall plugin deployed"
}

# Phase 10: Merge workspace (append-only for selected files + overwrite templates).
phase_10_workspace_merge() {
    log_step "Phase 10: Workspace merge"

    local helper="$INSTALL_DIR/src/upgrade-workspace.sh"
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

    local soul_template="$INSTALL_DIR/src/templates/SOUL.md"
    if [[ ! -f "$soul_template" ]]; then
        soul_template="$INSTALL_DIR/src/templates/SOUL-partner.md"
    fi

    local append_sources=(
        "$soul_template"
        "$INSTALL_DIR/src/templates/MEMORY.md"
        "$INSTALL_DIR/src/templates/USER.md.tmpl"
        "$INSTALL_DIR/src/templates/IDENTITY.md"
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
        local from="$INSTALL_DIR/src/templates/$name"
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

# Phase 11: Rebuild LaunchAgent plists from .tmpl files and validate.
phase_11_rebuild_launchagents() {
    log_step "Phase 11: Rebuild LaunchAgents"

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
    )

    local t
    for t in "${templates[@]}"; do
        local tmpl_path="$INSTALL_DIR/src/templates/$t"
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

    add_updated "LaunchAgents rebuilt"
}

cron_job_exists() {
    local key="$1"
    local list_output="$2"
    echo "$list_output" | grep -Fqi "$key"
}

add_cron_job() {
    local schedule="$1"
    local command="$2"
    local description="$3"
    local existing_list="$4"

    if cron_job_exists "$description" "$existing_list"; then
        log_info "Cron already exists, skipping: $description"
        add_skipped "Cron: $description (already exists)"
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        if openclaw cron add --schedule "$schedule" --timezone "$USER_TZ" --command "$command" --description "$description" 2>/dev/null; then
            log_success "Cron added: $description"
        elif openclaw cron add --schedule "$schedule" --command "TZ=$USER_TZ $command" --description "$description" 2>/dev/null; then
            log_success "Cron added (timezone in command): $description"
        else
            log_warning "Failed to add cron job: $description"
            add_skipped "Cron: $description (add failed)"
            return
        fi
    else
        log_info "[DRY RUN] Would: openclaw cron add --schedule '$schedule' --timezone '$USER_TZ' --command '$command' --description '$description'"
    fi

    add_updated "Cron: $description"
}

# Phase 12: Install cron jobs for daily memory curation and lesson review.
phase_12_install_cron() {
    log_step "Phase 12: Install cron jobs"

    if ! command -v openclaw >/dev/null 2>&1; then
        log_warning "openclaw not found; skipping cron setup"
        add_skipped "Cron setup (openclaw missing)"
        return
    fi

    local existing_list=""
    existing_list=$(openclaw cron list 2>/dev/null || true)

    add_cron_job "30 3 * * *" "node $GOOSE_HOME/pipeline/learn-daily.js" "daily-memory-curator" "$existing_list"
    add_cron_job "30 4 * * *" "node $GOOSE_HOME/pipeline/learn-scoring.js" "lesson-review" "$existing_list"
}

# Phase 13: Patch openclaw.json with lesson-recall plugin config (safe JSON merge via python3).
phase_13_patch_config() {
    log_step "Phase 13: Patch openclaw.json for lesson-recall"

    if [[ "$DRY_RUN" != "true" ]]; then
        python3 - <<'PY' "$CONFIG_FILE" "$LESSON_DB_PATH" "$TELEGRAM_CHAT_ID" "$USER_TZ"
import json
import sys

config_path, db_path, chat_id, user_tz = sys.argv[1:5]
with open(config_path, "r", encoding="utf-8") as f:
    data = json.load(f)

plugins = data.setdefault("plugins", {})
entries = plugins.setdefault("entries", {})
lesson = entries.setdefault("lesson-recall", {})
lesson["enabled"] = True
cfg = lesson.setdefault("config", {})
cfg["enabled"] = True
cfg["dbPath"] = db_path
cfg["timezone"] = user_tz
cfg.setdefault("ollamaUrl", "http://localhost:11434")
cfg.setdefault("embeddingModel", "nomic-embed-text")
cfg.setdefault("topK", 5)
cfg.setdefault("minSimilarity", 0.45)
cfg.setdefault("maxChars", 2000)
if chat_id:
    cfg["telegramChatId"] = chat_id

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
        log_success "Patched lesson-recall plugin config"
    else
        log_info "[DRY RUN] Would: patch $CONFIG_FILE with lesson-recall plugin config"
    fi

    add_updated "openclaw.json patched for lesson-recall"
}

# Phase 14: Optionally inject API keys.
phase_14_inject_keys() {
    log_step "Phase 14: Optional API key injection"

    if [[ "$INJECT_KEYS" != "true" ]]; then
        log_info "--inject-keys not set; skipping key injection"
        add_skipped "API key injection (not requested)"
        return
    fi

    if [[ -z "$ANTHROPIC_KEY$OPENAI_KEY$GOOGLE_KEY$BRAVE_KEY$TELEGRAM_BOT_TOKEN" ]]; then
        log_warning "--inject-keys set but no key values were provided"
        add_skipped "API key injection (no values provided)"
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        python3 - <<'PY' "$CONFIG_FILE" "$ANTHROPIC_KEY" "$OPENAI_KEY" "$GOOGLE_KEY" "$BRAVE_KEY" "$TELEGRAM_BOT_TOKEN"
import json
import sys

config_path, anthropic, openai, google, brave, telegram = sys.argv[1:7]
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

# Phase 15: Restart gateway and run health checks.
phase_15_restart_and_healthcheck() {
    log_step "Phase 15: Restart gateway and healthcheck"

    if ! command -v openclaw >/dev/null 2>&1; then
        log_warning "openclaw not found; skipping restart/healthcheck"
        add_skipped "Gateway restart + healthcheck (openclaw missing)"
        return
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        if openclaw gateway restart 2>/dev/null || openclaw gateway start 2>/dev/null; then
            log_success "Gateway restarted"
        else
            log_warning "Gateway restart failed"
        fi

        if [[ -f "$INSTALL_DIR/src/healthcheck.sh" ]]; then
            (
                export GOOSE_WORKSPACE_DIR="$WORKSPACE_DIR"
                export GOOSE_ARCH="$(uname -m)"
                # shellcheck source=/dev/null
                source "$INSTALL_DIR/src/healthcheck.sh"
            ) || log_warning "Healthcheck reported issues"
        else
            log_warning "healthcheck.sh not found; skipped"
        fi
    else
        log_info "[DRY RUN] Would: openclaw gateway restart"
        log_info "[DRY RUN] Would: run healthcheck script"
    fi

    add_updated "Gateway restart + healthcheck phase completed"
}

# Phase 16: Print an explicit summary of actions performed and skipped.
phase_16_summary() {
    log_step "Phase 16: Upgrade summary"

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
    phase_10_workspace_merge
    phase_11_rebuild_launchagents
    phase_12_install_cron
    phase_13_patch_config
    phase_14_inject_keys
    phase_15_restart_and_healthcheck
    phase_16_summary
}

main "$@"
