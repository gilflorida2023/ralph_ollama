#!/bin/bash
# Pin cwd to the script's directory so rm -rf workspace/ and the delegated
# ralph.sh resolve against the project root regardless of invoke location.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rm -rf workspace/

rm logs/*
if ! [ -d venv/ ]
then
	python3 -m venv venv
fi
source venv/bin/activate
pip install -r requirements.txt

 ./ralph.sh 50 -v --clean
