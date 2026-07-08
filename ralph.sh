#!/bin/bash
# ralph.sh - Simple Ralph Wiggum loop for Ollama

set -euo pipefail

MAX_ITERATIONS=${1:-50}  # Safety cap
ITER=0
LOGFILE="logs/ralph_$(date +%s).log"

mkdir -p logs

echo "=== Starting Ralph Wiggum Loop for Ollama ==="
echo "Spec: $(cat spec.md | head -c 200)... (see spec.md)"
echo "Press Ctrl+C to stop. Max iterations: $MAX_ITERATIONS"

while [ $ITER -lt $MAX_ITERATIONS ]; do
    ITER=$((ITER + 1))
    echo "=== Iteration $ITER ===" | tee -a "$LOGFILE"
    
    # Run the agent (it will read spec.md + progress.md)
    if python3 agent.py; then
        echo "Iteration $ITER completed successfully." | tee -a "$LOGFILE"
        
        # Optional: Check if done (all 4 tasks marked [DONE])
        if grep -q "\[DONE\] Task 1" progress.md && \
           grep -q "\[DONE\] Task 2" progress.md && \
           grep -q "\[DONE\] Task 3" progress.md && \
           grep -q "\[DONE\] Task 4" progress.md; then
            echo "🎉 All tasks complete! Stopping." | tee -a "$LOGFILE"
            break
        fi
    else
        echo "⚠️ Agent failed on iteration $ITER. Continuing anyway..." | tee -a "$LOGFILE"
    fi
    
    # Small delay to avoid hammering
    sleep 2
done

echo "Ralph loop ended after $ITER iterations."
