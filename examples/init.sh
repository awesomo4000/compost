#!/bin/sh
# Run with: compo --init examples/init.sh
# Or copy to ~/.config/compo/init.sh and customize the commands.
set -eu

ctl() { "$COMPO_BIN" ctl --quiet "$@"; }

ctl create --tile --name main --command 'tmux new-session -A -s work'
ctl create --tile --name sidebar --target main --edge left --ratio 2500 --command 'tmm'
ctl create --tile --name scratch --target main --edge bottom --ratio 2500
ctl focus main
