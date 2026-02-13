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
        echo "Updating GooseStack..."
        cd /tmp && curl -fsSL https://goosestack.com/install.sh -o goosestack-update.sh && sh goosestack-update.sh
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
        echo "  help        Show this help"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'goosestack help' for usage"
        exit 1
        ;;
esac