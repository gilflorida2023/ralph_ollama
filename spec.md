# Specification: SimpleSieve Setup & Validation Loop

## 1. Global Execution Rules
* **Workspace Constraint:** All implementations and test cases must reside in exactly one file: `workspace/tasks.py`.
* **State Updates:** Only change `Status: [TODO]` to `Status: [DONE]` once the exact command in the **Validation Command** section passes with an exit code of `0`.
* **Test Isolation:** Do not use mock objects. All tests must verify real file-system states and real process executions on disk.
* **Entry Point:** `workspace/tasks.py` must define a `main()` function that calls all task functions sequentially (clone_repo, get_project_dir, build_program, count_primes). The file ends with `if __name__ == "__main__": main()`. **Wiring up `main()` is its own task (Task 5)** — do NOT add `main()` during Tasks 1–4. `main()` MUST be the last definition in the file (after all task functions).

---

## 2. Phase Task Breakdown

### Task 1: Clone Repository
* **Status:** [TODO]
* **Description:** Implement a function `clone_repo()` that clones `https://github.com/gilflorida2023/simplesieve` into `workspace/simplesieve/`.
* **Requirements:**
  * Must be fully idempotent. If `workspace/simplesieve/` already exists, clean it or remove it entirely before cloning to prevent "destination path already exists" failures.
  * Must return the execution result or handle process failures explicitly.
* **Implementation:**
  * Signature: `def clone_repo()` — no arguments, returns a `subprocess.CompletedProcess`.
  * Import `subprocess.run`, `os`, and `shutil`.
  * **CRITICAL FOR IDEMPOTENCY:** If `workspace/simplesieve/` already exists, remove it with `shutil.rmtree` BEFORE cloning.
  * Clone the repo: `git clone --depth 1 https://github.com/gilflorida2023/simplesieve workspace/simplesieve`. (Use `--depth 1` — a full clone of this repo is very large/slow on a flaky network and can time out.)
  * Return the `CompletedProcess` result.
  * **Doctests to embed in docstring:**
    * Call `clone_repo()`, verify `result.returncode == 0`.
    * Verify `os.path.isdir("workspace/simplesieve/.git")` is `True`.
* **Validation Command:** `python3 -m pytest --doctest-modules workspace/tasks.py -v -k <this_task_function>` (the harness validates only the current task's doctests)

---

### Task 2: Navigate and Locate Project Directory
* **Status:** [TODO]
* **Depends On:** Task 1
* **Description:** Implement a function `get_project_dir()` that returns the absolute path to the cloned `simplesieve` workspace directory.
* **Requirements:**
  * Must return an absolute string path.
  * Must verify that the directory actually exists on the filesystem before returning.
* **Implementation:**
  * Signature: `def get_project_dir()` — no arguments, returns a `str` (absolute path).
  * Import `os`.
  * Compute `os.path.abspath("workspace/simplesieve")`.
  * Raise `FileNotFoundError` if the path does not exist.
  * Return the absolute path.
  * **Doctests to embed in docstring:**
    * Call `get_project_dir()` and verify `os.path.isabs(d)` is `True`.
    * Verify `os.path.isdir(d)` is `True`.
    * Verify `os.path.basename(d) == "simplesieve"` is `True`.
* **Validation Command:** `python3 -m pytest --doctest-modules workspace/tasks.py -v -k <this_task_function>` (the harness validates only the current task's doctests)

---

### Task 3: Compile the Go Program
* **Status:** [TODO]
* **Depends On:** Task 1, Task 2
* **Description:** Implement a function `build_program()` that compiles the `simplesieve` source code using the **Go compiler**.
* **Requirements:**
  * Must execute `go build -o simplesieve` targeting the path provided by `get_project_dir()`.
  * Must explicitly set the subprocess execution context working directory (`cwd`) to the project directory.
  * The project is written in **Go** (not C/C++), so use `go build`, NOT `make`.
* **Implementation:**
  * Signature: `def build_program()` — no arguments, returns `int` (exit code).
  * Import `subprocess`.
  * Call `get_project_dir()` to get the working directory. **`get_project_dir()` MUST return an ABSOLUTE path (use `os.path.abspath`).**
  * **Do NOT use `os.chdir()`** — pass `cwd=project_dir` to `subprocess.run` instead.
  * If the cloned repo is missing (e.g. `not os.path.isdir(get_project_dir())`), call `clone_repo()` first so the build always has something to compile.
  * Run `["go", "build", "-o", "simplesieve"]` with `cwd=dir_path`.
  * Return `result.returncode`.
  * **Doctests to embed in docstring:**
    * Call `build_program()` and verify `exit_code == 0`.
    * Verify `"simplesieve"` exists and is executable.
* **Validation Command:** `python3 -m pytest --doctest-modules workspace/tasks.py -v -k <this_task_function>` (the harness validates only the current task's doctests)

---

### Task 4: Execute Sieve & Extract Prime Count
* **Status:** [TODO]
* **Depends On:** Task 1, Task 2, Task 3
* **Description:** Implement a function `count_primes()` that runs the compiled **Go binary** to calculate primes within a specific range.
* **Requirements:**
  * Must execute `./simplesieve -c --limit 1e6` inside the project directory.
  * Must capture and return the `stdout` output as a string.
* **Implementation:**
  * Signature: `def count_primes()` — no arguments, returns `str`.
  * Import `subprocess`.
  * Call `get_project_dir()` to get the working directory. **MUST be ABSOLUTE (`os.path.abspath`).** **Do NOT use `os.chdir()`** — use `cwd=project_dir`.
  * If the binary is missing, call `build_program()` (and `clone_repo()` if the repo is missing) so the run always has a binary.
  * **Run EXACTLY this command** (the `-c` flag is REQUIRED — without it the binary prints usage help, not the count):
    `run(["./simplesieve", "-c", "--limit", "1e6"], cwd=project_dir, capture_output=True, text=True)`
  * The binary prints the prime count to **stderr** (not stdout). Capture and return `result.stderr`.
  * **Do NOT call `.decode()`** — `text=True` already returns a `str`; `result.stderr` is a string.
  * Return `result.stderr`.
  * **Doctests to embed in docstring:**
    * Call `count_primes()` and verify `isinstance(output, str)` is `True`.
    * Verify `"78498" in output` is `True`.
* **Validation Command:** `python3 -m pytest --doctest-modules workspace/tasks.py -v -k <this_task_function>` (the harness validates only the current task's doctests)

---

### Task 5: Wire Up the Entry Point (main)
* **Status:** [TODO]
* **Depends On:** Task 1, Task 2, Task 3, Task 4
* **Description:** Implement `main()` that calls all task functions in order and guard execution with `if __name__ == "__main__": main()`.
* **Requirements:**
  * `main()` MUST be the LAST definition in `workspace/tasks.py` — it must appear AFTER `clone_repo`, `get_project_dir`, `build_program`, and `count_primes`.
  * It must call `clone_repo()`, `get_project_dir()`, `build_program()`, `count_primes()` in that order.
  * `if __name__ == "__main__": main()` must be the final two lines of the file.
* **Implementation:**
  * Signature: `def main()` — no arguments, returns `None`.
  * The file must NOT contain any function definition after `def main(` (this is the validation criterion below).
  * **Doctests to embed in docstring** (verify placement by inspecting the module source):
    * `main()` is the LAST top-level function definition in the file:
      ```python
      >>> import sys, re
      >>> src = open(sys.modules[__name__].__file__).read()
      >>> defs = re.findall(r'^def (\w+)\(', src, re.M)
      >>> defs[-1]
      'main'
      ```
    * `main()` calls the task functions without error:
      ```python
      >>> import os
      >>> main() is None
      True
      ```
* **Validation Command:** `python3 -m pytest --doctest-modules workspace/tasks.py -v -k <this_task_function>` (the harness validates only the current task's doctests)

---

## 3. Entry Point
The `main()` function is defined in **Task 5** (it must be the last definition in the file, verified by a doctest that inspects source ordering). Reference implementation:

```python
def main():
    clone_repo()
    get_project_dir()
    build_program()
    count_primes()

if __name__ == "__main__":
    main()
```