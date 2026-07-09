#!/bin/bash
# ralph.sh - Simple Ralph Wiggum loop for Ollama with exclusive get_next_task tool

set -euo pipefail

MAX_ITERATIONS=${1:-50}
ITER=0
LOGFILE="logs/ralph_$(date +%s).log"
VERBOSE=false

# Parse verbose flag
if [[ "$1" == "-v" || "$1" == "--verbose" ]]; then
    VERBOSE=true
    shift
fi

mkdir -p logs

# Setup workspace from spec.md
python3 agent.py setup
echo "=== Starting Ralph Wiggum Loop for Ollama ==="
echo "Press Ctrl+C to stop. Max iterations: $MAX_ITERATIONS"
if [[ "$VERBOSE" == true ]]; then
    echo "=== VERBOSE MODE: Tool calls will be logged in detail ==="
fi

while [ $ITER -lt $MAX_ITERATIONS ]; do
    ITER=$((ITER + 1))
    echo "=== Iteration $ITER ===" | tee -a "$LOGFILE"

    # Get next task using exclusive get_next_task tool (direct tool call, no CLI confusion)
    if [[ "$VERBOSE" == true ]]; then
        echo "=== DEBUG: Calling execute_get_next_task ===" | tee -a "$LOGFILE"
    fi
    NEXT_TASK_JSON=$(python3 -c "
import json, sys, io
from agent import execute_get_next_task

old_stdout = sys.stdout
try:
    sys.stdout = io.StringIO()
    result = execute_get_next_task({})
    captured = sys.stdout.getvalue().strip()
    sys.stdout = old_stdout
    
    if [[ "$VERBOSE" == true ]]; then
        print(f'=== TOOL EXECUTION DEBUG ===')
        print(f'Return type: {type(result).__name__}')
        print(f'Is string: {isinstance(result, str)}')
        print(f'Length: {len(result) if result else 0}')
        if isinstance(result, str) and result.strip():
            print(f'Result preview: {result[:200]}')
    
    if result:
        print(result)
    else:
        print('{}')
except Exception as e:
    if [[ "$VERBOSE" == true ]]; then
        import traceback
        print(f'ERROR: {e}')
        print('Stack trace:')
        traceback.print_exc()
    else:
        print(f'ERROR: {e}', file=sys.stderr)
" 2>/dev/null)

    if [[ "$VERBOSE" == true ]]; then
        echo "=== DEBUG: Raw NEXT_TASK_JSON result ===" | tee -a "$LOGFILE"
        if [[ "$NEXT_TASK_JSON" ]]; then
            echo "Result is not empty!" | tee -a "$LOGFILE"
            if [[ "$NEXT_TASK_JSON" == *\"done\":\"true\"* ]]; then
                echo "Result indicates DONE" | tee -a "$LOGFILE"
            elif [[ "$NEXT_TASK_JSON" == *\"num\":* ]]; then
                echo "Result contains task info (num field)" | tee -a "$LOGFILE"
            else
                echo "Result is something else: $NEXT_TASK_JSON" | tee -a "$LOGFILE"
            fi
        else
            echo "ERROR: NEXT_TASK_JSON is empty!" | tee -a "$LOGFILE"
        fi
    fi

    # Check if done - Ralph wants to get the next task, if done it should be {\"done\": true}
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

        # Create a prompt for the task
        python3 -c "
import json, sys

if len(sys.argv) < 2:
    print('ERROR: Task JSON required')
    sys.exit(1)

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
- Use: write_file with path=\"workspace/tasks.py\"

'''

prompt += f'''Now implement this task. What tool calls should we make?

IMPORTANT: We need to implement function '{task['func']}' and potentially write a test for '{task['test']}' if it exists.

The tools available are: read_file, write_file, run_command, update_progress, get_next_task

Recommendation: First check if the function exists in tasks.py (use read_file), then if not create it (use write_file)
'''

with open('/tmp/ralph_prompt.txt', 'w') as f:
    f.write(prompt)
" "$NEXT_TASK_JSON"

        # Call LLM to decide what to do with the task
        PROMPT_RESPONSE=$(python3 -c "
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
" 2>/dev/null)

        echo "LLM response: $PROMPT_RESPONSE" >> "$LOGFILE"

        # Execute tool calls from LLM response
        echo "$PROMPT_RESPONSE" | python3 -c "
import json, subprocess, sys

try:
    r = json.loads(sys.stdin.read())
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
" 2>&1 | tee -a "$LOGFILE"
    else
        echo "⚠️ Unexpected response from get_next_task: $NEXT_TASK_JSON" | tee -a "$LOGFILE"
        continue
    fi

    sleep 1
done

echo "Ralph loop ended after $ITER iterations."
