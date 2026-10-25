#!/bin/sh
# deploy.sh - sync the script tree to the device and rebuild the UGen.
# artifacts (*.o, *.so) and ugens/BeadsUGen.sc are excluded: sclang compiles
# every .sc under ~/dust, which would duplicate the Extensions copy.
#
# usage: ./deploy.sh [host]        (default host: fates)

HOST="${1:-fates}"
DEST="~/dust/code/beads"

set -e

tar czf - \
  --exclude='*.o' --exclude='*.so' --exclude='.git' \
  --exclude='ugens/BeadsUGen.sc' \
  beads.lua lib ugens \
  | ssh "$HOST" "mkdir -p $DEST && tar xzf - -C $DEST && \
      make -C $DEST/ugens && make -C $DEST/ugens install && \
      rm -f $DEST/ugens/*.o $DEST/ugens/BeadsUGen.so"

echo "synced + built. restart with: ssh $HOST sudo systemctl restart norns.target"
