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

# Example tools - add your own here
@register_tool
def write_file(path: str, content: str) -> str:
    """Create or overwrite a file with content."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return f"✅ Successfully wrote {path} ({len(content)} characters)"

@register_tool
def read_file(path: str) -> str:
    """Read the content of a file."""
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except Exception as e:
        return f"❌ Error reading {path}: {e}"

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
    try:
        with open(file_path, encoding="utf-8") as f:
            content = f.read()
        new_content = content.replace(old_text, new_text, 1)
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(new_content)
        return f"✅ Replaced in {file_path}"
    except Exception as e:
        return f"❌ Replace failed: {e}"


@register_tool
def run_shell(command: str) -> str:
    """Run any shell command (use carefully)."""
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=60)
        return f"STDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}\nCode: {result.returncode}"
    except Exception as e:
        return f"Command failed: {e}"

def load_context():
    context = {}
    for f in ["spec.md", "progress.md", "todo.md"]:
        try:
            with open(f) as fh:
                context[f] = fh.read()
        except FileNotFoundError:
            context[f] = ""
    return context

def main():
    client = Client()  # or Client(host=...) for remote

    context = load_context()
    
    prompt = f"""You are Ralph, a persistent autonomous agent.

SPEC:
{context['spec.md']}

CURRENT PROGRESS:
{context['progress.md'] or 'None yet.'}

TODO:
{context['todo.md'] or 'None.'}

You have access to tools. Perform **one meaningful step** toward the spec per response.
Update progress.md and todo.md when appropriate.
When the overall goal is achieved, write "TASK COMPLETE" in your final message.

Respond in this JSON format:
{{
  "reasoning": "what I'm doing this step",
  "tool_calls": [ {{"name": "tool_name", "args": {{"arg1": "value"}}}} , ... ],
  "next_progress_update": "summary for progress.md"
}}"""

    # Get response from Ollama (use a capable model with tool support)
    response = client.chat(
        model="llama3.2:3b",  # or qwen2.5, mistral-nemo, etc. — pick one good at JSON/tools
        messages=[{"role": "user", "content": prompt}],
        tools=[  # Ollama tool format
            {
                "type": "function",
                "function": {
                    "name": name,
                    "description": func.__doc__ or "",
                    "parameters": {"type": "object", "properties": {}, "required": []}  # Extend as needed
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
                output = TOOLS[name](**args)
                print("Tool output:", output)
            else:
                print(f"Unknown tool: {name}")
        
        # Update progress
        if "next_progress_update" in result:
            with open("progress.md", "a") as f:
                f.write(f"\n\n### Iteration {os.getenv('ITER', 'unknown')}\n{result['next_progress_update']}")
        
        print("Agent step complete.")
        
    except Exception as e:
        print("Error parsing agent response:", e, file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
