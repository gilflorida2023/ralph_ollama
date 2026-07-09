#!/bin/bash
# Ralph Wiggum loop: restore done code, validate with pytest, store new code

set -euo pipefail

# Pin cwd to the script's directory
cd "$(dirname "${BASH_SOURCE[0]}")"

# Use the project's virtualenv (it has python deps) instead of system python3.
if [ -f venv/bin/activate ]; then
    source venv/bin/activate
fi

# Kill any PREVIOUS ralph.sh run still lingering (a leftover run holds the GPU).
# Skip $$ and all ancestor pids to avoid killing our own launcher tree.
SELF=$$
ANCESTORS="$SELF"
p=$PPID
while [ -n "$p" ] && [ "$p" != "0" ]; do
    ANCESTORS="$ANCESTORS $p"
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done
for pid in $(pgrep -f "ralph\.sh" 2>/dev/null || true); do
    skip=0
    for a in $ANCESTORS; do
        [ "$pid" = "$a" ] && skip=1 && break
    done
    [ "$skip" = 1 ] && continue
    echo "=== Killing previous ralph.sh process (pid $pid) ===" >&2
    for cpid in $(ps -o pid= --ppid "$pid" 2>/dev/null); do
        kill "$cpid" 2>/dev/null || true
    done
    kill "$pid" 2>/dev/null || true
done

# --- Arguments ---
MAX_ITERATIONS=50
VERBOSE=false
CLEAN=false
MODEL_NAME='qwen2.5:7b'
# Accepts either order: `ralph.sh 3 -v` or `ralph.sh -v 3`.
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose) VERBOSE=true ;;
        --clean) CLEAN=true ;;
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

# --- Done-code snapshot (manages progress without git) ---
RALPH_DONE_FILE="workspace/.ralph_good_state"
RALPH_DONE_CODE=""
if [ -f "$RALPH_DONE_FILE" ]; then
    RALPH_DONE_CODE=$(cat "$RALPH_DONE_FILE")
fi

# Setup workspace from agent.py; --clean forces a fresh start.
if [ "$CLEAN" = true ]; then
    echo "=== Clean start: running agent.py setup ==="
    python3 agent.py setup
    rm -f workspace/tasks.py "$RALPH_DONE_FILE"
else
    if [ ! -f workspace/tasks.json ]; then
        python3 agent.py setup
    fi
fi

# --- Token accumulator + elapsed-time reporting ---
echo '{"calls":0,"prompt_tokens":0,"completion_tokens":0}' > /tmp/ralph_token_usage.json
RALPH_START_EPOCH=$(date +%s)

print_summary() {
    if [ -f /tmp/ralph_token_usage.json ]; then
        python3 - /tmp/ralph_token_usage.json "${RALPH_START_EPOCH:-$(date +%s)}" "$MODEL_NAME" <<'PY' 2>&1 | tee -a "$LOGFILE"
import json, sys, time
with open(sys.argv[1]) as f:
    u = json.load(f)
start = int(sys.argv[2])
model = sys.argv[3]
elapsed = int(time.time()) - start
h = elapsed // 3600
m = (elapsed % 3600) // 60
s = elapsed % 60
if h:
    elapsed_str = f"{h}:{m:02d}:{s:02d}"
elif m:
    elapsed_str = f"{m}:{s:02d}"
else:
    elapsed_str = f"{s}"
c = u['calls']
pt = u['prompt_tokens']
ct = u['completion_tokens']
tt = pt + ct
print("=== Summary ===")
print(f"  Model Name:        {model}")
print(f"  Elapsed time:      {elapsed_str}")
print(f"  Ollama calls:      {c}")
if c:
    print(f"  Prompt tokens:     {pt}  (avg {pt//c}/call)")
    print(f"  Completion tokens: {ct}  (avg {ct//c}/call)")
    print(f"  Total tokens:      {tt}  (avg {tt//c}/call)")
print("================")
PY
    fi
}
trap print_summary EXIT

echo "=== Starting Ralph Wiggum Loop for Ollama ==="
echo "Press Ctrl+C to stop. Max iterations: $MAX_ITERATIONS"
[ "$VERBOSE" = true ] && echo "=== VERBOSE MODE ==="

while [ "$ITER" -lt "$MAX_ITERATIONS" ]; do
    ITER=$((ITER + 1))
    echo "=== Iteration $ITER ===" | tee -a "$LOGFILE"

    # --- 1. next_task --- (fix: was always returning {"done": true})
    NEXT_TASK_JSON=$(python3 - <<'PY'
import json
import sys
sys.path.insert(0, '.')
from agent import find_next_task
t = find_next_task()
print(json.dumps({"done": True}) if t is None else json.dumps(t))
PY
)

    if echo "$NEXT_TASK_JSON" | grep -q '"done": true'; then
        STUCK=$(python3 - <<'PY'
import sys, json
import sys
sys.path.insert(0, '.')
from agent import load_tasks, load_progress
p = load_progress()
print('stuck' if any(not p.get(t['num'], False) for t in load_tasks()) else 'done')
PY
)
        if [ "$STUCK" = "stuck" ]; then
            echo "⚠️ No available task — some tasks are BLOCKED. Stopping." | tee -a "$LOGFILE"
        else
            echo "🎉 All tasks complete! Stopping." | tee -a "$LOGFILE"
        fi
        break
    fi

    TASK_NUM=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['num'])" 2>/dev/null)
    TASK_TITLE=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])" 2>/dev/null)
    TASK_FUNC=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('func', ''))" 2>/dev/null)
    TASK_TEST=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('test', ''))" 2>/dev/null)
    TASK_DEPS=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('depends_on', [])))" 2>/dev/null)

    echo "🎯 Working on Task $TASK_NUM: $TASK_TITLE (function: $TASK_FUNC, test: $TASK_TEST)" | tee -a "$LOGFILE"

    # --- 2. restore done code (last successful snapshots) ---
    if [ -n "$RALPH_DONE_CODE" ]; then
        echo "$RALPH_DONE_CODE" > workspace/tasks.py
        echo "=== Restored done code from snapshot ===" | tee -a "$LOGFILE"
    elif [ ! -f workspace/tasks.py ]; then
        : > workspace/tasks.py
        echo "=== Created empty workspace/tasks.py ===" | tee -a "$LOGFILE"
    fi

    # Remove any stray project-root clone (a clone_repo without explicit workspace/
    # target would create ./simplesieve here and break downstream tasks that
    # explicitly target workspace/simplesieve). The legitimate clone always lives
    # in workspace/simplesieve per spec.md.
    if [ -e simplesieve ]; then
        echo "=== Removing stray project-root clone ./simplesieve ===" | tee -a "$LOGFILE"
        rm -rf simplesieve
    fi

    # Build prompt for this task
    python3 - "$NEXT_TASK_JSON" "$TASK_DEPS" <<'PY'
import json, sys, re

task = json.loads(sys.argv[1])
deps = json.loads(sys.argv[2])

with open('prompt.md') as f:
    system = f.read().strip()

with open('spec.md') as f:
    spec = f.read().strip()

m = re.search(r'## Task ' + str(task['num']) + r':.*?```python\s*\n(.*?)```\s*\n\*\*Test:\*\*.*?```python\s*\n(.*?)```', spec, re.DOTALL)
func_code = m.group(1).strip() if m else ''
test_code = m.group(2).strip() if m else ''

prompt = f'''{system}

Implement this task: Task {task['num']}: {task['title']}

Implement the function '{task['func']}' (AND its test '{task['test']}') in workspace/tasks.py:
- Read workspace/tasks.py first - existing functions are already there.
- Add ONLY the new function and its test.
- Re-write the ENTIRE file preserving all existing code (do NOT drop done functions).
- Keep main() at the bottom exactly as in spec.md.
'''
if func_code:
    prompt += f'''Use this exact reference implementation:
```python
{func_code}
```

'''
if test_code:
    prompt += f'''Use this exact reference test (calls any prerequisites already present in tasks.py):
```python
{test_code}
```

'''
if deps:
    try:
        tasks_list = json.load(open('workspace/tasks.json'))
    except Exception:
        tasks_list = []
    dep_lines = []
    for d in deps:
        for t in tasks_list:
            if t['num'] == d:
                dep_lines.append(f"  - Task {d}: {t['title']} (function {t['func']}() already exists in tasks.py)")
    if dep_lines:
        prompt += "This task depends on (already implemented - call them directly by name):\n"
        prompt += "\n".join(dep_lines) + "\n\n"

prompt += f'''Now implement this task. Steps:
1. read_file workspace/tasks.py (see what is already there)
2. write_file workspace/tasks.py (add {task['func']} + {task['test']}, keep main())
3. run_command with cmd="python3 -m pytest workspace/tasks.py -k {task['test']} -v" to validate
4. If the test fails, fix with write_file and re-run this command.
'''
with open('/tmp/ralph_prompt.txt', 'w') as f:
    f.write(prompt)
PY

    # --- 3. inner retry loop (up to 10 attempts) ---
    MAX_ATTEMPTS=10
    ATT=0
    TASK_DONE=false
    PYTEST_OUTPUT=""
    while [ "$ATT" -lt "$MAX_ATTEMPTS" ] && [ "$TASK_DONE" != "true" ]; do
        ATT=$((ATT + 1))
        # On retry: restore the last good snapshot so the model starts from known state
        if [ "$ATT" -gt 1 ] && [ -n "$RALPH_DONE_CODE" ]; then
            echo "$RALPH_DONE_CODE" > workspace/tasks.py
            echo "=== Restored done code from snapshot for retry $ATT ===" | tee -a "$LOGFILE"
        fi

        if [ "$VERBOSE" = true ]; then
            echo "=== DEBUG: Prompt sent to Ollama (attempt $ATT) ===" | tee -a "$LOGFILE"
            cat /tmp/ralph_prompt.txt | tee -a "$LOGFILE"
            echo "=== END PROMPT ===" | tee -a "$LOGFILE"
        fi

        # Call Ollama and capture API response (robust - curl and jq in sequence)
        (jq -Rs --arg model "$MODEL_NAME" \
            '{model: $model, messages: [{role: "user", content: .}], format: "json", stream: false, options: {temperature: 0.7}}' \
            /tmp/ralph_prompt.txt \
         | curl -s http://localhost:11434/api/chat -d @- \
         | tee /tmp/ralph_last_response.json \
         | jq -r '.message.content // ""') > /tmp/ralph_response.txt

        # Extract content and accumulate token usage from last_response.json
        PROMPT_RESPONSE=$(cat /tmp/ralph_response.txt 2>/dev/null || echo "")
        if [ -f /tmp/ralph_token_usage.json ] && [ -f /tmp/ralph_last_response.json ]; then
            python3 - /tmp/ralph_token_usage.json /tmp/ralph_last_response.json <<'PY'
import json, sys
with open(sys.argv[1]) as a_f, open(sys.argv[2]) as r_f:
    a = json.load(a_f)
    r = json.load(r_f)
a['calls'] += 1
if 'prompt_eval_count' in r:
    a['prompt_tokens'] += r['prompt_eval_count']
if 'eval_count' in r:
    a['completion_tokens'] += r['eval_count']
json.dump(a, open(sys.argv[1], 'w'))
PY
        fi

        if [ "$VERBOSE" = true ]; then
            echo "=== DEBUG: Raw Ollama response (attempt $ATT) ===" | tee -a "$LOGFILE"
            cat /tmp/ralph_response.txt | tee -a "$LOGFILE"
            echo "=== END RESPONSE ===" | tee -a "$LOGFILE"
        else
            echo "LLM response: $(cat /tmp/ralph_response.txt 2>/dev/null | head -c 200)" >> "$LOGFILE"
        fi

        python3 - "$PROMPT_RESPONSE" <<'PY' 2>&1 || true
import json, subprocess, sys, re

raw = sys.argv[1] if len(sys.argv) > 1 else ""

raw = raw.strip()
raw = raw.replace('```json', '').replace('```', '').strip()

def normalize_tool_calls(raw):
    try:
        r = json.loads(raw)
    except json.JSONDecodeError as e:
        return [], f"JSON decode error: {e}"
    tool_calls = r.get('tool_calls', [])
    if not tool_calls:
        tool_name = r.get('tool') or r.get('tool_to_use') or r.get('action')
        if tool_name and tool_name not in ('done', 'write_function', 'write_test', 'run_pytest', 'get_next_task'):
            args = {k: v for k, v in r.items() if k not in ('tool', 'tool_to_use', 'action', 'reasoning', 'next_progress_update')}
            tool_calls = [{'name': tool_name, 'args': args}]
    normalized = []
    for call in tool_calls:
        if not isinstance(call, dict):
            print(f"SKIP (not dict): {call}")
            continue
        name = call.get('name') or call.get('function') or call.get('tool') or ''
        if not name:
            print(f"SKIP (nameless): {call}")
            continue
        if name in ('run_shell', 'shell'):
            name = 'run_command'
        args = call.get('args') or call.get('parameters') or {}
        normalized.append({'name': name, 'args': args})
    if not normalized:
        return [], "No valid tool calls"
    return normalized, None

normalized, err = normalize_tool_calls(raw)
if err:
    print(f"PARSE ERROR: {err}")
    sys.exit(0)

ALLOWED = {'read_file', 'write_file', 'run_command', 'debrief_task'}
for call in normalized:
    name = call['name']
    args = call['args']
    if name not in ALLOWED:
        print(f"Tool {name} -> BLOCKED (not permitted for model)")
        continue
    print(f"Tool: {name}({json.dumps(args)})")
    result = subprocess.run(['python3', 'agent.py', 'execute', name, json.dumps(args)],
                            capture_output=True, text=True, timeout=130)
    print(f"  -> {result.stdout.strip()[:200]}")
PY

        # --- 4. validate via pytest ---
        echo "=== Running validation (pytest) ===" | tee -a "$LOGFILE"
        # Do NOT let `set -e` abort the script on a failing test; capture rc.
        PYTEST_OUTPUT=$(python3 -m pytest workspace/tasks.py -k "$TASK_TEST" -v --tb=short 2>&1) || PYTEST_RC=$?
        PYTEST_RC=${PYTEST_RC:-0}
        echo "$PYTEST_OUTPUT" | tee -a "$LOGFILE"

        if [ "$PYTEST_RC" -eq 0 ]; then
            echo "=== Test passed, marking task DONE ===" | tee -a "$LOGFILE"
            python3 agent.py execute mark_task "{\"num\":$TASK_NUM,\"state\":\"done\"}" >> "$LOGFILE" 2>&1
            # Snapshot the verified code so future tasks start from it.
            cp workspace/tasks.py "$RALPH_DONE_FILE"
            echo "=== Snapshot saved to workspace/.ralph_good_state ===" | tee -a "$LOGFILE"
            TASK_DONE=true
        else
            if [ "$ATT" -lt "$MAX_ATTEMPTS" ]; then
                echo "=== Test failed (attempt $ATT/$MAX_ATTEMPTS), adding feedback ===" | tee -a "$LOGFILE"
                TASKS_PY_CONTENT="$(cat workspace/tasks.py 2>/dev/null || echo '')"
                python3 - "$TASK_FUNC" "$TASK_TEST" "$TASKS_PY_CONTENT" "$PYTEST_OUTPUT" <<'PY'
import sys
task_func = sys.argv[1]
task_test = sys.argv[2]
tasks_py = sys.argv[3]
verify_out = sys.argv[4]
with open('/tmp/ralph_prompt.txt', 'a') as f:
    f.write("\n\nPREVIOUS ATTEMPT FAILED.\n")
    f.write(f"\n=== workspace/tasks.py ===\n{tasks_py}\n")
    f.write(f"\n=== test output (python3 -m pytest workspace/tasks.py -k {task_test} -v) ===\n{verify_out}\n")
    f.write(f"\nFix the code and re-run: python3 -m pytest workspace/tasks.py -k {task_test} -v\n")
PY
            else
                echo "=== Task failed after $MAX_ATTEMPTS attempts, marking BLOCKER ===" | tee -a "$LOGFILE"
                python3 agent.py execute mark_task "{\"num\":$TASK_NUM,\"state\":\"blocked\"}" >> "$LOGFILE" 2>&1
                TASK_DONE=true
            fi
        fi
    done

    sleep 1
done

echo "Ralph loop ended after $ITER iterations."
