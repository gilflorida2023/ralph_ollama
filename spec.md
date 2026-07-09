# SimpleSieve Setup & Validation

You must create two Python files in the `workspace/` directory:

1. **`tasks.py`** — one function per task below
2. **`test_tasks.py`** — one pytest test function per task

After writing each function and its test, run `pytest workspace/test_tasks.py -v` to validate.
Only mark a task `[DONE]` when its corresponding pytest test passes.

---

## Task 1: Clone repository

**Function:** `clone_repo()` in `tasks.py`

```python
def clone_repo():
    """Clone https://github.com/gilflorida2023/simplesieve into workspace/simplesieve/.
    Use subprocess.run to execute: git clone https://github.com/gilflorida2023/simplesieve workspace/simplesieve
    Run it from the project root so the repo lands inside workspace/simplesieve/.
    Return the subprocess result.

    IMPORTANT: This step must be idempotent. If workspace/simplesieve already
    exists (e.g. from a previous run/session), remove it first (e.g.
    shutil.rmtree('workspace/simplesieve')) before running git clone, so the
    clone never fails with "destination path already exists".
    """
```

**Test:** `test_clone_repo()` in `test_tasks.py`

```python
def test_clone_repo():
    import os
    from tasks import clone_repo
    result = clone_repo()
    assert result.returncode == 0, f"git clone failed: {result.stderr}"
    assert os.path.isdir("workspace/simplesieve"), "Directory workspace/simplesieve does not exist"
```

**Validation:** Run `pytest workspace/test_tasks.py::test_clone_repo -v`
**Done:** False

---

## Task 2: Navigate to project directory

**Function:** `get_project_dir()` in `tasks.py`

```python
def get_project_dir():
    """Return the absolute path to the simplesieve project directory.
    This should be os.path.abspath('workspace/simplesieve').
    """
```

**Test:** `test_get_project_dir()` in `test_tasks.py`

```python
def test_get_project_dir():
    import os
    from tasks import get_project_dir
    path = get_project_dir()
    assert os.path.isdir(path), f"Path does not exist: {path}"
    assert path.endswith("simplesieve"), f"Path does not end with simplesieve: {path}"
```

**Validation:** Run `pytest workspace/test_tasks.py::test_get_project_dir -v`
**Done:** False

---

## Task 3: Build the program

**Function:** `build_program()` in `tasks.py`

```python
def build_program():
    """Build simplesieve using 'go build -o simplesieve' inside the project directory.
    Use subprocess.run, set cwd to get_project_dir().
    Return the subprocess result.
    """
```

**Test:** `test_build_program()` in `test_tasks.py`

```python
def test_build_program():
    import os
    from tasks import build_program, get_project_dir
    result = build_program()
    assert result.returncode == 0, f"go build failed: {result.stderr}"
    exe = os.path.join(get_project_dir(), "simplesieve")
    assert os.path.isfile(exe), f"Executable not found: {exe}"
    assert os.access(exe, os.X_OK), f"File is not executable: {exe}"
```

**Validation:** Run `pytest workspace/test_tasks.py::test_build_program -v`
**Done:** False

---

## Task 4: Count primes in first 1,000,000 natural numbers

**Function:** `count_primes()` in `tasks.py`

```python
def count_primes():
    """Run simplesieve -c --limit 1e6 and return the output as a string.
    Use subprocess.run, set cwd to get_project_dir().
    Note: -c flag prints count to stderr, so return stderr (or stdout as fallback).
    """
```

**Test:** `test_count_primes()` in `test_tasks.py`

```python
def test_count_primes():
    from tasks import count_primes
    output = count_primes()
    assert "78498" in output, f"Expected '78498' in output, got: {output}"
```

**Validation:** Run `pytest workspace/test_tasks.py::test_count_primes -v`
**Done:** False
