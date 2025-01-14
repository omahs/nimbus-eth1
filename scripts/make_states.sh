#!/bin/bash

# Create a set of states, each advanced by 100k blocks

set -e

trap "exit" INT

if [ -z "$3"  ]
  then
    echo "Syntax: make_states.sh datadir era1dir statsdir"
    exit 1;
fi

counter=0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
DATE="$(date -u +%Y%m%d_%H%M)"
REV=$(git rev-parse --short=8 HEAD)

while true;
do
  "$SCRIPT_DIR/../build/nimbus" import \
    --data-dir:"$1/${DATE}-${REV}" \
    --era1-dir:"$2" \
    --debug-csv-stats:"$3/stats-${DATE}-${REV}.csv" \
    --max-blocks:100000
  cp -ar "$1/${DATE}-${REV}" "$1/${DATE}-${REV}"-$(printf "%04d" $counter)
  counter=$((counter+1))
done
