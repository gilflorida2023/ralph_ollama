# SimpleSieve Setup & Validation

You must create ONE Python file in the `workspace/` directory:

1. **`tasks.py`** — every function AND its test go in this single file.

After writing each function and its test, run it directly as a script to
validate: `python3 workspace/tasks.py <test_name>`. Only mark a task `[DONE]`
when its test passes (the script exits 0).

The file ends with a `main()` dispatcher (see the **Entry point** section) that
runs whichever `test_*` function matches `sys.argv[1]`. `main()` auto-discovers
test functions, so you only ever add `def test_*(...)` functions — you never
edit the `main()` dispatch logic.

---

## Task 1: Clone repository

**Function:** `clone_repo()` in `tasks.py`

```python
import os
import shutil
from subprocess import run

def clone_repo():
    """Clone https://github.com/gilflorida2023/simplesieve into workspace/simplesieve/.
    Return the subprocess result.
    """
    target = "workspace/simplesieve"
    # Idempotent: remove any pre-existing clone so git clone never fails with
    # "destination path already exists".
    if os.path.isdir(target):
        shutil.rmtree(target)
    return run(["git", "clone", "https://github.com/gilflorida2023/simplesieve", target])
```

**Test:** `test_clone_repo()` in `tasks.py`

```python
def test_clone_repo():
    result = clone_repo()
    assert result.returncode == 0, f"git clone failed: {result.stderr}"
    assert os.path.isdir("workspace/simplesieve"), "Directory workspace/simplesieve does not exist"
```

**Validation:** Run `python3 workspace/tasks.py test_clone_repo`
**Done:** False

---

## Task 2: Navigate to project directory

**Function:** `get_project_dir()` in `tasks.py`

```python
def get_project_dir():
    """Return the absolute path to the simplesieve project directory.
    This should be os.path.abspath('workspace/simplesieve').
    """
    return os.path.abspath("workspace/simplesieve")
```

**Test:** `test_get_project_dir()` in `tasks.py`

```python
def test_get_project_dir():
    import os
    clone_repo()  # Prerequisite: make sure the upstream repo is cloned first
    path = get_project_dir()
    assert os.path.isdir(path), f"Path does not exist: {path}"
    assert path.endswith("simplesieve"), f"Path does not end with simplesieve: {path}"
```

**Validation:** Run `python3 workspace/tasks.py test_get_project_dir`
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
    return run(["go", "build", "-o", "simplesieve"], cwd=get_project_dir())
```

**Test:** `test_build_program()` in `tasks.py`

```python
def test_build_program():
    import os
    from subprocess import run
    clone_repo()  # Prerequisite: make sure the upstream repo is cloned first
    result = build_program()
    assert result.returncode == 0, f"go build failed: {result.stderr}"
    exe = os.path.join(get_project_dir(), "simplesieve")
    assert os.path.isfile(exe), f"Executable not found: {exe}"
    assert os.access(exe, os.X_OK), f"File is not executable: {exe}"
```

**Validation:** Run `python3 workspace/tasks.py test_build_program`
**Done:** False

---

## Task 4: Count primes in first 1,000,000 natural numbers

**Function:** `count_primes()` in `tasks.py`

```python
def count_primes():
    """Run simplesieve -c --limit 1e6, print the result to stdout, and return
    it as a string.
    Use subprocess.run, set cwd to get_project_dir().
    """
    result = run(["./simplesieve", "-c", "--limit", "1e6"], cwd=get_project_dir(),
                 capture_output=True, text=True)
    print(result.stdout, end="")
    return result.stdout
```

**Test:** `test_count_primes()` in `tasks.py`

```python
def test_count_primes():
    output = count_primes()
    assert "78498" in output, f"Expected '78498' in output, got: {output}"
```

**Validation:** Run `python3 workspace/tasks.py test_count_primes`
**Done:** False

---

## Entry point

Every `tasks.py` must end with a `main()` dispatcher and an
`if __name__ == "__main__"` block. `main()` auto-discovers any `test_*` function
by name, so you NEVER edit the dispatch chain — just add `def test_*(...)` above
it and call `main()` via `python3 workspace/tasks.py <test_name>`.

```python
def main():
    import sys
    name = sys.argv[1] if len(sys.argv) > 1 else ""
    for fn, func in globals().items():
        if fn.startswith("test_") and fn == name:
            func()
            return
    print(f"Unknown test: {name}")
    sys.exit(1)


if __name__ == "__main__":
    main()
```
