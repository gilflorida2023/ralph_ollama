#!/bin/bash
# Ralph Wiggum loop: restore done code, validate, store new code

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Environment variable storing all previously done code
RALPH_DONE_FILE="/tmp/ralph_done_code.txt"
if [ -f "$RALPH_DONE_FILE" ]; then
    RALPH_DONE_CODE=$(cat "$RALPH_DONE_FILE")
fi

# Clean start: reset done code
RALPH_CLEAN_START=false
if [[ "${1:-}" == "--clean" ]]; then
    if [[ "${2:-}" == "*" ]]; then
        MAX_ITERS="${2:-}"
    else
        MAX_ITERS=50
    fi
    # Clean start
    rm -f workspace/tasks.py "$RALPH_DONE_FILE" workspace/tasks.json workspace/progress.md
    python3 agent.py setup
    unset RALPH_DONE_CODE
    RALPH_CLEAN_START=true
else
    # Continue existing run
    if [ ! -f workspace/tasks.json ]; then
        python3 agent.py setup
    fi
fi

MAX_ITERS="${MAX_ITERS:-50}"

# Main loop
for ITER in $(seq 1 "$MAX_ITERS"); do
    echo "=== Iteration $ITER ==="

    # Get next task
    NEXT_TASK_JSON=$(python3 - <<'PY'
import json
import sys
sys.path.insert(0, '.')
from agent import next_task
print(json.dumps({"done": True}))
PY
)

    if echo "$NEXT_TASK_JSON" | grep -q '"done": true'; then
        echo "All tasks completed!"
        break
    fi

    TASK_NUM=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['num'])")
    TASK_TITLE=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
    TASK_FUNC=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('func', ''))")

    echo "Working on Task $TASK_NUM: $TASK_TITLE"

    # Restore previously done code (current state)
    if [ -n "$RALPH_DONE_CODE" ]; then
        echo "$RALPH_DONE_CODE" > workspace/tasks.py
    elif [ ! -f workspace/tasks.py ]; then
        : > workspace/tasks.py
    fi

    # Build prompt for this task
    python3 - "$TASK_NUM" "$TASK_TITLE" "$TASK_FUNC" <<'PY'
import json, sys, os
from datetime import datetime

task_num = int(sys.argv[1])
task_title = sys.argv[2]
task_func = sys.argv[3]

# Read existing prompt
with open('prompt.md', 'r') as f:
    system = f.read()

# Add task-specific prompt
prompt = f'''{system}

Task {task_num}: {task_title}

Implement the function '{task_func}' in tasks.py:

1. Read tasks.py
2. Add this function and its test
3. Run: python3 workspace/tasks.py test_$task_func

Keep all existing code.
'''

with open('/tmp/ralph_prompt.txt', 'w') as f:
    f.write(prompt)
PY

    # Get model response
    curl -s "http://localhost:11434/api/chat" \
         -d "{\"model\":\"qwen2.5:7b\", \"messages\":[{\"role\":\"user\", \"content\":\"$(cat /tmp/ralph_prompt.txt | sed 's/\\/\\\\/g; s/\"/\\\"/g')\"}]" \
         | jq -r '.message.content // ""' > /tmp/ralph_response.txt

    # Execute model response
    python3 <<'PY'
import json
import subprocess
import sys

response_file = "/tmp/ralph_response.txt"
with open(response_file, 'r') as f:
    response = f.read()

# Try to parse tool calls
if '"tool_calls"' in response:
    data = json.loads(response)
    for call in data.get('tool_calls', []):
        name = call.get('name', '')
        args = call.get('args', {})
        if name in ['read_file', 'write_file', 'run_command']:
            subprocess.run(['python3', 'agent.py', 'execute', name, json.dumps(args)])
else:
    print("No tool calls found in response")
PY

    # Validate the task
    echo "Validating..."
    python3 workspace/tasks.py test_$TASK_FUNC

    # Validation passed - update progress and store code
    python3 agent.py execute mark_task "{\"num\":$TASK_NUM,\"state\":\"done\"}"
    RALPH_DONE_CODE=$(cat workspace/tasks.py)
    echo "$RALPH_DONE_CODE" > "$RALPH_DONE_FILE"

    echo "Task $TASK_NUM completed successfully"
done

echo "Ralph loop finished"
