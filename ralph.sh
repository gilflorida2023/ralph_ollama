#!/bin/bash
# ralph.sh - Simple Ralph Wiggum loop for Ollama with exclusive get_next_task tool

set -euo pipefail

# Pin cwd to the script's directory (PROJECT_ROOT) so all relative paths used
# by the agent (workspace/simplesieve, workspace/test_tasks.py, prompt.md) and
# by the generated clone_repo() resolve deterministically against the project
# root, regardless of where this script is invoked from.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use the project's virtualenv (it has pytest and the ollama client) instead
# of the system python3, which lacks them.
if [ -f venv/bin/activate ]; then
    # shellcheck disable=SC1091
    source venv/bin/activate
fi

# Kill any PREVIOUS ralph.sh run still lingering (e.g. a stuck `--clean 50`
# from an earlier session). A leftover run holds the GPU/model and makes new
# Ollama chat calls hang indefinitely.
#
# IMPORTANT implementation notes (learned the hard way):
#  * Run this INLINE in the main shell. A `bash -c` / `timeout bash -c`
#    subshell would itself match `pgrep -f "ralph\.sh"` (its own cmdline
#    literally contains "ralph.sh") and kill ITSELF instead of the stale run.
#  * `pgrep -f "ralph\.sh"` ALSO matches our own launcher chain (the tool
#    shell, `timeout`, etc. all have "ralph.sh" in their command line). We must
#    skip $$ AND every ancestor (parent, grandparent, ...), otherwise we kill
#    the very shell that launched us and the run hangs.
#  * Do NOT use `pkill -P` here: it hangs in this environment. `ps --ppid` is
#    safe for listing children.
SELF=$$
# Collect $$ and all ancestor pids so we never kill our own launcher tree.
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
        kill "$cpid" 2>/dev/null || true   # its blocking ollama chat/pytest
    done
    kill "$pid" 2>/dev/null || true
done


MAX_ITERATIONS=50
VERBOSE=false
CLEAN=false
MODEL_NAME='qwen2.5:7b'
# Parse arguments. Accepts either order: `ralph.sh 3 -v` or `ralph.sh -v 3`.
# `--clean` forces a fresh `agent.py setup` (resets workspace); otherwise we
# continue an existing run and skip setup.
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

# Reset Ollama token accumulator for a fresh run
echo '{"calls":0,"prompt_tokens":0,"completion_tokens":0}' > /tmp/ralph_token_usage.json
# Record start epoch for elapsed-time reporting at loop exit
RALPH_START_EPOCH=$(date +%s)

# Print a summary (token usage + elapsed time) to stdout AND the log.
# Wrapped in a function + EXIT trap so it also fires if the run is
# interrupted (e.g. Ctrl-C), not just on a clean loop completion.
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
    elapsed_str = f"T{h}:{m:02d}:{s:02d}"
elif m:
    elapsed_str = f"T{m}:{s:02d}"
else:
    elapsed_str = f"T{s}"

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

# Setup workspace from spec.md. By default we CONTINUE an existing run and
# skip setup (so progress is preserved). Use --clean to force a fresh setup.
if [ "$CLEAN" = true ]; then
    echo "=== Clean start: running agent.py setup ==="
    python3 agent.py setup
elif [ -f workspace/tasks.json ]; then
    echo "=== Continuing existing run (skipping agent.py setup) ==="
else
    echo "=== No existing workspace/tasks.json found; running agent.py setup ==="
    python3 agent.py setup
fi

# Ensure workspace/ has its OWN git repo to snapshot agent artifacts
# (the cloned upstream repo and caches are ignored so they are never tracked).
if [ ! -d workspace/.git ]; then
    git -C workspace init -q
    printf 'simplesieve/\n__pycache__/\n.pytest_cache/\n' > workspace/.gitignore
fi

# Create an initial baseline commit so discard-on-start always has a HEAD to
# revert to (otherwise a crashed session's partial files would persist).
git -C workspace add -A
git -C workspace commit -q -m "setup: fresh workspace" || true

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
            if [[ "$NEXT_TASK_JSON" == *'"done": true'* ]]; then
                echo "Result indicates DONE" | tee -a "$LOGFILE"
            elif [[ "$NEXT_TASK_JSON" == *'"num":'* ]]; then
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

        # Discard unfinished changes left by a previous (crashed/interrupted)
        # session, but ONLY if the workspace repo already has a committed
        # baseline to revert to. We communicate what was tried first.
        if git -C workspace rev-parse -q --verify HEAD >/dev/null 2>&1; then
            if git -C workspace status --porcelain | grep -q .; then
                echo "=== Discarding unfinished changes from previous session for Task $TASK_NUM ===" | tee -a "$LOGFILE"
                echo "--- code that was tried (diff vs last committed baseline) ---" | tee -a "$LOGFILE"
                git -C workspace diff | tee -a "$LOGFILE"
                git -C workspace log --oneline -3 | tee -a "$LOGFILE"
                git -C workspace checkout -- .
                # -fdx (not -fd) so gitignored dirs like workspace/simplesieve/
                # are also removed between iterations; otherwise stale clones
                # persist and clone_repo() re-clones every time.
                git -C workspace clean -fdx
                echo "=== Reverted to last committed baseline ===" | tee -a "$LOGFILE"
            fi
        fi

        # Safety net: remove any stray clone that landed at the project root
        # (a clone_repo that omitted the explicit workspace/simplesieve target
        # would create ./simplesieve here instead of ./workspace/simplesieve).
        # The legitimate clone always lives in workspace/simplesieve.
        if [ -e simplesieve ]; then
            echo "=== Removing stray project-root clone ./simplesieve ===" | tee -a "$LOGFILE"
            rm -rf simplesieve
        fi

        # Build the prompt for the task and write to /tmp/ralph_prompt.txt
        python3 - "$NEXT_TASK_JSON" <<'PY'
import json, sys, os

task = json.loads(sys.argv[1])

with open('prompt.md') as f:
    system = f.read().strip()

# Accumulated lessons from previous runs (the self-improving knowledge base).
lessons_path = 'workspace/lessons.md'
lessons = ''
if os.path.isfile(lessons_path):
    with open(lessons_path) as f:
        lessons = f.read().strip()

prompt = f'''{system}

'''

if lessons:
    prompt += f'''## Lessons learned from previous tasks (apply these!)
{lessons}

'''

prompt += f'''Implement this task: Task {task['num']}: {task['title']}

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

The tools available are: read_file, write_file, run_command, update_progress, get_next_task, debrief_task

Recommendation: First check if the function exists in tasks.py (use read_file), then if not create it (use write_file)
'''

with open('/tmp/ralph_prompt.txt', 'w') as f:
    f.write(prompt)
PY

        # ---- LLM call + parse + execute with inner retry loop ----
        MAX_CODE_ATTEMPTS=10
        ATT=0
        TASK_DONE=false
        TASK_FAILED=false
        while [ "$ATT" -lt "$MAX_CODE_ATTEMPTS" ] && [ "$TASK_DONE" != "true" ] && [ "$TASK_FAILED" != "true" ]; do
            ATT=$((ATT + 1))

            # If this is a retry, failure feedback (full current code + pytest
            # output) is appended after pytest runs, in the failure block below.
            # No name-only feedback here.

            # If this is the final attempt and the test failed, mark as BLOCKER
            if [ "$ATT" -eq "$MAX_CODE_ATTEMPTS" ] && [ -n "$PYTEST_OUTPUT" ]; then
                echo "=== Task failed after $MAX_CODE_ATTEMPTS attempts, marking as BLOCKER ===" | tee -a "$LOGFILE"
                python3 agent.py execute mark_task "{\"num\":$TASK_NUM,\"state\":\"blocked\"}" >> "$LOGFILE" 2>&1
                TASK_FAILED=true
            fi

            # Log the prompt sent to Ollama
            if [ "$VERBOSE" = true ]; then
                echo "=== DEBUG: Prompt sent to Ollama (attempt $ATT) ===" | tee -a "$LOGFILE"
                cat /tmp/ralph_prompt.txt | tee -a "$LOGFILE"
                echo "=== END PROMPT ===" | tee -a "$LOGFILE"
            fi

            # Call LLM via Ollama API (curl + jq for raw token stats)
            PROMPT_RESPONSE=$(
              jq -Rs --arg model "${MODEL_NAME}" \
                '{model: $model, messages: [{role: "user", content: .}], format: "json", stream: false, options: {temperature: 0.7}}' \
                /tmp/ralph_prompt.txt \
              | curl -s http://localhost:11434/api/chat -d @- \
              | tee /tmp/ralph_last_response.json \
              | jq -r '.message.content // ""'
            )

            # Accumulate token usage
            if [ -f /tmp/ralph_token_usage.json ]; then
              python3 - /tmp/ralph_token_usage.json /tmp/ralph_last_response.json <<'PY' || true
import json, sys
with open(sys.argv[1]) as a_f, open(sys.argv[2]) as r_f:
    a = json.load(a_f)
    r = json.load(r_f)
a['calls'] += 1
a['prompt_tokens'] += r.get('prompt_eval_count', 0)
a['completion_tokens'] += r.get('eval_count', 0)
json.dump(a, open(sys.argv[1], 'w'))
PY
            fi

            # Log raw response
            if [ "$VERBOSE" = true ]; then
                echo "=== DEBUG: Raw Ollama response (attempt $ATT) ===" | tee -a "$LOGFILE"
                echo "$PROMPT_RESPONSE" | tee -a "$LOGFILE"
                echo "=== END RESPONSE ===" | tee -a "$LOGFILE"
            else
                echo "LLM response: $PROMPT_RESPONSE" >> "$LOGFILE"
            fi

            # Robust parse and execute tool calls
            python3 - "$PROMPT_RESPONSE" <<'PY' 2>&1
import json, subprocess, sys

raw = sys.argv[1] if len(sys.argv) > 1 else ""

def normalize_tool_calls(raw):
    try:
        r = json.loads(raw)
    except json.JSONDecodeError as e:
        # malformed JSON -> caller should retry (nothing to execute)
        return [], f"JSON decode error: {e}"
    # Extract tool calls, tolerant of variations
    tool_calls = r.get('tool_calls', [])
    if not tool_calls:
        # Possibly old format: top-level tool/tool_to_use/action
        tool_name = r.get('tool') or r.get('tool_to_use') or r.get('action')
        if tool_name and tool_name not in ('done', 'write_function', 'write_test', 'run_pytest', 'get_next_task'):
            args = {k: v for k, v in r.items() if k not in ('tool', 'tool_to_use', 'action', 'reasoning', 'next_progress_update')}
            tool_calls = [{'name': tool_name, 'args': args}]
    # Normalize key names
    normalized = []
    for call in tool_calls:
        if not isinstance(call, dict):
            # skip bogus entry
            print(f"SKIP (not dict): {call}")
            continue
        name = call.get('name') or call.get('function') or call.get('tool') or ''
        if not name:
            # skip nameless entry
            print(f"SKIP (nameless): {call}")
            continue
        # Map legacy tool names
        if name == 'run_shell' or name == 'shell':
            name = 'run_command'
        args = call.get('args') or call.get('parameters') or {}
        normalized.append({'name': name, 'args': args})
    if not normalized:
        # No valid calls to execute
        return [], "No valid tool calls"
    return normalized, None

# Parse
normalized, err = normalize_tool_calls(raw)
if err:
    print(f"PARSE ERROR: {err}")
    sys.exit(0)

# Execute each call, echoing the name and args for logs
for call in normalized:
    name = call['name']
    args = call['args']
    args_json = json.dumps(args)
    # Logging: show normalized name and args
    print(f"Tool: {name}({json.dumps(args)})")
    result = subprocess.run(['python3', 'agent.py', 'execute', name, args_json], capture_output=True, text=True, timeout=130)
    output = result.stdout.strip()
    print(f'  -> {output[:200]}')

print('Step complete.')
PY

            # --- Post-write merge: protect done functions from overwrite ---
            # The model tends to rewrite tasks.py / test_tasks.py with ONLY the
            # current function, deleting all previously done work. Merge the
            # model's version of the current task back into the last committed
            # version (which holds every done function + its imports). Runs on
            # every attempt so done code can never be lost.
            python3 - "$TASK_FUNC" "$TASK_TEST" <<'PY' || true
import subprocess, sys

func_target = sys.argv[1]
test_target = sys.argv[2]

def git_show(path):
    r = subprocess.run(['git', 'show', f'HEAD:{path}'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return r.stdout

def top_level_func_lines(code, name):
    """Return lines of top-level def `name` from `code`, or None."""
    lines = code.split('\n')
    out = []
    in_func = False
    indent = None
    for line in lines:
        s = line.lstrip()
        if s.startswith(f'def {name}('):
            in_func = True
            indent = len(line) - len(s)
            out.append(line)
        elif in_func:
            if s.startswith('def ') and len(line) - len(s) <= indent:
                break
            out.append(line)
    return out if out else None

def remove_top_level_func(lines, name):
    """Return list of lines with top-level def `name` removed."""
    out = []
    in_func = False
    indent = None
    for line in lines:
        s = line.lstrip()
        if s.startswith(f'def {name}('):
            in_func = True
            indent = len(line) - len(s)
            continue
        elif in_func:
            if s.startswith('def ') and len(line) - len(s) <= indent:
                in_func = False
                out.append(line)
            continue
        out.append(line)
    return out

def is_import(line):
    return line.strip().startswith(('import ', 'from '))

def merge_file(path, target):
    if not target:
        return
    committed = git_show(path)
    if committed is None:
        # No committed version yet (first task) - nothing to protect
        return
    try:
        with open(path) as f:
            model = f.read()
    except FileNotFoundError:
        return

    committed_lines = committed.split('\n')
    model_lines = model.split('\n')

    # Base = committed code minus the target function
    base_lines = remove_top_level_func(committed_lines, target)

    # Keep all committed imports, add any new ones the model introduced
    committed_imports = [l for l in committed_lines if is_import(l)]
    committed_import_set = set(committed_imports)
    new_imports = [l for l in model_lines if is_import(l) and l not in committed_import_set]

    # Insert new imports right after the last existing import line
    last_imp = -1
    for i, l in enumerate(base_lines):
        if is_import(l):
            last_imp = i
    for ni in new_imports:
        base_lines.insert(last_imp + 1, ni)
        last_imp += 1

    # Extract the model's (or committed) version of the target function
    target_lines = top_level_func_lines(model, target)
    if not target_lines:
        target_lines = top_level_func_lines(committed, target) or []

    # Drop trailing blank lines, then append the target function
    while base_lines and base_lines[-1].strip() == '':
        base_lines.pop()
    if target_lines:
        base_lines.append('')
        base_lines.append('')
        base_lines.extend(target_lines)

    with open(path, 'w') as f:
        f.write('\n'.join(base_lines) + '\n')
    print(f"Merged {path}: preserved done functions, kept '{target}' from model")

merge_file('workspace/tasks.py', func_target)
merge_file('workspace/test_tasks.py', test_target)
PY

            # Run pytest verification
            echo "=== Running verification ===" | tee -a "$LOGFILE"
            PYTEST_OUTPUT=$(python3 -m pytest workspace/test_tasks.py -k "$TASK_TEST" -v 2>&1 || true)
            echo "$PYTEST_OUTPUT" | tee -a "$LOGFILE"

            if echo "$PYTEST_OUTPUT" | grep -q "PASSED"; then
                echo "=== Test passed, marking task DONE ===" | tee -a "$LOGFILE"
                python3 agent.py execute mark_task "{\"num\":$TASK_NUM,\"state\":\"done\"}" >> "$LOGFILE" 2>&1
                # Snapshot the successful state in the workspace git repo
                git -C workspace add -A
                git -C workspace commit -q -m "Task $TASK_NUM: $TASK_TITLE done" || true
                TASK_DONE=true
            else
                echo "=== Test failed, adding feedback and retrying ===" | tee -a "$LOGFILE"

                # Capture current code for richer feedback
                TASKS_PY_CONTENT="$(cat workspace/tasks.py 2>/dev/null || echo '')"
                TESTS_PY_CONTENT="$(cat workspace/test_tasks.py 2>/dev/null || echo '')"
                python3 - "$TASK_FUNC" "$TASK_TEST" "$TASKS_PY_CONTENT" "$TESTS_PY_CONTENT" "$PYTEST_OUTPUT" <<'PY'
import sys
task_func = sys.argv[1]
task_test = sys.argv[2]
tasks_py = sys.argv[3]
tests_py = sys.argv[4]
pytest_out = sys.argv[5]
with open('/tmp/ralph_prompt.txt','a') as f:
    f.write("\n\nPREVIOUS ATTEMPT FAILED. Here is the full current code:\n")
    f.write(f"\n=== workspace/tasks.py ===\n{tasks_py}\n")
    if task_test:
        f.write(f"\n=== workspace/test_tasks.py ===\n{tests_py}\n")
    f.write(f"\n=== pytest output ===\n{pytest_out}\n")
    f.write("\nFix the code and re-run pytest.\n")
PY
            fi
        done

            # BLOCKER fallback: if the model never called debrief_task on its
            # final attempt (it can't know it was the last), auto-record a
            # concise debrief from the final error so the lesson is not lost.
            if [ "$TASK_FAILED" = true ] && ! echo "$PROMPT_RESPONSE" | grep -q "debrief_task"; then
                echo "=== Auto-recording blocker debrief for Task $TASK_NUM ===" | tee -a "$LOGFILE"
                python3 - "$TASK_NUM" "$PYTEST_OUTPUT" <<'PY' >> "$LOGFILE" 2>&1
import sys
from agent import execute_debrief_task
num = int(sys.argv[1])
err = sys.argv[2][-800:]
msg = f"Task exhausted all attempts without passing. Final pytest error:\n{err}"
print(execute_debrief_task({"task_num": num, "what_was_confusing": msg,
                             "suggested_rule_for_prompt": "", "suggested_spec_clarification": ""}))
PY
            fi
    fi

    sleep 1
done

echo "Ralph loop ended after $ITER iterations."
