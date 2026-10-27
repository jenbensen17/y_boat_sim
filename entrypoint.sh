#!/bin/bash
# Set up the sim's environment, then run the given command.
set -e
source /sim/setup.bash
exec "$@"
