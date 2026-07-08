#!/usr/bin/env python3
import json
import sys
import os
import subprocess
from ollama import Client

WORKSPACE = "workspace"

# ── Bootstrap templates ──────────────────────────────────────────────
# Each task has a function template and a test template.
# On first run, these are written to workspace/ so pytest can validate.

TASK_TEMPLATES = {
    1: {
        "func": '''import subprocess
import os

def clone_repo():
    """Clone the simplesieve repo into workspace/. Skips if already cloned."""
    workspace = os.path.abspath(os.path.dirname(__file__))
    target = os.path.join(workspace, "simplesieve")
    if os.path.isdir(target):
        # Already cloned
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
    # -c flag prints count to stderr
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

_TEST_MAP = {
    1: "test_clone_repo",
    2: "test_get_project_dir",
    3: "test_build_program",
    4: "test_count_primes",
}


def bootstrap_files():
    """Create tasks.py and test_tasks.py from templates if they don't exist,
    or append the next task's function/test if they do exist but are incomplete."""
    tasks_py = os.path.join(WORKSPACE, "tasks.py")
    test_py = os.path.join(WORKSPACE, "test_tasks.py")

    # Read existing content
    existing_tasks = ""
    existing_tests = ""
    if os.path.isfile(tasks_py):
        with open(tasks_py) as f:
            existing_tasks = f.read()
    if os.path.isfile(test_py):
        with open(test_py) as f:
            existing_tests = f.read()

    # Find which tasks are already present
    for task_num in range(1, 5):
        func_marker = f"def {['clone_repo', 'get_project_dir', 'build_program', 'count_primes'][task_num-1]}("
        test_marker = f"def {_TEST_MAP[task_num]}("
        if func_marker not in existing_tasks:
            with open(tasks_py, "a") as f:
                f.write(f"\n\n{TASK_TEMPLATES[task_num]['func']}")
            print(f"[bootstrap] Added function for Task {task_num} to tasks.py")
        if test_marker not in existing_tests:
            with open(test_py, "a") as f:
                f.write(f"\n\n{TASK_TEMPLATES[task_num]['test']}")
            print(f"[bootstrap] Added test for Task {task_num} to test_tasks.py")


def run_pytest():
    """Run all pytest tests and return results."""
    test_file = os.path.join(WORKSPACE, "test_tasks.py")
    if not os.path.isfile(test_file):
        return {}
    try:
        result = subprocess.run(
            [sys.executable, "-m", "pytest", test_file, "-v", "--tb=short"],
            capture_output=True, text=True, timeout=120
        )
        print(result.stdout)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        
        # Parse which tests passed
        passed = {}
        for task_num, test_name in _TEST_MAP.items():
            passed[task_num] = f"{test_name} PASSED" in result.stdout
        return passed
    except Exception as e:
        print(f"Pytest error: {e}", file=sys.stderr)
        return {}


def update_progress(test_results):
    """Update progress.md based on pytest results."""
    progress_file = "progress.md"
    with open(progress_file) as f:
        lines = f.readlines()

    task_descriptions = {
        1: "Task 1: Clone repository",
        2: "Task 2: Navigate to project directory",
        3: "Task 3: Build the program",
        4: "Task 4: Count primes in first 1,000,000 natural numbers",
    }

    new_lines = []
    for line in lines:
        updated = False
        for task_num, desc in task_descriptions.items():
            if desc in line:
                if test_results.get(task_num, False):
                    new_lines.append(f"- [DONE] {desc}\n")
                else:
                    new_lines.append(f"- [TODO] {desc}\n")
                updated = True
                break
        if not updated:
            new_lines.append(line)

    with open(progress_file, "w") as f:
        f.writelines(new_lines)


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


def all_done():
    """Check if all tasks are marked DONE."""
    with open("progress.md") as f:
        content = f.read()
    return all(f"[DONE] Task {i}:" in content for i in range(1, 5))


def main():
    client = Client()

    # Step 1: Bootstrap Python files from templates
    print("=== Bootstrapping Python files ===")
    bootstrap_files()

    # Step 2: Run pytest to validate
    print("\n=== Running pytest ===")
    test_results = run_pytest()

    # Step 3: Update progress based on test results
    print("\n=== Updating progress ===")
    update_progress(test_results)
    with open("progress.md") as f:
        print(f.read())

    # Step 4: If all done, stop
    if all_done():
        print("\nALL TASKS COMPLETE")
        return

    # Step 5: Ask LLM for help if something failed
    failed_tasks = [n for n, p in test_results.items() if not p]
    if not failed_tasks:
        print("\nNo test results yet, or all passed. Done for this iteration.")
        return

    # Load prompt from filesystem
    system_prompt = load_prompt()

    # Load context for LLM
    context = {}
    for f in ["spec.md", "progress.md", f"{WORKSPACE}/tasks.py", f"{WORKSPACE}/test_tasks.py"]:
        try:
            with open(f) as fh:
                context[f] = fh.read()
        except FileNotFoundError:
            context[f] = ""

    failed_names = ", ".join(f"Task {n}" for n in failed_tasks)
    prompt = f"""{system_prompt}

The following pytest tests FAILED: {failed_names}

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

Fix the failing functions in tasks.py so that the tests pass. Do NOT change the test files.
Only change the function implementations in tasks.py.

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
        print("\n=== Re-running pytest after fix ===")
        test_results = run_pytest()
        update_progress(test_results)
        with open("progress.md") as f:
            print(f.read())

    except Exception as e:
        print(f"LLM error: {e}", file=sys.stderr)

    print("Agent step complete.")


if __name__ == "__main__":
    main()
