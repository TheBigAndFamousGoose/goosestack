#!/bin/bash
# GooseStack CLI — thin wrapper around OpenClaw

case "${1:-}" in
    terminal|chat|tui|"")
        # Default: open the TUI chat
        exec openclaw
        ;;
    status)
        exec openclaw status
        ;;
    logs)
        exec openclaw logs --follow
        ;;
    start)
        exec openclaw gateway start
        ;;
    stop)
        exec openclaw gateway stop
        ;;
    restart)
        exec openclaw gateway restart
        ;;
    doctor)
        exec openclaw doctor "$@"
        ;;
    update)
        shift
        if [[ -f "$HOME/.openclaw/goosestack/src/update.sh" ]]; then
            exec bash "$HOME/.openclaw/goosestack/src/update.sh" "$@"
        else
            # Bootstrap: download and run
            cd /tmp && curl -fsSL https://raw.githubusercontent.com/TheBigAndFamousGoose/goosestack/main/src/update.sh -o goosestack-update.sh && bash goosestack-update.sh "$@"
        fi
        ;;
    export)
        shift
        exec bash "$(dirname "$(readlink -f "$0")")/../src/migrate.sh" export "$@" 2>/dev/null || \
        bash "$HOME/.openclaw/goosestack/src/migrate.sh" export "$@"
        ;;
    import)
        shift
        exec bash "$(dirname "$(readlink -f "$0")")/../src/migrate.sh" import "$@" 2>/dev/null || \
        bash "$HOME/.openclaw/goosestack/src/migrate.sh" import "$@"
        ;;
    uninstall)
        shift
        # Try local uninstall script first, then download
        if [[ -f "$HOME/.openclaw/goosestack/src/uninstall.sh" ]]; then
            exec bash "$HOME/.openclaw/goosestack/src/uninstall.sh" "$@"
        elif [[ -f "/tmp/goosestack/src/uninstall.sh" ]]; then
            exec bash "/tmp/goosestack/src/uninstall.sh" "$@"
        else
            echo "Downloading uninstall script..."
            cd /tmp && git clone --depth 1 https://github.com/TheBigAndFamousGoose/goosestack.git goosestack-tmp 2>/dev/null
            exec bash /tmp/goosestack-tmp/src/uninstall.sh "$@"
        fi
        ;;
    help|--help|-h)
        echo "GooseStack — Your AI Agent Environment"
        echo ""
        echo "Usage: goosestack [command]"
        echo ""
        echo "Commands:"
        echo "  terminal    Open the chat TUI (default)"
        echo "  status      Show agent and gateway status"
        echo "  logs        Follow gateway logs"
        echo "  start       Start the gateway"
        echo "  stop        Stop the gateway"
        echo "  restart     Restart the gateway"
        echo "  doctor      Run diagnostics"
        echo "  update      Update GooseStack"
        echo "  export      Export configuration and workspace"
        echo "  import      Import configuration and workspace"
        echo "  uninstall   Remove GooseStack"
        echo "  help        Show this help"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'goosestack help' for usage"
        exit 1
        ;;
esac