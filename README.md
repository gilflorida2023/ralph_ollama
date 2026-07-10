# Ralph — Autonomous Agent Loop for Ollama

An autonomous Python agent that reads a task spec, executes tasks, validates them with **doctest** (via pytest), and tracks progress. Uses a local Ollama LLM (`qwen2.5-coder:7b`) to decide what to do.

## How it works

1. **`spec.md`** defines tasks in English (function signatures, requirements, doctest examples)
2. **`ralph.sh`** runs `agent.py` in a loop (up to 50 iterations)
3. **`agent.py`** bootstraps `workspace/tasks.py` from `spec.md`, runs pytest with `--doctest-modules`, and auto-updates `progress.md`
4. If tests fail, the LLM is asked to debug and fix the code (inner retry loop up to 10 attempts, feeding back generated code and test failures)
5. The loop stops when all 4 tasks are `[DONE]` in `progress.md`

## Key change: Doctest-based validation

- Each task function includes `>>>` doctest examples in its docstring
- Validation runs: `python3 -m pytest --doctest-modules workspace/tasks.py -v`
- No separate `test_*` functions needed — the docstring IS the test
- Single file: `workspace/tasks.py` contains implementations + doctests + `main()`

### Session isolation (git snapshots)

`workspace/` is its own git repo (the cloned upstream repo `simplesieve/` and caches are gitignored). This prevents conflicts between runs/sessions:

- When a task is marked `[DONE]`, `ralph.sh` commits the agent artifacts (`tasks.py`, `progress.md`, `tasks.json`) as a known-good baseline
- At the start of each task, any **uncommitted** changes (leftover from a crashed/interrupted session) are logged (diff + recent log) and then discarded, reverting to the last committed baseline — so a failed attempt can never poison the next run
- `clone_repo` is idempotent: if `workspace/simplesieve` already exists it is removed before `git clone`, so a pre-existing clone never makes the clone fail

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
| `spec.md` | Task specification — English descriptions with function signatures + doctest requirements |
| `prompt.md` | LLM system prompt (loaded by agent.py) |
| `agent.py` | Main agent — parses spec, bootstraps tasks.py, runs pytest --doctest-modules, asks LLM for help if needed |
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

- `workspace/tasks.py` — Python functions (one per task) with embedded doctests
- `workspace/simplesieve/` — cloned repo (built by the agent)

The `workspace/` directory is gitignored.

## Model compatibility

Ralph requires a model that can (1) emit **structured JSON tool-calls** (`{"tool_calls": [{"name": ..., "args": ...}]}`), (2) generate **Python with `>>>` doctests**, and (3) **self-correct** failing tests from feedback. Models below were tried and found **insufficient** for the Ralph loop:

| Model | Why it failed for Ralph |
|-------|-------------------------|
| `granite4.1:8b` | Too weak at self-correcting doctests. On Task 2 it repeatedly wrote `re` inside a doctest without `import re` and could not fix it across 6+ retries, exhausting the attempt budget. |
| `lfm2.5:8b` | Cannot follow the JSON tool-call schema. Emits `write_file({})` with an empty `args` object, so no code is ever written and validation reports "no tests ran". |
| `granite3.2-vision:2b` | Multimodal/vision model — wrong modality for a text/code agent task. |
| `qwen3-vl:8b` | Multimodal/vision model — wrong modality for text/code generation. |
| `deepseek-r1:1.5b` | Too small (<2B) to sustain structured JSON output plus Python/doctest generation. |
| `opencoder:1.5b` | Too small (<2B) for reliable JSON + code generation. |
| `qwen2.5-coder:1.5b` | Too small to reliably generate correct doctests. |
| `qwen2.5:0.5b` | Far too small for this task. |
| `qwen3:1.7b` | Too small; struggles to keep valid JSON and working code simultaneously. |
| `deepseek-r1:8b` | Chain-of-thought reasoning floods the response with `<think:6124c78e>` text, which fights the JSON parser and is extremely slow per call. |
| `deepseek-r1:7b` | Same CoT verbosity / slowness problem as the 8b variant. |
| `qwen2.5-coder:3b` | Borderline — the 7b works well, but 3b frequently produces broken doctests. |

**Recommended:** `qwen2.5-coder:7b` — purpose-built for code, reliably produces the JSON tool-calls and doctests Ralph needs, and has carried the run through all five tasks. General 7–9B models (`qwen2.5:7b`, `qwen3:8b`, `qwen3:4b`, `glm4:9b`, `llama3.1:8b`) are also plausible alternatives.
