# Ralph — Autonomous Agent Loop for Ollama

An autonomous Python agent that reads a task spec, executes tasks, validates them with pytest, and tracks progress. Uses a local Ollama LLM (`qwen2.5:7b`) to decide what to do.

## How it works

1. **`spec.md`** defines the tasks (markdown with function signatures and pytest tests)
2. **`ralph.sh`** runs `agent.py` in a loop (up to 50 iterations)
3. **`agent.py`** bootstraps `workspace/tasks.py` and `workspace/test_tasks.py` from templates, runs pytest, and auto-updates `progress.md`
4. If tests fail, the LLM is asked to debug and fix the code (with inner retry loop up to 10 attempts, feeding back generated code and test failures to improve the fix)
5. The loop stops when all 4 tasks are `[DONE]` in `progress.md`

### Session isolation (git snapshots)

`workspace/` is its own git repo (the cloned upstream repo `simplesieve/` and caches are gitignored). This prevents conflicts between runs/sessions:

- When a task is marked `[DONE]`, `ralph.sh` commits the agent artifacts (`tasks.py`, `test_tasks.py`, `progress.md`, `tasks.json`) as a known-good baseline.
- At the start of each task, any **uncommitted** changes (leftover from a crashed/interrupted session) are logged (diff + recent log) and then discarded, reverting to the last committed baseline — so a failed attempt can never poison the next run.
- `clone_repo` is idempotent: if `workspace/simplesieve` already exists it is removed before `git clone`, so a pre-existing clone never makes the clone fail.

## Quick start

```bash
# Install dependencies (from the venv)
source venv/bin/activate
pip install -r requirements.txt

# Run once (bootstrap + validate)
python3 agent.py

# Run in loop mode
./ralph.sh

# Run with custom max iterations
./ralph.sh 10
```

## Files

| File | Purpose |
|------|---------|
| `spec.md` | Task specification — defines functions to write and pytest tests |
| `prompt.md` | LLM system prompt (loaded by agent.py) |
| `agent.py` | Main agent — bootstraps files, runs pytest, asks LLM for help if needed |
| `ralph.sh` | Bash loop runner with logging |
| `progress.md` | Tracks task completion status |
| `requirements.txt` | Python dependencies (`ollama`, `pytest`) |

## Tool calls

The LLM can call these 6 tools defined in `agent.py`:

- **`read_file`** — read a project file (`{"path": ...}`)
- **`write_file`** — write a file (`{"path": ..., "content": ...}`)
- **`run_command`** — run a shell command (`{"cmd": ...}`), blocks dangerous commands
- **`update_progress`** — mark a task done/TODO (`{"num": ..., "state": "done"/"todo"}`)
- **`get_next_task`** — return the next pending task
- **`mark_task`** — mark a task done/blocked (`{"num": ..., "state": "done"}`)

The LLM emits tool calls as a JSON object with a `tool_calls` array: `{"tool_calls": [{"name": "...", "args": {...}}]}`. `ralph.sh` normalizes legacy names (e.g., `run_shell` → `run_command`) and handles malformed JSON gracefully. With `-v/--verbose`, you also see the Ollama prompt and raw response.

## Workspace

`workspace/` is the agent's sandbox. All generated files go there:

- `workspace/tasks.py` — Python functions (one per task)
- `workspace/test_tasks.py` — pytest tests (one per task)
- `workspace/simplesieve/` — cloned repo (built by the agent)

The `workspace/` directory is gitignored.
