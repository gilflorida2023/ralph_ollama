#!/usr/bin/env python3
"""
Zero-dependency check for Ralph's get_next_task / mark_task tool flow.

No pytest required. Run from the repo root:
  python3 tests/check_ralph_tools.py
  (or: ./venv/bin/python tests/check_ralph_tools.py)

Mirrors the pytest tests in test_ralph_tools.py but uses plain asserts and
prints PASS/FAIL so it works even if pytest is not installed.
"""
import os
import sys
import json
import shutil
import subprocess

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import agent  # noqa: E402

WORKSPACE = agent.WORKSPACE
BACKUP = WORKSPACE + ".bak_test"

PASS = 0
FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS: {name}")
    else:
        FAIL += 1
        print(f"FAIL: {name}  {detail}")


def workspace_snapshot():
    existed = os.path.isdir(WORKSPACE)
    if existed:
        if os.path.isdir(BACKUP):
            shutil.rmtree(BACKUP)
        shutil.copytree(WORKSPACE, BACKUP)
    agent.setup()
    return existed


def workspace_restore(existed):
    if existed:
        shutil.rmtree(WORKSPACE)
        shutil.copytree(BACKUP, WORKSPACE)
        shutil.rmtree(BACKUP)
    else:
        if os.path.isdir(WORKSPACE):
            shutil.rmtree(WORKSPACE)


def main():
    existed = workspace_snapshot()
    try:
        # 1. tools registered
        check("get_next_task registered",
              "get_next_task" in agent.TOOLS,
              str(list(agent.TOOLS)))
        check("mark_task registered",
              "mark_task" in agent.TOOLS,
              str(list(agent.TOOLS)))
        check("get_next_task -> execute_get_next_task",
              agent.TOOLS["get_next_task"] is agent.execute_get_next_task)

        # 2. get_next_task direct (ralph.sh style)
        r = subprocess.run(
            [sys.executable, "-c",
             "from agent import execute_get_next_task; print(execute_get_next_task({}))"],
            capture_output=True, text=True, cwd=agent.PROJECT_ROOT,
        )
        ok = r.returncode == 0
        data = None
        if ok:
            try:
                data = json.loads(r.stdout.strip())
            except Exception as e:
                ok = False
                detail = f"bad json: {e!r}; stdout={r.stdout!r}"
        check("get_next_task direct returns task 1",
              ok and data is not None and data.get("num") == 1,
              r.stderr or (f"data={data}"))

        # 3. mark then next advances
        res = agent.execute("mark_task", json.dumps({"num": 1, "state": "done"}))
        nxt = json.loads(agent.execute("get_next_task", "{}"))
        check("mark task 1 done advances next to task 2",
              nxt.get("num") == 2,
              f"mark_res={res!r}; next={nxt!r}")

        # 4. all done sentinel
        for t in agent.load_tasks():
            agent.execute("mark_task", json.dumps({"num": t["num"], "state": "done"}))
        nxt = agent.execute("get_next_task", "{}")
        check("all done returns {\"done\": true}",
              json.loads(nxt) == {"done": True},
              f"next={nxt!r}")

        # 5. dispatcher CLI (LLM path)
        agent.setup()  # reset to a clean state (prior checks marked tasks done)
        r = subprocess.run(
            [sys.executable, "agent.py", "execute", "get_next_task", "{}"],
            capture_output=True, text=True, cwd=agent.PROJECT_ROOT,
        )
        ok = r.returncode == 0
        data = None
        if ok:
            try:
                data = json.loads(r.stdout.strip())
            except Exception as e:
                ok = False
                detail = f"bad json: {e!r}; stdout={r.stdout!r}"
        check("dispatcher CLI get_next_task returns task 1",
              ok and data is not None and data.get("num") == 1,
              r.stderr or (f"data={data}"))
    finally:
        workspace_restore(existed)

    print(f"\n{PASS} passed, {FAIL} failed")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
