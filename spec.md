# SimpleSieve Setup & Validation

- [ ] **Task 1: Clone repository**
  ```bash
  write python3 code to: git clone https://github.com/gilflorida2023/simplesieve
  ```
  **Validation:**
  - `$?` -eq 0
  - Directory `simplesieve` is created
  **Done: False

- [ ] **Task 2: Navigate to project directory**
  ```bash
  write python3 code to: cd simplesieve
  ```
  **Validation:**
  - `pwd` shows path ending in `simplesieve`
  **Done: False

- [ ] **Task 3: Build the program**
  ```bash
  write python3 code to: go build -o simplesieve
  ```
  **Validation:**
  - `$?` -eq 0
  - Executable file `simplesieve` is created
  **Done: False

- [ ] **Task 4: Count primes in first 1,000,000 natural numbers**
  ```bash
  write python3 code to: ./simplesieve -c --limit 1e6
  ```
  **Validation:**
  - `$?` -eq 0
  - Program returns `48498` (count of primes ≤ 1,000,000)
  **Done: False
