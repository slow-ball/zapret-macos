#!/bin/bash
# The first run installs zapret, later ones open its menu
exec "$(dirname "$0")/src/zapret.sh"
