rm -rf workspace/

if ! [ -d venv/ ]
then
	python3 -m venv
fi
source venv/bin/activate
pip install -r requirements.txt

# Run once (bootstrap + validate)
python3 agent.py

# Run in loop mode default is 5
./ralph.sh

