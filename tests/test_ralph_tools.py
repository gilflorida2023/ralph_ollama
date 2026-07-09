"""
pytest tests for Ralph's exclusive get_next_task / mark_task tool flow.

These prove:
  - the tools are registered
  - get_next_task returns the first task (and matches how ralph.sh calls it)
  - marking a task done advances get_next_task to the next task
  - when all tasks are done, get_next_task returns {"done": true}
  - the CLI dispatcher `agent.py execute get_next_task '{}'` works (LLM path)

Run from repo root with the venv interpreter:
  ./venv/bin/python -m pytest tests/test_ralph_tools.py -v
"""
import os
import sys
import json
import shutil
import subprocess

import pytest  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import agent  # noqa: E402

WORKSPACE = agent.WORKSPACE
BACKUP = WORKSPACE + ".bak_test"


@pytest.fixture(autouse=True)
def workspace_snapshot():
    """Back up the real workspace, regenerate it via setup(), restore after."""
    existed = os.path.isdir(WORKSPACE)
    if existed:
        if os.path.isdir(BACKUP):
            shutil.rmtree(BACKUP)
        shutil.copytree(WORKSPACE, BACKUP)
    agent.setup()
    try:
        yield
    finally:
        if existed:
            shutil.rmtree(WORKSPACE)
            shutil.copytree(BACKUP, WORKSPACE)
            shutil.rmtree(BACKUP)
        else:
            if os.path.isdir(WORKSPACE):
                shutil.rmtree(WORKSPACE)


def test_tools_registered():
    assert "get_next_task" in agent.TOOLS
    assert "mark_task" in agent.TOOLS
    assert agent.TOOLS["get_next_task"] is agent.execute_get_next_task


def test_get_next_task_direct():
    """Replicates exactly how ralph.sh obtains the next task."""
    r = subprocess.run(
        [sys.executable, "-c",
         "from agent import execute_get_next_task; print(execute_get_next_task({}))"],
        capture_output=True, text=True, cwd=agent.PROJECT_ROOT,
    )
    assert r.returncode == 0, r.stderr
    data = json.loads(r.stdout.strip())
    assert data["num"] == 1


def test_mark_then_next_advances():
    res = agent.execute("mark_task", json.dumps({"num": 1, "state": "done"}))
    assert "OK" in res
    nxt = json.loads(agent.execute("get_next_task", "{}"))
    assert nxt["num"] == 2


def test_all_done_sentinel():
    for t in agent.load_tasks():
        agent.execute("mark_task", json.dumps({"num": t["num"], "state": "done"}))
    nxt = agent.execute("get_next_task", "{}")
    assert json.loads(nxt) == {"done": True}


def test_dispatcher_cli():
    """Proves the LLM tool-call path: `agent.py execute get_next_task '{}'`."""
    r = subprocess.run(
        [sys.executable, "agent.py", "execute", "get_next_task", "{}"],
        capture_output=True, text=True, cwd=agent.PROJECT_ROOT,
    )
    assert r.returncode == 0, r.stderr
    data = json.loads(r.stdout.strip())
    assert data["num"] == 1
