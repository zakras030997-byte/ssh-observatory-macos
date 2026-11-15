#!/bin/bash
set -euo pipefail
app='/Applications/SSH Observatory.app'
if [[ ! -d "$app" ]]; then
  echo 'First copy SSH Observatory.app to Applications, then run this installer again.'
  read -r -p 'Press Return to close. ' ignored
  exit 1
fi
if [[ ! -x /usr/bin/python3 ]]; then
  echo 'Python 3 / Apple Command Line Tools is required. See READ ME FIRST.md.'
  read -r -p 'Press Return to close. ' ignored
  exit 1
fi
/usr/bin/python3 "$app/Contents/Resources/setup/install-service.py" --app "$app"
echo 'Service installed. Open SSH Observatory; configure your own SSH aliases and nodes.'
read -r -p 'Press Return to close. ' ignored
