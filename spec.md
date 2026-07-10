# Specification: SimpleSieve Setup & Validation Loop

## 1. Global Execution Rules
* **Workspace Constraint:** All implementations and test cases must reside in exactly one file: `workspace/tasks.py`.
* **State Updates:** Only change `Status: [TODO]` to `Status: [DONE]` once the exact command in the **Validation Command** section passes with an exit code of `0`.
* **Test Isolation:** Do not use mock objects. All tests must verify real file-system states and real process executions on disk.
* **Entry Point:** `workspace/tasks.py` must define a `main()` function that calls all task functions sequentially (clone_repo, get_project_dir, build_program, count_primes). The file ends with `if __name__ == "__main__": main()`.

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
  * Clone the repo: `git clone https://github.com/gilflorida2023/simplesieve workspace/simplesieve`.
  * Return the `CompletedProcess` result.
  * **Doctests to embed in docstring:**
    * Call `clone_repo()`, verify `result.returncode == 0`.
    * Verify `os.path.isdir("workspace/simplesieve/.git")` is `True`.
* **Validation Command:** `python3 -m pytest --doctest-modules workspace/tasks.py -v`

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
* **Validation Command:** `python3 -m pytest --doctest-modules workspace/tasks.py -v`

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
  * Call `get_project_dir()` to get the working directory.
  * Run `["go", "build", "-o", "simplesieve"]` with `cwd=dir_path`.
  * Return `result.returncode`.
  * **Doctests to embed in docstring:**
    * Call `build_program()` and verify `exit_code == 0`.
    * Verify `"simplesieve"` exists and is executable.
* **Validation Command:** `python3 -m pytest --doctest-modules workspace/tasks.py -v`

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
  * Call `get_project_dir()` to get the working directory.
  * Run `["./simplesieve", "-c", "--limit", "1e6"]` with `cwd=dir_path`, `capture_output=True`, `text=True`.
  * Return `result.stdout`.
  * **Doctests to embed in docstring:**
    * Call `count_primes()` and verify `isinstance(output, str)` is `True`.
    * Verify `"78498" in output` is `True`.
* **Validation Command:** `python3 -m pytest --doctest-modules workspace/tasks.py -v`

---

## 3. Entry Point
After the last task function is added, `workspace/tasks.py` must define main() that calls all functions:

```python
def main():
    clone_repo()
    get_project_dir()
    build_program()
    count_primes()

if __name__ == "__main__":
    main()
```