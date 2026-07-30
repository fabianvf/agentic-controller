#!/bin/sh
# Minimal harness stub for testing the controller pipeline.
# The real harness will manage git lifecycle and launch the agent runtime.
# See: https://github.com/konveyor/enhancements/pull/296

set -e

echo "=== konveyor agent-base ==="
echo "Workspace: $(pwd)"
echo "Skills:    $(ls /opt/skills/ 2>/dev/null || echo 'none')"
echo "Params:    $(env | grep KONVEYOR_PARAM_ | sort || echo 'none')"
echo "Models:    $(env | grep KONVEYOR_MODEL_ | cut -d= -f1 | sort || echo 'none')"
echo ""

if [ -n "$KONVEYOR_INSTRUCTIONS" ]; then
    echo "Instructions: $KONVEYOR_INSTRUCTIONS"
fi

if [ -n "$KONVEYOR_PROMPT" ]; then
    echo "Prompt: $KONVEYOR_PROMPT"
fi

echo ""
echo "Agent run completed successfully."

# Run-to-completion mode, opt-in via KONVEYOR_STUB_MODE=exit.
#
# The default below keeps the container alive, which is what a single AgentRun
# wants (the pod stays inspectable via kubectl exec). But it means the AgentRun
# never reaches Succeeded -- so an AgentPlaybookRun, which waits for each stage
# to complete before starting the next, hangs on stage 1 forever.
#
# Defaults to the previous behaviour so existing e2e runs are unaffected.
if [ "${KONVEYOR_STUB_MODE:-serve}" = "exit" ]; then
    echo "Stub mode 'exit': exiting 0 so the AgentRun completes."
    exit 0
fi

# Keep the container running. Agent Sandbox expects a long-running
# process. The real harness will run goose serve here.
echo "Waiting for shutdown signal..."
exec sleep infinity
