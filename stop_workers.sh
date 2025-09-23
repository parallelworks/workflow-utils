#!/bin/bash

# Specify list of nodes to shut down on command line, e.g.:
# ./stop_workers.sh sfgary-azure2-00017-1-[0001-0011]

echo "Stopping workers: ${1}"

sudo scontrol update nodename="${1}" state=power_down_force

echo "Workers should be stopped. Check their status in sinfo."

