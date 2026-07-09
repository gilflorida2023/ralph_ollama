#!/bin/bash
rm -rf workspace/

if ! [ -d venv/ ]
then
	python3 -m venv venv
fi
source venv/bin/activate
pip install -r requirements.txt

 ./ralph.sh 50 -v

