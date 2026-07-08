#!/usr/bin/env python3
import json
import sys
import os
import subprocess
from ollama import Client

WORKSPACE = "workspace"

TASK_TEMPLATES = {
    1: {
        "func": '''import subprocess
import os

def clone_repo():
    """Clone the simplesieve repo into workspace/. Skips if already cloned."""
    workspace = os.path.abspath(os.path.dirname(__file__))
    target = os.path.join(workspace, "simplesieve")
    if os.path.isdir(target):
        class Result:
            returncode = 0
            stderr = ""
            stdout = ""
        return Result()
    result = subprocess.run(
        ["git", "clone", "https://github.com/gilflorida2023/simplesieve"],
        cwd=workspace,
        capture_output=True, text=True
    )
    return result
''',
        "test": '''import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "workspace"))
from tasks import clone_repo

def test_clone_repo():
    result = clone_repo()
    assert result.returncode == 0, f"git clone failed: {result.stderr}"
    assert os.path.isdir(os.path.join(os.path.dirname(__file__), "..", "workspace", "simplesieve")), \\
        "Directory workspace/simplesieve does not exist"
''',
    },
    2: {
        "func": '''import os

def get_project_dir():
    """Return the absolute path to the simplesieve project directory."""
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "simplesieve"))
''',
        "test": '''import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "workspace"))
from tasks import get_project_dir

def test_get_project_dir():
    path = get_project_dir()
    assert os.path.isdir(path), f"Path does not exist: {path}"
    assert path.endswith("simplesieve"), f"Path does not end with simplesieve: {path}"
''',
    },
    3: {
        "func": '''import subprocess
import os

def build_program():
    """Build simplesieve using go build."""
    project_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "simplesieve"))
    result = subprocess.run(
        ["go", "build", "-o", "simplesieve"],
        cwd=project_dir,
        capture_output=True, text=True
    )
    return result
''',
        "test": '''import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "workspace"))
from tasks import build_program, get_project_dir

def test_build_program():
    result = build_program()
    assert result.returncode == 0, f"go build failed: {result.stderr}"
    exe = os.path.join(get_project_dir(), "simplesieve")
    assert os.path.isfile(exe), f"Executable not found: {exe}"
    assert os.access(exe, os.X_OK), f"File is not executable: {exe}"
''',
    },
    4: {
        "func": '''import subprocess
import os

def count_primes():
    """Run simplesieve -c --limit 1e6 and return the output.
    Note: simplesieve -c prints the count to stderr."""
    project_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "simplesieve"))
    result = subprocess.run(
        ["./simplesieve", "-c", "--limit", "1e6"],
        cwd=project_dir,
        capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(f"simplesieve failed: {result.stderr}")
    output = result.stderr.strip() if result.stderr.strip() else result.stdout.strip()
    return output
''',
        "test": '''import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "workspace"))
from tasks import count_primes

def test_count_primes():
    output = count_primes()
    assert "78498" in output, f"Expected '78498' in output, got: {output}"
''',
    },
}

FUNC_NAMES = {1: "clone_repo", 2: "get_project_dir", 3: "build_program", 4: "count_primes"}
_TEST_MAP = {1: "test_clone_repo", 2: "test_get_project_dir", 3: "test_build_program", 4: "test_count_primes"}
TASK_DESCRIPTIONS = {
    1: "Task 1: Clone repository",
    2: "Task 2: Navigate to project directory",
    3: "Task 3: Build the program",
    4: "Task 4: Count primes in first 1,000,000 natural numbers",
}


def load_prompt():
    """Load the LLM system prompt from prompt.md. Raises error if missing."""
    path = os.path.join(os.path.dirname(__file__), "prompt.md")
    if not os.path.isfile(path):
        raise FileNotFoundError(
            f"prompt.md not found at {path}. "
            "This file is required — it contains the LLM system prompt."
        )
    with open(path) as f:
        return f.read()


def get_progress_path():
    """Return the path to progress.md inside the workspace."""
    return os.path.join(WORKSPACE, "progress.md")


def init_progress():
    """Create progress.md in workspace with all tasks marked TODO if it doesn't exist."""
    os.makedirs(WORKSPACE, exist_ok=True)
    progress_path = get_progress_path()
    if not os.path.isfile(progress_path):
        lines = [f"- [TODO] {TASK_DESCRIPTIONS[i]}\n" for i in range(1, 5)]
        with open(progress_path, "w") as f:
            f.writelines(lines)
        print(f"[init] Created {progress_path}")


def find_next_task():
    """Find the first task marked [TODO] in progress.md. Returns task number or None."""
    with open(get_progress_path()) as f:
        content = f.read()
    for task_num in range(1, 5):
        if f"[TODO] Task {task_num}:" in content:
            return task_num
    return None


def all_done():
    """Check if all tasks are marked DONE."""
    with open(get_progress_path()) as f:
        content = f.read()
    return all(f"[DONE] Task {i}:" in content for i in range(1, 5))


def bootstrap_next_task(task_num):
    """Add the function and test for a single task to workspace files."""
    os.makedirs(WORKSPACE, exist_ok=True)
    tasks_py = os.path.join(WORKSPACE, "tasks.py")
    test_py = os.path.join(WORKSPACE, "test_tasks.py")

    existing_tasks = ""
    existing_tests = ""
    if os.path.isfile(tasks_py):
        with open(tasks_py) as f:
            existing_tasks = f.read()
    if os.path.isfile(test_py):
        with open(test_py) as f:
            existing_tests = f.read()

    func_marker = f"def {FUNC_NAMES[task_num]}("
    test_marker = f"def {_TEST_MAP[task_num]}("

    if func_marker not in existing_tasks:
        with open(tasks_py, "a") as f:
            f.write(f"\n\n{TASK_TEMPLATES[task_num]['func']}")
        print(f"[bootstrap] Added function for Task {task_num} to tasks.py")

    if test_marker not in existing_tests:
        with open(test_py, "a") as f:
            f.write(f"\n\n{TASK_TEMPLATES[task_num]['test']}")
        print(f"[bootstrap] Added test for Task {task_num} to test_tasks.py")


def run_pytest_for_task(task_num):
    """Run pytest for a single task. Returns True if passed."""
    test_file = os.path.join(WORKSPACE, "test_tasks.py")
    if not os.path.isfile(test_file):
        return False
    test_name = _TEST_MAP[task_num]
    try:
        result = subprocess.run(
            [sys.executable, "-m", "pytest", test_file, "-k", test_name, "-v", "--tb=short"],
            capture_output=True, text=True, timeout=120
        )
        print(result.stdout)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        return f"{test_name} PASSED" in result.stdout
    except Exception as e:
        print(f"Pytest error: {e}", file=sys.stderr)
        return False


def update_progress(task_num, passed):
    """Update progress.md for a single task."""
    progress_path = get_progress_path()
    with open(progress_path) as f:
        lines = f.readlines()

    desc = TASK_DESCRIPTIONS[task_num]
    new_lines = []
    for line in lines:
        if desc in line:
            new_lines.append(f"- [{'DONE' if passed else 'TODO'}] {desc}\n")
        else:
            new_lines.append(line)

    with open(progress_path, "w") as f:
        f.writelines(new_lines)


def main():
    client = Client()

    # Ensure progress.md exists in workspace
    init_progress()

    # Step 1: Find the next task to work on
    task_num = find_next_task()
    if task_num is None:
        print("ALL TASKS COMPLETE")
        return

    print(f"=== Working on Task {task_num}: {TASK_DESCRIPTIONS[task_num]} ===")

    # Step 2: Bootstrap that one task's function and test
    print("\n=== Bootstrapping ===")
    bootstrap_next_task(task_num)

    # Step 3: Run pytest for this task
    print(f"\n=== Running pytest for Task {task_num} ===")
    passed = run_pytest_for_task(task_num)

    # Step 4: Update progress
    update_progress(task_num, passed)
    with open(get_progress_path()) as f:
        print(f.read())

    if passed:
        print(f"Task {task_num} PASSED")
        return

    # Step 5: Task failed — ask LLM for help
    print(f"\nTask {task_num} FAILED — asking LLM for help")

    system_prompt = load_prompt()

    context = {}
    for fname in [f"{WORKSPACE}/tasks.py", f"{WORKSPACE}/test_tasks.py", "spec.md"]:
        try:
            with open(fname) as fh:
                context[fname] = fh.read()
        except FileNotFoundError:
            context[fname] = ""

    prompt = f"""{system_prompt}

Task {task_num} FAILED: {TASK_DESCRIPTIONS[task_num]}

CURRENT tasks.py:
```python
{context.get(f'{WORKSPACE}/tasks.py', '# file not found')}
```

CURRENT test_tasks.py:
```python
{context.get(f'{WORKSPACE}/test_tasks.py', '# file not found')}
```

SPEC:
{context.get('spec.md', '')}

Fix the function for Task {task_num} in tasks.py so that the test passes. Do NOT change the test files.
Only change the function implementation in tasks.py.

Respond in JSON:
{{
  "reasoning": "what's wrong and how to fix it",
  "tool_calls": [{{"name": "write_file", "args": {{"path": "workspace/tasks.py", "content": "<fixed content>"}}}}]
}}"""

    response = client.chat(
        model="qwen2.5:7b",
        messages=[{"role": "user", "content": prompt}],
        tools=[{
            "type": "function",
            "function": {
                "name": "write_file",
                "description": "Write content to a file",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": {"type": "string"},
                        "content": {"type": "string"}
                    },
                    "required": ["path", "content"]
                }
            }
        }],
        format="json",
        options={"temperature": 0.3}
    )

    try:
        content = response['message']['content']
        print("LLM RESPONSE:", content[:500], file=sys.stderr)
        result = json.loads(content)
        print("Reasoning:", result.get("reasoning"))

        for call in result.get("tool_calls", []):
            name = call.get("name")
            args = {k: v.replace("\\n", "\n").replace("\\t", "\t") if isinstance(v, str) else v
                    for k, v in call.get("args", {}).items()}
            if name == "write_file":
                path = os.path.join(WORKSPACE, os.path.basename(args.get("path", "")))
                os.makedirs(WORKSPACE, exist_ok=True)
                with open(path, "w") as f:
                    f.write(args.get("content", ""))
                print(f"Wrote {path}")

        # Re-run pytest after LLM fix
        print(f"\n=== Re-running pytest for Task {task_num} ===")
        passed = run_pytest_for_task(task_num)
        update_progress(task_num, passed)
        with open(get_progress_path()) as f:
            print(f.read())

        if passed:
            print(f"Task {task_num} PASSED after LLM fix")
        else:
            print(f"Task {task_num} STILL FAILED — will retry next iteration")

    except Exception as e:
        print(f"LLM error: {e}", file=sys.stderr)

    print("Agent step complete.")


if __name__ == "__main__":
    main()
