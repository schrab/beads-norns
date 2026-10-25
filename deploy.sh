#!/bin/sh
# deploy.sh - sync the script tree to the device and rebuild the UGen.
# artifacts (*.o, *.so) are excluded; the UGen class rides along in lib/
# (sclang compiles every .sc under ~/dust).
#
# usage: ./deploy.sh [host]        (default host: fates)

HOST="${1:-fates}"
DEST="~/dust/code/beads"

set -e

tar czf - \
  --exclude='*.o' --exclude='*.so' --exclude='.git' \
  beads.lua lib ugens \
  | ssh "$HOST" "mkdir -p $DEST && tar xzf - -C $DEST && \
      make -C $DEST/ugens && make -C $DEST/ugens install && \
      rm -f $DEST/ugens/*.o $DEST/ugens/BeadsUGen.so && \
      rm -rf ~/.local/share/SuperCollider/Extensions/BeadsUGens"

echo "synced + built. restart with: ssh $HOST sudo systemctl restart norns.target"
