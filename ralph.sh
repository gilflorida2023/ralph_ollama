#!/bin/bash
# Ralph Wiggum loop: restore done code, validate with pytest, store new code

set -euo pipefail

# Pin cwd to the script's directory
cd "$(dirname "${BASH_SOURCE[0]}")"

# Use the project's virtualenv (it has python deps) instead of system python3.
if [ -f venv/bin/activate ]; then
    source venv/bin/activate
fi

# --- Singleton guard: ensure only ONE ralph.sh loop runs at a time. ---
# A lingering previous run holds the GPU and corrupts shared state
# (workspace/tasks.py, progress.md). We use a PID lock file plus a
# pgrep sweep so that launches via `setsid`/`nohup` (which break the
# parent/child ancestry the old logic relied on) are still detected.
RALPH_LOCK="workspace/.ralph.pid"
SELF=$$

kill_tree() {
    # Kill a pid and all of its direct children, best-effort.
    local pid="$1"
    for cpid in $(ps -o pid= --ppid "$pid" 2>/dev/null); do
        kill -9 "$cpid" 2>/dev/null || true
    done
    kill -9 "$pid" 2>/dev/null || true
}

# 1) Honor an existing lock file: if it points at a live process, kill it.
if [ -f "$RALPH_LOCK" ]; then
    OLD_PID=$(cat "$RALPH_LOCK" 2>/dev/null || echo "")
    if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$SELF" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "=== Killing previous ralph.sh (lock pid $OLD_PID) ===" >&2
        kill_tree "$OLD_PID"
    fi
fi

# 2) Sweep any other process whose command line invokes this script, skipping
#    ourselves and our own ancestor tree (so we never kill our launcher).
ANCESTORS="$SELF"
p=$PPID
while [ -n "$p" ] && [ "$p" != "0" ]; do
    ANCESTORS="$ANCESTORS $p"
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ralph.sh"
for pid in $(pgrep -f "ralph\.sh" 2>/dev/null || true); do
    skip=0
    for a in $ANCESTORS; do
        [ "$pid" = "$a" ] && skip=1 && break
    done
    [ "$skip" = 1 ] && continue
    [ "$pid" = "$SELF" ] && continue
    echo "=== Killing previous ralph.sh process (pid $pid) ===" >&2
    kill_tree "$pid"
done

# 3) Take the lock.
echo "$SELF" > "$RALPH_LOCK"

# Release the lock on exit.
cleanup_lock() { rm -f "$RALPH_LOCK" 2>/dev/null || true; }

# --- Arguments ---
MAX_ITERATIONS=50
VERBOSE=false
CLEAN=false
MODEL_NAME='qwen2.5-coder:7b'
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
trap 'print_summary; cleanup_lock' EXIT

echo "=== Starting Ralph Wiggum Loop for Ollama ==="
echo "Press Ctrl+C to stop. Max iterations: $MAX_ITERATIONS"
[ "$VERBOSE" = true ] && echo "=== VERBOSE MODE ==="

# Ensure the workspace scaffolding (tasks.json + progress.md) exists. This is
# idempotent; without it the harness cannot track task state.
python3 agent.py setup >> "$LOGFILE" 2>&1 || true

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
import sys
sys.path.insert(0, '.')
from agent import load_tasks
try:
    with open('workspace/progress.md') as f:
        content = f.read()
except FileNotFoundError:
    content = ''
blocked = '[BLOCKED]' in content
done_all = all(f"[DONE] Task {t['num']}:" in content for t in load_tasks())
# find_next_task() returned None at the top of the loop, which only happens
# when NO task can be started: either every task is [DONE] (success) or some
# dependency chain is stuck (a task is BLOCKED / incomplete). It is 'done'
# ONLY when every task carries a [DONE] marker; otherwise we are stuck and
# must stop instead of looping forever or exiting with a false success.
print('done' if done_all else 'stuck')
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

# Match new spec format: ### Task N: ... ```python (Implementation) ```
m = re.search(r'### Task ' + str(task['num']) + r':.*?```python\s*\n(.*?)```', spec, re.DOTALL)
func_code = m.group(1).strip() if m else ''

prompt = f'''{system}

Implement this task: Task {task['num']}: {task['title']}

Implement the function '{task['func']}' with embedded doctests in workspace/tasks.py:
- Read workspace/tasks.py first - existing functions are already there.
- Add ONLY the new function with its doctests in the docstring.
- Re-write the ENTIRE file preserving all existing code (do NOT drop done functions).
'''
if task['num'] == 5:
    prompt += f'''- This is Task 5: add `main()` as the LAST definition in the file (after all task functions) plus `if __name__ == "__main__": main()`. Embed the ordering doctest from spec.md so validation proves main() is at the bottom.
'''
else:
    prompt += f'''- Do NOT add `main()` in this task - wiring up `main()` is Task 5's responsibility.
'''
if func_code:
    prompt += f'''Use this exact reference implementation (includes doctests in docstring):
```python
{func_code}
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
2. write_file workspace/tasks.py (add {task['func']} with doctests in its docstring)
3. run_command with cmd="python3 -m pytest --doctest-modules workspace/tasks.py -v -k {task['func']}" to validate ONLY this task's doctests
4. If the test fails, fix with write_file and re-run this command.
'''
if task['num'] == 5:
    prompt += f'''IMPORTANT: This is Task 5. Add `main()` as the LAST definition in the file (after all task functions) plus `if __name__ == "__main__": main()`. Include the ordering doctest from spec.md so validation proves main() is at the bottom. Do NOT add main() during earlier tasks.
'''
else:
    prompt += f'''Do NOT add `main()` in this task — wiring up `main()` is Task 5's responsibility. Just add {task['func']} and keep all previously implemented functions.
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

        # Call Ollama and capture API response. Retry on transient failures
        # (curl error, empty body, GPU OOM) so a single hiccup never kills the
        # whole loop: `set -euo pipefail` would otherwise abort the script when
        # curl/jq return non-zero inside the pipeline.
        PROMPT_RESPONSE=""
        OLLAMA_OK=false
        for oa in 1 2 3 4 5; do
            curl_out=$(jq -Rs --arg model "$MODEL_NAME" \
                '{model: $model, messages: [{role: "user", content: .}], format: "json", stream: false, options: {temperature: 0.7}}' \
                /tmp/ralph_prompt.txt 2>/dev/null \
              | curl -s --max-time 180 http://localhost:11434/api/chat -d @- 2>/dev/null) || true
            if [ -n "$curl_out" ]; then
                echo "$curl_out" > /tmp/ralph_last_response.json
                PROMPT_RESPONSE=$(echo "$curl_out" | jq -r '.message.content // ""' 2>/dev/null || true)
                if [ -n "$PROMPT_RESPONSE" ]; then
                    OLLAMA_OK=true
                    break
                fi
            fi
            echo "=== Ollama call empty/failed (retry $oa/5) — sleeping 5s ===" | tee -a "$LOGFILE"
            sleep 5
        done

        # If Ollama is unreachable after retries, mark the task BLOCKED and move on
        # rather than aborting the entire loop.
        if [ "$OLLAMA_OK" != "true" ]; then
            echo "=== Ollama unavailable after 5 retries — marking Task $TASK_NUM BLOCKED ===" | tee -a "$LOGFILE"
            python3 agent.py execute mark_task "{\"num\":$TASK_NUM,\"state\":\"blocked\"}" >> "$LOGFILE" 2>&1
            TASK_DONE=true
            continue
        fi

        # Extract content and accumulate token usage from last_response.json
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
        if tool_name and tool_name not in ('done', 'write_function', 'write_test', 'run_pytest'):
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

ALLOWED = {'read_file', 'write_file', 'run_command', 'debrief_task', 'mark_task', 'get_next_task'}
# The harness is the SOLE authority on task completion (FSM). The model's
# mark_task calls are ignored so it cannot prematurely mark tasks done just
# because it wrote their code in one shot — each task must pass validation
# via the harness before it is accepted.
MODEL_SKIP = {'mark_task', 'get_next_task'}
for call in normalized:
    name = call['name']
    args = call['args']
    if name not in ALLOWED:
        print(f"Tool {name} -> BLOCKED (not permitted for model)")
        continue
    if name in MODEL_SKIP:
        print(f"Tool: {name}({json.dumps(args)}) -> SKIPPED (harness owns task state)")
        continue
    print(f"Tool: {name}({json.dumps(args)})")
    result = subprocess.run(['python3', 'agent.py', 'execute', name, json.dumps(args)],
                            capture_output=True, text=True, timeout=130)
    print(f"  -> {result.stdout.strip()[:200]}")
PY

        # --- FSM enforcement (structural, model-independent) ---
        # The model frequently ignores the "one task at a time" rule and dumps
        # every function into tasks.py at once, often with malformed doctests
        # that abort pytest COLLECTION for the whole module. We therefore
        # REBUILD tasks.py from the verified snapshot plus ONLY the current
        # task's function, surgically dropping any extras the model added.
        # This guarantees the file can always be collected and validated.
        python3 - "$TASK_FUNC" "$TASK_NUM" <<'PY' || true
import sys, re
task_func = sys.argv[1]
task_num = int(sys.argv[2])
SNAP = 'workspace/.ralph_good_state'
CUR = 'workspace/tasks.py'

def extract_funcs(src):
    matches = list(re.finditer(r'(?m)^def (\w+)\(', src))
    out = {}
    for i, m in enumerate(matches):
        start = m.start()
        end = matches[i+1].start() if i + 1 < len(matches) else len(src)
        out[m.group(1)] = src[start:end].rstrip() + "\n"
    return out

def extract_imports(src):
    return [l for l in src.splitlines() if re.match(r'^\s*(import |from )', l)]

try:
    snap_src = open(SNAP).read()
except FileNotFoundError:
    snap_src = ""
cur_src = open(CUR).read()
snap_funcs = extract_funcs(snap_src)
cur_funcs = extract_funcs(cur_src)

allowed = (set(snap_funcs) | {'main'}) if task_num == 5 else (set(snap_funcs) | {task_func})

# Keep verified snapshot functions that are allowed; recover them even if the
# model dropped them this attempt.
final = {}
dropped = []
for name, body in snap_funcs.items():
    if name in allowed:
        final[name] = body
    else:
        dropped.append(name)

# Take the current task's function from the model's latest write.
added = None
if task_func in cur_funcs:
    added = cur_funcs[task_func]
    final[task_func] = added
else:
    # Model didn't even write the required function — fall back to snapshot if present.
    if task_func in snap_funcs:
        final[task_func] = snap_funcs[task_func]

# Inject CANONICAL doctests for each task function. The model reliably writes
# broken/echoing doctests (e.g. calling clone_repo() inside build_program's
# doctest, which echoes CompletedProcess). Using a known-good doctest per task
# makes validation depend only on the IMPLEMENTATION being correct, not on the
# model's doctest-writing skill. The canonical doctests assume the conventional
# return types (clone_repo -> CompletedProcess, build_program -> returncode int,
# count_primes -> stderr string).
CANON_DOCTESTS = {
    'clone_repo': '''"""Clone the simplesieve repository.

    >>> import os
    >>> result = clone_repo()
    >>> result.returncode == 0
    True
    >>> os.path.isdir("workspace/simplesieve/.git")
    True
    """''',
    'get_project_dir': '''"""Return the absolute path to the project directory.

    >>> import os
    >>> os.path.isabs(get_project_dir())
    True
    >>> os.path.isdir(get_project_dir())
    True
    """''',
    'build_program': '''"""Build the Go program.

    >>> build_program() == 0
    True
    """''',
    'count_primes': '''"""Run the sieve and return the prime count as a string.

    >>> "78498" in str(count_primes())
    True
    """''',
    'main': '''"""Entry point; runs all tasks in order.

    >>> import sys, re
    >>> src = open(sys.modules[__name__].__file__).read()
    >>> defs = re.findall(r'^def (\\w+)\\(', src, re.M)
    >>> defs[-1]
    'main'
    """''',
}
def _replace_docstring(body, canon):
    # Replace the first triple-quoted docstring with the canonical one.
    return re.sub(r'"""[\s\S]*?"""', canon, body, count=1)
for name in list(final.keys()):
    if name in CANON_DOCTESTS:
        final[name] = _replace_docstring(final[name], CANON_DOCTESTS[name])

# Union of imports (snapshot first, then any new ones the model added).
snap_imp = extract_imports(snap_src)
cur_imp = extract_imports(cur_src)
imports = snap_imp + [i for i in cur_imp if i not in snap_imp]

# Enforce: main() must be LAST for Task 5.
if task_num == 5 and 'main' in final:
    main_body = final.pop('main')
    ordered = [final[k] for k in final] + [main_body]
else:
    ordered = list(final.values())

new_src = "\n".join(imports).rstrip() + "\n\n" + "\n".join(ordered).rstrip() + "\n"

# Guarantee `clone_repo` is SILENT: force any `git clone` run() call to use
# capture_output=True. The model frequently omits this, and the resulting
# "Cloning into…" output leaks into build_program/count_primes/main doctests
# (which self-heal by calling clone_repo) and fails them. Enforcing it here
# makes the harness robust to that model mistake.
import re as _re
def _silence_clone(src):
    def _fix(m):
        call = m.group(0)
        if 'capture_output' in call:
            return call
        return call[:-1].rstrip() + ', capture_output=True, text=True)'
    return _re.sub(r"run\(\[[^\]]*git[^\]]*clone[^\]]*\]\)", _fix, src)
new_src = _silence_clone(new_src)

open(CUR, 'w').write(new_src)

if dropped:
    print("FSM: dropped disallowed functions from attempt:", ", ".join(dropped))
if added is None:
    print("FSM: WARNING - model did not write '" + task_func + "'")
print("FSM: rebuilt tasks.py with functions:", ", ".join(final.keys()))
PY
        # Log what the enforcer did.
        grep -q "FSM:" /tmp/ralph_prompt.txt 2>/dev/null || true

        # --- Check if model already marked task done via tool call ---
        if grep -q "\[DONE\] Task $TASK_NUM:" workspace/progress.md 2>/dev/null || grep -q "\[BLOCKED\] Task $TASK_NUM:" workspace/progress.md 2>/dev/null; then
            echo "=== Model marked task done/blocked via tool call ===" | tee -a "$LOGFILE"
            TASK_DONE=true
            continue
        fi

        # --- 4. validate via pytest ---
        echo "=== Running validation (pytest) ===" | tee -a "$LOGFILE"
        # Do NOT let `set -e` abort the script on a failing test; capture rc.
        # Validate ONLY the current task's doctests via -k, so a not-yet-finalized
        # function (e.g. main() written early) cannot block earlier tasks.
        # Reset PYTEST_RC each attempt so a stale non-zero value from a prior
        # failed attempt is not carried into a passing one.
        PYTEST_RC=0
        PYTEST_OUTPUT=$(python3 -m pytest --doctest-modules workspace/tasks.py -v --tb=short -k "$TASK_FUNC" 2>&1) || PYTEST_RC=$?
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
                python3 - "$TASK_FUNC" "$TASKS_PY_CONTENT" "$PYTEST_OUTPUT" <<'PY' || true
import sys
task_func = sys.argv[1]
tasks_py = sys.argv[2]
verify_out = sys.argv[3]
with open('/tmp/ralph_prompt.txt', 'a') as f:
    f.write("\n\nPREVIOUS ATTEMPT FAILED.\n")
    f.write(f"\n=== workspace/tasks.py ===\n{tasks_py}\n")
    f.write(f"\n=== test output (python3 -m pytest --doctest-modules workspace/tasks.py -v -k {task_func}) ===\n{verify_out}\n")
    f.write(f"\nFix the code and re-run: python3 -m pytest --doctest-modules workspace/tasks.py -v -k {task_func}\n")
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
