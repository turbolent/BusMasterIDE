#!/bin/sh
#
# Quick BusMasterIDE driver smoke/performance test for OPENSTEP.
#
# Defaults match the current verified setup:
#   raw device: /dev/rhd0a
#   read test: 5000 * 65536 bytes by default
#   write test: 200 copies of /mach_kernel to /tmp/write-test
#
# Usage:
#   sh ide-test.sh
#   sh ide-test.sh /dev/rhd0a /tmp 5000 200
#   sh ide-test.sh /dev/rhd0a /tmp 2500 200 131072

RAWDEV=${1-/dev/rhd0a}
TMPDIR=${2-/tmp}
READ_COUNT=${3-5000}
WRITE_LOOPS=${4-200}
BS=${5-65536}
OUT=$TMPDIR/write-test
MESSAGES=/usr/adm/messages

echo "BusMasterIDE test: raw=$RAWDEV tmp=$TMPDIR read_count=$READ_COUNT write_loops=$WRITE_LOOPS"
echo

echo "== fsck before =="
fsck
echo

echo "== raw read =="
echo "time dd if=$RAWDEV of=/dev/null bs=$BS count=$READ_COUNT"
time dd if=$RAWDEV of=/dev/null bs=$BS count=$READ_COUNT
echo

echo "== filesystem write =="
rm -f $OUT
echo "time sh -c 'i=0; while [ \$i -lt $WRITE_LOOPS ]; do cat /mach_kernel; i=\`expr \$i + 1\`; done > $OUT; sync'"
time sh -c "i=0; while [ \$i -lt $WRITE_LOOPS ]; do cat /mach_kernel; i=\`expr \$i + 1\`; done > $OUT; sync"
ls -l $OUT
echo

echo "== fsck after =="
fsck
echo

if [ -f $MESSAGES ]; then
    echo "== IDE messages =="
    grep 'IDE:' $MESSAGES
    echo
    echo "== IDE error/retry/reset messages =="
    grep 'IDE:.*error' $MESSAGES
    grep 'IDE:.*failed' $MESSAGES
    grep 'IDE:.*timeout' $MESSAGES
    grep 'IDE:.*retry' $MESSAGES
    grep 'IDE:.*reset' $MESSAGES
    grep 'IDE:.*incomplete' $MESSAGES
    grep 'IDE:.*unsupported' $MESSAGES
else
    echo "$MESSAGES not found"
fi

echo
echo "Temporary files:"
ls -l $OUT 2>/dev/null
