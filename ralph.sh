#!/bin/bash
# ralph.sh - Simple Ralph Wiggum loop for Ollama with exclusive get_next_task tool

set -euo pipefail

MAX_ITERATIONS=50
VERBOSE=false

# Parse arguments. Accepts either order: `ralph.sh 3 -v` or `ralph.sh -v 3`.
while [ "$#" -gt 0 ]; do
    case "$1" in
        -v|--verbose) VERBOSE=true ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                MAX_ITERATIONS=$1
            else
                echo "Invalid iteration count: $1 (expected a number)" >&2
                exit 1
            fi
            ;;
    esac
    shift
done

ITER=0
LOGFILE="logs/ralph_$(date +%s).log"

mkdir -p logs

# Setup workspace from spec.md
python3 agent.py setup
echo "=== Starting Ralph Wiggum Loop for Ollama ==="
echo "Press Ctrl+C to stop. Max iterations: $MAX_ITERATIONS"
if [ "$VERBOSE" = true ]; then
    echo "=== VERBOSE MODE: Tool calls will be logged in detail ==="
fi

while [ "$ITER" -lt "$MAX_ITERATIONS" ]; do
    ITER=$((ITER + 1))
    echo "=== Iteration $ITER ===" | tee -a "$LOGFILE"

    # Get next task using exclusive get_next_task tool (direct tool call, no CLI confusion)
    if [ "$VERBOSE" = true ]; then
        echo "=== DEBUG: Calling execute_get_next_task ===" | tee -a "$LOGFILE"
    fi

    # Use a QUOTED heredoc ('PY') so bash does NOT expand anything inside the
    # Python source. VERBOSE is passed in as an argument instead of being
    # inlined as bash syntax (which previously crashed the script).
    # Debug/error text goes to stderr so NEXT_TASK_JSON stays pure JSON.
    NEXT_TASK_JSON=$(python3 - "$VERBOSE" <<'PY' || true
import sys, json, io

verbose = (sys.argv[1] == "true")
from agent import execute_get_next_task

old_stdout = sys.stdout
try:
    sys.stdout = io.StringIO()
    result = execute_get_next_task({})
    sys.stdout = old_stdout

    if verbose:
        print("=== TOOL EXECUTION DEBUG ===", file=sys.stderr)
        print(f"Return type: {type(result).__name__}", file=sys.stderr)
        print(f"Is string: {isinstance(result, str)}", file=sys.stderr)
        print(f"Length: {len(result) if result else 0}", file=sys.stderr)
        if isinstance(result, str) and result.strip():
            print(f"Result preview: {result[:200]}", file=sys.stderr)

    print(result if result else "{}")
except Exception as e:
    import traceback
    print(f"ERROR: {e}", file=sys.stderr)
    if verbose:
        traceback.print_exc()
PY
)

    if [ "$VERBOSE" = true ]; then
        echo "=== DEBUG: Raw NEXT_TASK_JSON result ===" | tee -a "$LOGFILE"
        if [ -n "$NEXT_TASK_JSON" ]; then
            echo "Result is not empty!" | tee -a "$LOGFILE"
            if [[ "$NEXT_TASK_JSON" == *"\"done\": true"* ]]; then
                echo "Result indicates DONE" | tee -a "$LOGFILE"
            elif [[ "$NEXT_TASK_JSON" == *"\"num\":"* ]]; then
                echo "Result contains task info (num field)" | tee -a "$LOGFILE"
            else
                echo "Result is something else: $NEXT_TASK_JSON" | tee -a "$LOGFILE"
            fi
        else
            echo "ERROR: NEXT_TASK_JSON is empty!" | tee -a "$LOGFILE"
        fi
    fi

    # Check if done - Ralph wants to get the next task, if done it should be {"done": true}
    if echo "$NEXT_TASK_JSON" | grep -q '"done": true'; then
        echo "🎉 All tasks complete! Stopping." | tee -a "$LOGFILE"
        break
    fi

    # Get the task details from the response
    if echo "$NEXT_TASK_JSON" | grep -q '"num"'; then
        # We have a task to work on, format it for Ralph
        TASK_NUM=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['num'])")
        TASK_TITLE=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
        TASK_FUNC=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('func', ''))")
        TASK_TEST=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('test', ''))")

        echo "🎯 Working on Task $TASK_NUM: $TASK_TITLE (function: $TASK_FUNC, test: $TASK_TEST)" | tee -a "$LOGFILE"
        echo "Task JSON: $NEXT_TASK_JSON" >> "$LOGFILE"

        # Create a prompt for the task (heredoc avoids bash quoting issues)
        python3 - "$NEXT_TASK_JSON" <<'PY'
import json, sys

task = json.loads(sys.argv[1])

with open('prompt.md') as f:
    system = f.read().strip()

prompt = f'''{system}

Implement this task: Task {task['num']}: {task['title']}

Implement the function '{task['func']}' from tasks.py:
'''

func_code = task.get('func_code', '')
if func_code:
    prompt += f'''```python
{func_code}
```

IMPLEMENTATION REQUIREMENT:
Implement the function '{task['func']}' in workspace/tasks.py:
- If workspace/tasks.py already has functions, READ IT FIRST with read_file
- Write ALL existing functions PLUS this new one
- DO NOT overwrite existing functions
- Use: write_file with path="workspace/tasks.py"

'''

prompt += f'''Now implement this task. What tool calls should we make?

IMPORTANT: We need to implement function '{task['func']}' and potentially write a test for '{task['test']}' if it exists.

The tools available are: read_file, write_file, run_command, update_progress, get_next_task

Recommendation: First check if the function exists in tasks.py (use read_file), then if not create it (use write_file)
'''

with open('/tmp/ralph_prompt.txt', 'w') as f:
    f.write(prompt)
PY

        # Call LLM to decide what to do with the task (heredoc avoids quoting issues)
        PROMPT_RESPONSE=$(python3 - <<'PY' || true
import json
from ollama import Client

with open('/tmp/ralph_prompt.txt') as f:
    prompt = f.read()

client = Client()
resp = client.chat(
    model='qwen2.5:7b',
    messages=[{'role': 'user', 'content': prompt}],
    format='json',
    options={'temperature': 0.7}
)
print(resp['message']['content'])
PY
)

        echo "LLM response: $PROMPT_RESPONSE" >> "$LOGFILE"

        # Execute tool calls from LLM response (PROMPT_RESPONSE passed via argv)
        python3 - "$PROMPT_RESPONSE" <<'PY' 2>&1 | tee -a "$LOGFILE"
import json, subprocess, sys

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    r = json.loads(raw)
except json.JSONDecodeError as e:
    print(f'JSON error: {e}')
    sys.exit(0)

reasoning = r.get('reasoning', '')
if reasoning:
    print(f'Reasoning: {reasoning}')

# Normalize tool calls: handle all key variants
tool_calls = r.get('tool_calls', [])
if not tool_calls:
    tool_name = r.get('tool') or r.get('tool_to_use') or r.get('action') or ''
    if tool_name and tool_name not in ('done', 'write_function', 'write_test', 'run_pytest', 'get_next_task'):
        args = {k: v for k, v in r.items() if k not in ('tool', 'tool_to_use', 'action', 'reasoning', 'next_progress_update')}
        tool_calls = [{'name': tool_name, 'args': args}]

for call in tool_calls:
    name = call.get('name', '')
    args = call.get('args', {})
    args_json = json.dumps(args)
    print(f'Tool: {name}({args_json[:150]})')
    result = subprocess.run(
        ['python3', 'agent.py', 'execute', name, args_json],
        capture_output=True, text=True, timeout=130
    )
    output = result.stdout.strip()
    print(f'  -> {output[:200]}')

print('Step complete.')
PY
    else
        echo "⚠️ Unexpected response from get_next_task: $NEXT_TASK_JSON" | tee -a "$LOGFILE"
        continue
    fi

    sleep 1
done

echo "Ralph loop ended after $ITER iterations."
