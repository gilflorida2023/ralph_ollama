#!/usr/bin/env python3
import json
import sys
import os
import subprocess
from ollama import Client

# Simple tool registry
TOOLS = {}

def register_tool(func):
    TOOLS[func.__name__] = func
    return func

WORKSPACE = "workspace"

def _enforce_workspace(path: str) -> str:
    """Ensure path is inside the workspace directory."""
    if path.startswith(f"{WORKSPACE}/") or path.startswith(f"{WORKSPACE}\\"):
        return path
    return f"{WORKSPACE}/{path.lstrip('/')}"

# Example tools - add your own here
@register_tool
def write_file(path: str, content: str) -> str:
    """Create or overwrite a file with content."""
    path = _enforce_workspace(path)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return f"Successfully wrote {path} ({len(content)} characters)"

@register_tool
def read_file(path: str) -> str:
    """Read the content of a file."""
    path = _enforce_workspace(path)
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except Exception as e:
        return f"Error reading {path}: {e}"

@register_tool
def list_dir(path: str = ".") -> str:
    """List files and directories."""
    try:
        return "\n".join(sorted(os.listdir(path)))
    except Exception as e:
        return f"Error: {e}"


@register_tool
def run_python(script_path: str, args: str = "") -> str:
    """Run a Python script and return output + errors."""
    try:
        result = subprocess.run(
            [sys.executable, script_path] + (args.split() if args else []),
            capture_output=True,
            text=True,
            timeout=30
        )
        output = f"STDOUT:\n{result.stdout}\n\nSTDERR:\n{result.stderr}\nReturn code: {result.returncode}"
        return output
    except subprocess.TimeoutExpired:
        return "❌ Script timed out (30s limit)"
    except Exception as e:
        return f"❌ Error running script: {e}"


@register_tool
def search_replace(file_path: str, old_text: str, new_text: str) -> str:
    """Replace text in a file (great for targeted edits)."""
    file_path = _enforce_workspace(file_path)
    try:
        with open(file_path, encoding="utf-8") as f:
            content = f.read()
        new_content = content.replace(old_text, new_text, 1)
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(new_content)
        return f"Replaced in {file_path}"
    except Exception as e:
        return f"Replace failed: {e}"


@register_tool
def run_shell(command: str) -> str:
    """Run any shell command (use carefully)."""
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=60)
        return f"STDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}\nCode: {result.returncode}"
    except Exception as e:
        return f"Command failed: {e}"

@register_tool
def check_task_status(task_number: int) -> str:
    """Check if a specific task is complete by running its validation checks."""
    checks = {
        1: lambda: os.path.isdir(f"{WORKSPACE}/simplesieve"),
        2: lambda: os.path.basename(os.getcwd()) == "simplesieve" or os.path.isdir(f"{WORKSPACE}/simplesieve"),
        3: lambda: os.path.isfile(f"{WORKSPACE}/simplesieve/simplesieve") or os.path.isfile(f"{WORKSPACE}/simplesieve.exe"),
        4: lambda: _validate_task4(),
    }
    if task_number not in checks:
        return f"Unknown task number: {task_number}"
    try:
        passed = checks[task_number]()
        status = "DONE" if passed else "TODO"
        return f"Task {task_number}: {status}"
    except Exception as e:
        return f"Task {task_number}: ERROR - {e}"

def _validate_task4() -> bool:
    """Run simplesieve and check if output matches expected prime count."""
    exe = f"{WORKSPACE}/simplesieve"
    if not os.path.isfile(exe):
        return False
    try:
        result = subprocess.run(
            [exe, "-c", "--limit", "1e6"],
            capture_output=True, text=True, timeout=30
        )
        return result.returncode == 0 and "48498" in result.stdout
    except Exception:
        return False

TOOLS_SCHEMA = {
    "write_file": {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "File path to write to"},
            "content": {"type": "string", "description": "Content to write"}
        },
        "required": ["path", "content"]
    },
    "read_file": {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "File path to read"}
        },
        "required": ["path"]
    },
    "list_dir": {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "Directory path to list", "default": "."}
        },
        "required": []
    },
    "run_python": {
        "type": "object",
        "properties": {
            "script_path": {"type": "string", "description": "Path to the Python script"},
            "args": {"type": "string", "description": "Space-separated arguments", "default": ""}
        },
        "required": ["script_path"]
    },
    "search_replace": {
        "type": "object",
        "properties": {
            "file_path": {"type": "string", "description": "File to edit"},
            "old_text": {"type": "string", "description": "Text to find"},
            "new_text": {"type": "string", "description": "Replacement text"}
        },
        "required": ["file_path", "old_text", "new_text"]
    },
    "run_shell": {
        "type": "object",
        "properties": {
            "command": {"type": "string", "description": "Shell command to run"}
        },
        "required": ["command"]
    },
    "check_task_status": {
        "type": "object",
        "properties": {
            "task_number": {"type": "integer", "description": "Task number to check (1-4)"}
        },
        "required": ["task_number"]
    }
}

def load_context():
    context = {}
    for f in ["spec.md", "progress.md"]:
        try:
            with open(f) as fh:
                context[f] = fh.read()
        except FileNotFoundError:
            context[f] = ""
    return context

def main():
    client = Client()  # or Client(host=...) for remote

    context = load_context()
    
    prompt = f"""You are Ralph, a persistent autonomous agent. You execute tasks from a spec.

SPEC (tasks to complete):
{context['spec.md']}

PROGRESS (what's done):
{context['progress.md'] or 'No tasks completed yet.'}

INSTRUCTIONS:
1. Read the progress above. Find the FIRST task NOT marked [DONE].
2. Execute that task using your tools.
3. Validate the task completed (use check_task_status).
4. Update progress.md with the result: mark [DONE] if success, [TODO] if failed.
5. Do NOT repeat tasks already marked [DONE].
6. When ALL tasks are [DONE], write "ALL TASKS COMPLETE" in your final message.

The workspace is the "workspace" directory. All file operations must target files inside workspace/.

Respond in this JSON format:
{{
  "reasoning": "which task I'm working on and why",
  "tool_calls": [ {{"name": "tool_name", "args": {{"arg1": "value"}}}} ],
  "progress_update": "Line to append to progress.md, e.g. '- [DONE] Task 1: Clone repository'"
}}"""

    # Get response from Ollama (use a capable model with tool support)
    response = client.chat(
            model="qwen2.5:7b",  # or qwen2.5, mistral-nemo, etc. — pick one good at JSON/tools
        messages=[{"role": "user", "content": prompt}],
        tools=[  # Ollama tool format
            {
                "type": "function",
                "function": {
                    "name": name,
                    "description": func.__doc__ or "",
                    "parameters": TOOLS_SCHEMA.get(name, {"type": "object", "properties": {}, "required": []})
                }
            } for name, func in TOOLS.items()
        ],
        format="json",
        options={"temperature": 0.7}
    )

    try:
        content = response['message']['content']
        result = json.loads(content)
        
        print("Reasoning:", result.get("reasoning"))
        
        # Execute tool calls
        for call in result.get("tool_calls", []):
            name = call.get("name")
            args = call.get("args", {})
            if name in TOOLS:
                print(f"Calling {name}({args})")
                try:
                    output = TOOLS[name](**args)
                    print("Tool output:", output)
                except TypeError as e:
                    print(f"Argument error: {e}", file=sys.stderr)
                    print(f"Expected schema: {TOOLS_SCHEMA.get(name, {})}", file=sys.stderr)
                    sys.exit(1)
            else:
                print(f"Unknown tool: {name}")
        
        # Update progress
        if "progress_update" in result:
            with open("progress.md", "a") as f:
                f.write(f"\n{result['progress_update']}")
        
        print("Agent step complete.")
        
    except Exception as e:
        print("Error parsing agent response:", e, file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
