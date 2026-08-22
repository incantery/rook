#!/bin/sh
# Stand-in $SHELL for conformance runs: replay the corpus, then hold
# the screen. rook-mux spawns "$SHELL -l"; we ignore the args.
cat "$RMVT_FILE"
sleep 60
