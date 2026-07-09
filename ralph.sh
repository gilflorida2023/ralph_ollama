#!/bin/bash
# ralph.sh - Simple Ralph Wiggum loop for Ollama
#
# Flow per iteration:
#   1. next_task  -> which task to work on (skips tasks with unmet dependencies)
#   2. restore    -> copy workspace/.ralph_good_state -> workspace/tasks.py (last good code)
#   3. prompt     -> build a prompt from prompt.md + the task + its dependencies
#   4. model      -> call Ollama, execute the tool calls the model returns
#   5. validate   -> run `python3 workspace/tasks.py <test>` (exit 0 = pass)
#   6. snapshot   -> on pass, copy tasks.py -> .ralph_good_state and mark task done
#
# Done code is kept in a flat snapshot file (workspace/.ralph_good_state), not
# in git. No merge logic: before each attempt the snapshot is restored so the
# model always starts from known-good code.

set -euo pipefail

# Pin cwd to the script's directory (PROJECT_ROOT) so all relative paths used
# by the agent (workspace/simplesieve, workspace/tasks.py, prompt.md) resolve
# deterministically against the project root.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use the project's virtualenv (it has python deps) instead of system python3.
if [ -f venv/bin/activate ]; then
    # shellcheck disable=SC1091
    source venv/bin/activate
fi

# Kill any PREVIOUS ralph.sh run still lingering (a stuck previous run holds the
# GPU and makes new Ollama chat calls hang). Run this INLINE in the main shell
# (a `bash -c` subshell would match pgrep -f "ralph\.sh" and kill ITSELF).
# Skip $$ and every ancestor pid so we never kill our own launcher tree.
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

# --- Token accumulator + elapsed-time reporting ---
echo '{"calls":0,"prompt_tokens":0,"completion_tokens":0}' > /tmp/ralph_token_usage.json
RALPH_START_EPOCH=$(date +%s)

print_summary() {
    if [ -f /tmp/ralph_token_usage.json ]; then
        python3 - /tmp/ralph_token_usage.json "${RALPH_START_EPOCH:-$(date +%s)}" "$MODEL_NAME" <<'PY' 2>&1 | tee -a "$LOGFILE"
import json, sys, time
with open(sys.argv[1]) as f:
    u = json.load(f)
start = int(sys.argv[2]); model = sys.argv[3]
elapsed = int(time.time()) - start
h = elapsed // 3600; m = (elapsed % 3600) // 60; s = elapsed % 60
if h: elapsed_str = f"{h}:{m:02d}:{s:02d}"
elif m: elapsed_str = f"{m}:{s:02d}"
else: elapsed_str = f"{s}"
c = u['calls']; pt = u['prompt_tokens']; ct = u['completion_tokens']; tt = pt + ct
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

# --- Setup ---
if [ "$CLEAN" = true ]; then
    echo "=== Clean start: running agent.py setup ==="
    python3 agent.py setup
    rm -f workspace/tasks.py workspace/.ralph_good_state
elif [ -f workspace/tasks.json ]; then
    echo "=== Continuing existing run (skipping agent.py setup) ==="
else
    echo "=== No existing workspace/tasks.json found; running agent.py setup ==="
    python3 agent.py setup
fi

echo "=== Starting Ralph Wiggum Loop for Ollama ==="
echo "Press Ctrl+C to stop. Max iterations: $MAX_ITERATIONS"
[ "$VERBOSE" = true ] && echo "=== VERBOSE MODE ==="

while [ "$ITER" -lt "$MAX_ITERATIONS" ]; do
    ITER=$((ITER + 1))
    echo "=== Iteration $ITER ===" | tee -a "$LOGFILE"

    # --- 1. next_task ---
    NEXT_TASK_JSON=$(python3 - <<'PY'
import json, sys
sys.path.insert(0, '.')
from agent import find_next_task
t = find_next_task()
print(json.dumps({"done": True}) if t is None else json.dumps(t))
PY
)

    if echo "$NEXT_TASK_JSON" | grep -q '"done": true'; then
        # A null next_task can mean "all done" OR "stuck on a BLOCKER". Tell
        # them apart so we don't falsely claim success.
        STUCK=$(python3 - <<'PY'
import sys, json
sys.path.insert(0, '.')
from agent import load_tasks, load_progress
p = load_progress()
print('stuck' if any(not p.get(t['num'], False) for t in load_tasks()) else 'done')
PY
)
        if [ "$STUCK" = "stuck" ]; then
            echo "⚠️  No available task — some tasks are BLOCKED. Stopping." | tee -a "$LOGFILE"
        else
            echo "🎉 All tasks complete! Stopping." | tee -a "$LOGFILE"
        fi
        break
    fi

    TASK_NUM=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['num'])")
    TASK_TITLE=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
    TASK_FUNC=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('func', ''))")
    TASK_TEST=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('test', ''))")
    TASK_DEPS=$(echo "$NEXT_TASK_JSON" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('depends_on', [])))")

    echo "🎯 Working on Task $TASK_NUM: $TASK_TITLE (function: $TASK_FUNC, test: $TASK_TEST, deps: $TASK_DEPS)" | tee -a "$LOGFILE"

    # --- 2. restore last good code ---
    if [ -f workspace/.ralph_good_state ]; then
        cp workspace/.ralph_good_state workspace/tasks.py
        echo "=== Restored done code from snapshot ===" | tee -a "$LOGFILE"
    elif [ ! -f workspace/tasks.py ]; then
        : > workspace/tasks.py
        echo "=== Created empty workspace/tasks.py ===" | tee -a "$LOGFILE"
    fi

    # Remove any stray clone at the project root (a clone_repo without the
    # explicit target would create ./simplesieve instead of ./workspace/simplesieve).
    if [ -e simplesieve ]; then
        echo "=== Removing stray project-root clone ./simplesieve ===" | tee -a "$LOGFILE"
        rm -rf simplesieve
    fi

    # --- 3. build prompt ---
    python3 - "$NEXT_TASK_JSON" "$TASK_DEPS" <<'PY'
import json, sys
task = json.loads(sys.argv[1])
deps = json.loads(sys.argv[2])
with open('prompt.md') as f:
    system = f.read().strip()

prompt = f'''{system}

Implement this task: Task {task['num']}: {task['title']}

Implement the function '{task['func']}' and its test '{task['test']}' in workspace/tasks.py:
- Read workspace/tasks.py first - existing functions are already there.
- Add ONLY the new function and its test.
- Re-write the ENTIRE file preserving all existing code (do NOT drop done functions).
- Keep main() at the bottom exactly as in spec.md.

'''

# Inject the spec's EXACT reference implementation + test so the model does not
# invent its own (the model cannot see spec.md directly). Using the spec's test
# matters: e.g. test_get_project_dir calls clone_repo() as a prerequisite.
func_code = task.get('func_code', '')
test_code = task.get('test_code', '')
if func_code:
    prompt += f'''Implement EXACTLY this function (reference from spec.md):
```python
{func_code}
```

'''
if test_code:
    prompt += f'''Implement EXACTLY this test (reference from spec.md):
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

prompt += f'''Now implement this task. Use: read_file, write_file, run_command.

Steps:
1. read_file workspace/tasks.py (see what is already there)
2. write_file workspace/tasks.py (add {task['func']} + {task['test']}, keep main())
3. run_command with cmd="python3 workspace/tasks.py {task['test']}"
4. If the test fails, fix with write_file and re-run the same command.

After your test passes (or on your final attempt), call debrief_task as your last tool call.
'''
with open('/tmp/ralph_prompt.txt', 'w') as f:
    f.write(prompt)
PY

    # --- 4 + 5. model call + validate, with retry ---
    MAX_ATTEMPTS=10
    ATT=0
    TASK_DONE=false
    TASK_FAILED=false
    PYTEST_OUTPUT=""
    while [ "$ATT" -lt "$MAX_ATTEMPTS" ] && [ "$TASK_DONE" != "true" ] && [ "$TASK_FAILED" != "true" ]; do
        ATT=$((ATT + 1))

        # On retry, restore the snapshot (the model may have dropped done code).
        if [ "$ATT" -gt 1 ] && [ -f workspace/.ralph_good_state ]; then
            cp workspace/.ralph_good_state workspace/tasks.py
            echo "=== Restored done code from snapshot for retry $ATT ===" | tee -a "$LOGFILE"
        fi

        if [ "$VERBOSE" = true ]; then
            echo "=== DEBUG: Prompt sent to Ollama (attempt $ATT) ===" | tee -a "$LOGFILE"
            cat /tmp/ralph_prompt.txt | tee -a "$LOGFILE"
            echo "=== END PROMPT ===" | tee -a "$LOGFILE"
        fi

        # Call Ollama via curl + jq (stream:false) for raw token stats.
        PROMPT_RESPONSE=$(
            jq -Rs --arg model "${MODEL_NAME}" \
                '{model: $model, messages: [{role: "user", content: .}], format: "json", stream: false, options: {temperature: 0.7}}' \
                /tmp/ralph_prompt.txt \
            | curl -s http://localhost:11434/api/chat -d @- \
            | tee /tmp/ralph_last_response.json \
            | jq -r '.message.content // ""'
        )

        # Accumulate token usage.
        python3 - /tmp/ralph_token_usage.json /tmp/ralph_last_response.json <<'PY' || true
import json, sys
with open(sys.argv[1]) as a_f, open(sys.argv[2]) as r_f:
    a = json.load(a_f); r = json.load(r_f)
a['calls'] += 1
a['prompt_tokens'] += r.get('prompt_eval_count', 0)
a['completion_tokens'] += r.get('eval_count', 0)
json.dump(a, open(sys.argv[1], 'w'))
PY

        if [ "$VERBOSE" = true ]; then
            echo "=== DEBUG: Raw Ollama response (attempt $ATT) ===" | tee -a "$LOGFILE"
            echo "$PROMPT_RESPONSE" | tee -a "$LOGFILE"
            echo "=== END RESPONSE ===" | tee -a "$LOGFILE"
        else
            echo "LLM response: $PROMPT_RESPONSE" >> "$LOGFILE"
        fi

        # Parse + execute the tool calls the model returned.
        python3 - "$PROMPT_RESPONSE" <<'PY' 2>&1
import json, subprocess, sys
raw = sys.argv[1] if len(sys.argv) > 1 else ""

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
            print(f"SKIP (not dict): {call}"); continue
        name = call.get('name') or call.get('function') or call.get('tool') or ''
        if not name:
            print(f"SKIP (nameless): {call}"); continue
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

# The model may ONLY use these tools. Progress (mark_task / update_progress)
# and next_task are driven exclusively by the harness, so the model cannot
# corrupt task state or skip ahead.
ALLOWED = {'read_file', 'write_file', 'run_command', 'debrief_task'}

for call in normalized:
    name = call['name']; args = call['args']
    if name not in ALLOWED:
        print(f"Tool: {name} -> BLOCKED (not permitted for model)")
        continue
    print(f"Tool: {name}({json.dumps(args)})")
    result = subprocess.run(['python3', 'agent.py', 'execute', name, json.dumps(args)],
                            capture_output=True, text=True, timeout=130)
    print(f"  -> {result.stdout.strip()[:200]}")

print('Step complete.')
PY

        # --- Enforce the canonical main() from spec.md ---
        # The model tends to replace main() with something that does NOT run the
        # requested test (e.g. doctest.testmod()), which makes validation a
        # false positive. Always rewrite the trailing main()/if __name__ block
        # with the canonical dispatcher from spec.md's Entry point section.
        python3 - <<'PY' || true
import re
with open('spec.md') as f:
    spec = f.read()
m = re.search(r'## Entry point.*?```python\s*\n(.*?)```', spec, re.DOTALL)
canonical_main = m.group(1).strip() if m else ''
if not canonical_main:
    print('WARN: could not find canonical main() in spec.md')
else:
    with open('workspace/tasks.py') as f:
        content = f.read()
    idx = content.find('def main(')
    head = content[:idx].rstrip() if idx != -1 else content.rstrip()
    out = head + '\n\n\n' + canonical_main + '\n'
    with open('workspace/tasks.py', 'w') as f:
        f.write(out)
    print("Enforced canonical main() from spec.md")
PY

        # --- 5. validate via the module's main() dispatcher ---
        echo "=== Running verification ===" | tee -a "$LOGFILE"
        # Do NOT let `set -e` abort the script on a failing test; capture rc.
        PYTEST_OUTPUT=$(python3 workspace/tasks.py "$TASK_TEST" 2>&1) || PYTEST_RC=$?
        PYTEST_RC=${PYTEST_RC:-0}
        echo "$PYTEST_OUTPUT" | tee -a "$LOGFILE"

        if [ "$PYTEST_RC" -eq 0 ]; then
            echo "=== Test passed, marking task DONE ===" | tee -a "$LOGFILE"
            python3 agent.py execute mark_task "{\"num\":$TASK_NUM,\"state\":\"done\"}" >> "$LOGFILE" 2>&1
            # Snapshot the verified code so future tasks start from it.
            cp workspace/tasks.py workspace/.ralph_good_state
            echo "=== Snapshot saved to workspace/.ralph_good_state ===" | tee -a "$LOGFILE"
            TASK_DONE=true
        else
            if [ "$ATT" -ge "$MAX_ATTEMPTS" ]; then
                echo "=== Task failed after $MAX_ATTEMPTS attempts, marking BLOCKER ===" | tee -a "$LOGFILE"
                python3 agent.py execute mark_task "{\"num\":$TASK_NUM,\"state\":\"blocked\"}" >> "$LOGFILE" 2>&1
                TASK_FAILED=true
            else
                echo "=== Test failed (attempt $ATT/$MAX_ATTEMPTS), adding feedback ===" | tee -a "$LOGFILE"
                TASKS_PY_CONTENT="$(cat workspace/tasks.py 2>/dev/null || echo '')"
                python3 - "$TASK_FUNC" "$TASK_TEST" "$TASKS_PY_CONTENT" "$PYTEST_OUTPUT" <<'PY'
import sys
task_func = sys.argv[1]; task_test = sys.argv[2]; tasks_py = sys.argv[3]; verify_out = sys.argv[4]
with open('/tmp/ralph_prompt.txt', 'a') as f:
    f.write("\n\nPREVIOUS ATTEMPT FAILED.\n")
    f.write(f"\n=== workspace/tasks.py ===\n{tasks_py}\n")
    f.write(f"\n=== test output (python3 workspace/tasks.py {task_test}) ===\n{verify_out}\n")
    f.write(f"\nFix the code and re-run: python3 workspace/tasks.py {task_test}\n")
PY
            fi
        fi
    done

    sleep 1
done

echo "Ralph loop ended after $ITER iterations."
