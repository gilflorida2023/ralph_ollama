#!/usr/bin/env python3
import json
import re
import sys
import os
import subprocess
import shlex

PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
WORKSPACE = os.path.join(PROJECT_ROOT, "workspace")
SPEC_PATH = os.path.join(PROJECT_ROOT, "spec.md")
TASKS_JSON = os.path.join(WORKSPACE, "tasks.json")
PROGRESS_PATH = os.path.join(WORKSPACE, "progress.md")


def parse_spec():
    with open(SPEC_PATH) as f:
        content = f.read()
    sections = content.split("---")
    tasks = []
    for section in sections:
        m = re.search(r"## Task (\d+):\s*(.+)", section)
        if not m:
            continue
        num = int(m.group(1))
        title = m.group(2).strip()
        func_m = re.search(r"\*\*Function:\*\*\s*`(\w+)\(\)`", section)
        test_m = re.search(r"\*\*Test:\*\*\s*`(\w+)\(\)`", section)
        val_m = re.search(r"\*\*Validation:\*\*\s*(.+)", section)
        func_name = func_m.group(1) if func_m else ""
        test_name = test_m.group(1) if test_m else ""
        validation = val_m.group(1).strip() if val_m else ""
        func_code = ""
        tc = re.search(r"```python\s*\n(.*?)```", section, re.DOTALL)
        if tc:
            func_code = tc.group(1).strip()
        test_code = ""
        all_blocks = re.findall(r"```python\s*\n(.*?)```", section, re.DOTALL)
        if len(all_blocks) > 1:
            test_code = all_blocks[1].strip()
        tasks.append({
            "num": num,
            "title": title,
            "func": func_name,
            "test": test_name,
            "validation": validation,
            "func_code": func_code,
            "test_code": test_code,
        })
    tasks.sort(key=lambda t: t["num"])
    return tasks


def setup():
    os.makedirs(WORKSPACE, exist_ok=True)
    tasks = parse_spec()
    with open(TASKS_JSON, "w") as f:
        json.dump(tasks, f, indent=2)
    lines = []
    for t in tasks:
        lines.append(f"- [TODO] Task {t['num']}: {t['title']}\n")
    with open(PROGRESS_PATH, "w") as f:
        f.writelines(lines)
    print(f"Setup complete: {TASKS_JSON}, {PROGRESS_PATH}")


def load_tasks():
    with open(TASKS_JSON) as f:
        return json.load(f)


def load_progress():
    if not os.path.isfile(PROGRESS_PATH):
        return {}
    with open(PROGRESS_PATH) as f:
        content = f.read()
    result = {}
    for t in load_tasks():
        done_marker = f"[DONE] Task {t['num']}:"
        blocked_marker = f"[BLOCKED] Task {t['num']}:"
        result[t["num"]] = (done_marker in content) or (blocked_marker in content)
    return result


def find_next_task():
    progress = load_progress()
    for t in load_tasks():
        if not progress.get(t["num"], False):
            return t
    return None


def next_task():
    t = find_next_task()
    if t is None:
        print(json.dumps({"done": True}))
    else:
        print(json.dumps(t))


def next_action():
    t = find_next_task()
    if t is None:
        print(json.dumps({"action": "done"}))
        return

    tasks_path = os.path.join(WORKSPACE, "tasks.py")
    tests_path = os.path.join(WORKSPACE, "test_tasks.py")

    func_in_file = False
    if os.path.isfile(tasks_path):
        with open(tasks_path) as f:
            func_in_file = f"def {t['func']}(" in f.read()

    test_in_file = False
    if os.path.isfile(tests_path):
        with open(tests_path) as f:
            test_in_file = f"def {t['test']}(" in f.read()

    if not func_in_file:
        print(json.dumps({
            "action": "write_function",
            "num": t["num"],
            "title": t["title"],
            "func": t["func"],
            "func_code": t["func_code"],
        }))
    elif not test_in_file:
        print(json.dumps({
            "action": "write_test",
            "num": t["num"],
            "title": t["title"],
            "test": t["test"],
            "test_code": t["test_code"],
        }))
    else:
        # Auto-run pytest and check result
        result = subprocess.run(
            ["python3", "-m", "pytest", "workspace/test_tasks.py", "-k", t["test"], "-v", "--tb=short"],
            capture_output=True, text=True, timeout=120, cwd=PROJECT_ROOT
        )
        passed = f"{t['test']} PASSED" in result.stdout
        if passed:
            update_progress_file(t["num"], True)
            print(json.dumps({"action": "test_passed", "num": t["num"], "title": t["title"]}))
        else:
            print(json.dumps({
                "action": "run_pytest",
                "num": t["num"],
                "title": t["title"],
                "test": t["test"],
                "validation": t["validation"],
                "output": result.stdout[-500:] if result.stdout else "",
                "errors": result.stderr[-500:] if result.stderr else "",
            }))


def progress():
    p = load_progress()
    result = []
    for t in load_tasks():
        result.append({"num": t["num"], "done": p.get(t["num"], False)})
    print(json.dumps(result))


def update_progress_file(num, state):
    tasks = load_tasks()
    task = None
    for t in tasks:
        if t["num"] == num:
            task = t
            break
    if not task:
        return f"ERROR: unknown task {num}"
    marker = state.upper()
    with open(PROGRESS_PATH) as f:
        lines = f.readlines()
    desc = f"Task {task['num']}: {task['title']}"
    new_lines = []
    for line in lines:
        if desc in line:
            new_lines.append(f"- [{marker}] {desc}\n")
        else:
            new_lines.append(line)
    with open(PROGRESS_PATH, "w") as f:
        f.writelines(new_lines)
    return f"OK: Task {num} marked as {state}"


def execute_read_file(args):
    path = args.get("path", "")
    full = os.path.join(PROJECT_ROOT, path)
    if not os.path.isfile(full):
        return f"ERROR: file not found: {path}"
    with open(full) as f:
        return f.read()


def execute_write_file(args):
    path = args.get("path", "")
    content = args.get("content", "")
    if "\\n" in content:
        content = content.replace("\\n", "\n").replace("\\t", "\t").replace('\\"', '"')
    full = os.path.join(PROJECT_ROOT, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(content)
    return f"OK: wrote {len(content)} bytes to {path}"


def execute_run_command(args):
    cmd = args.get("cmd") or args.get("command") or ""
    blocked = ["rm -rf workspace", "rm -rf ./workspace", "rm -rf /", "rm -rf ~"]
    for b in blocked:
        if b in cmd:
            return f"ERROR: blocked dangerous command: {cmd}"
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True,
            timeout=120, cwd=PROJECT_ROOT,
        )
        output = ""
        if result.stdout:
            output += result.stdout
        if result.stderr:
            output += "\nSTDERR:\n" + result.stderr
        output += f"\nEXIT CODE: {result.returncode}"
        return output.strip()
    except subprocess.TimeoutExpired:
        return "ERROR: command timed out after 120s"
    except Exception as e:
        return f"ERROR: {e}"


def execute_update_progress(args):
    num = int(args.get("num", 0))
    state = args.get("state", "done")
    tasks = load_tasks()
    if num not in [t["num"] for t in tasks]:
        return f"ERROR: invalid task {num}"
    return update_progress_file(num, state)


def execute_get_next_task(args):
    import io
    import sys
    
    old_stdout = sys.stdout
    try:
        sys.stdout = buffer = io.StringIO()
        next_task()
        output = buffer.getvalue().strip()
        if output:
            return output
        return json.dumps({"done": True})
    finally:
        sys.stdout = old_stdout


def execute_mark_task(args):
    num = int(args.get("num", 0))
    state = args.get("state", "done")

    result = update_progress_file(num, state)
    if "ERROR" in result:
        return f"ERROR: {result}"

    # Regenerate tasks.json from spec (keeps task definitions current)
    tasks = parse_spec()
    with open(TASKS_JSON, "w") as f:
        json.dump(tasks, f, indent=2)

    return f"OK: Task {num} marked as {state}"


def execute_debrief_task(args):
    """Called by the model as its LAST action after a task passes (or after it
    gives up). Records the model's reflection + suggestions into progress.md
    (inline under the task's marker) and appends to workspace/lessons.md so the
    knowledge accumulates across runs for the vertical market.

    Expected args (semi-structured):
        task_num, what_was_confusing, suggested_rule_for_prompt,
        suggested_spec_clarification
    """
    num = int(args.get("task_num", 0))
    confusing = (args.get("what_was_confusing") or "").strip()
    prompt_rule = (args.get("suggested_rule_for_prompt") or "").strip()
    spec_clar = (args.get("suggested_spec_clarification") or "").strip()

    # --- 1) Inline record in progress.md (sub-items under the task line) ---
    tasks = load_tasks()
    title = ""
    for t in tasks:
        if t["num"] == num:
            title = t["title"]
            break
    if title:
        lines = []
        with open(PROGRESS_PATH) as f:
            lines = f.readlines()
        desc = f"Task {num}: {title}"
        new_lines = []
        for line in lines:
            new_lines.append(line)
            if desc in line:
                if confusing:
                    new_lines.append(f"    - Reflection: {confusing}\n")
                if prompt_rule:
                    new_lines.append(f"    - Suggestion (prompt.md): {prompt_rule}\n")
                if spec_clar:
                    new_lines.append(f"    - Suggestion (spec.md): {spec_clar}\n")
        with open(PROGRESS_PATH, "w") as f:
            f.writelines(new_lines)

    # --- 2) Accumulate into lessons.md (one block per debrief) ---
    today = __import__("datetime").date.today().isoformat()
    with open(os.path.join(WORKSPACE, "lessons.md"), "a") as f:
        f.write(f"## Task {num}: {title} ({today})\n")
        if confusing:
            f.write(f"- Confusing: {confusing}\n")
        if prompt_rule:
            f.write(f"- Suggested prompt.md rule: {prompt_rule}\n")
        if spec_clar:
            f.write(f"- Suggested spec.md clarification: {spec_clar}\n")
        f.write("\n")

    return "OK: debrief recorded"


TOOLS = {
    "read_file": execute_read_file,
    "write_file": execute_write_file,
    "run_command": execute_run_command,
    "update_progress": execute_update_progress,
    "get_next_task": execute_get_next_task,
    "mark_task": execute_mark_task,
    "debrief_task": execute_debrief_task,
}


def execute(tool_name, args_str):
    if tool_name not in TOOLS:
        return f"ERROR: unknown tool '{tool_name}'. Available: {', '.join(TOOLS)}"
    try:
        args = json.loads(args_str) if args_str else {}
    except json.JSONDecodeError:
        return f"ERROR: invalid JSON args: {args_str}"
    return TOOLS[tool_name](args)


def main():
    if len(sys.argv) < 2:
        print("Usage: agent.py <command> [args...]", file=sys.stderr)
        print("Commands: setup, next_task, next_action, progress, execute <tool> <json_args>", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "setup":
        setup()
    elif cmd == "next_task":
        next_task()
    elif cmd == "next_action":
        next_action()
    elif cmd == "progress":
        progress()
    elif cmd == "execute":
        if len(sys.argv) < 4:
            print("Usage: agent.py execute <tool_name> '<json_args>'", file=sys.stderr)
            sys.exit(1)
        tool_name = sys.argv[2]
        args_str = sys.argv[3]
        print(execute(tool_name, args_str))
    else:
        print(f"ERROR: unknown command '{cmd}'", file=sys.stderr)
        sys.exit(1)
if __name__ == "__main__":
    main()