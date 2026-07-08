#!/bin/bash
rm -rf workspace/

if ! [ -d venv/ ]
then
	python3 -m venv venv
fi
source venv/bin/activate
pip install -r requirements.txt

# Run once (bootstrap + validate)
python agent.py

# Run in loop mode default is 50
# Equivalent to ./ralph.sh 50
./ralph.sh

