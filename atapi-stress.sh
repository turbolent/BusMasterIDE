#!/bin/sh
#
# Read-only ATAPI CD stress test for OPENSTEP.
#
# Usage:
#   sh atapi-stress.sh /path/to/mounted/cd
#   sh atapi-stress.sh /path/to/mounted/cd 10
#   sh atapi-stress.sh /path/to/mounted/cd 10 /tmp
#
# The script repeatedly reads every regular file from the mounted CD to
# /dev/null.  Passes alternate between sorted and reverse-sorted order to keep
# the script compatible with OPENSTEP's older awk/shell tools.

MOUNT=${1-}
PASSES=${2-5}
TMPDIR=${3-/tmp}
MESSAGES=/usr/adm/messages
LIST=$TMPDIR/atapi-files.$$
ORDER=$TMPDIR/atapi-order.$$
LOGMARK="atapi-stress $$"

if [ "x$MOUNT" = "x" ]; then
    echo "usage: sh atapi-stress.sh /path/to/mounted/cd [passes] [tmpdir]"
    exit 1
fi

if [ ! -d "$MOUNT" ]; then
    echo "$MOUNT is not a directory"
    exit 1
fi

rm -f "$LIST" "$ORDER"

echo "$LOGMARK begin mount=$MOUNT passes=$PASSES"
echo "building file list..."
find "$MOUNT" -type f -print > "$LIST"

COUNT=`wc -l < "$LIST"`
echo "files: $COUNT"
if [ "$COUNT" -eq 0 ]; then
    echo "no regular files found under $MOUNT"
    rm -f "$LIST" "$ORDER"
    exit 1
fi

pass=1
while [ "$pass" -le "$PASSES" ]; do
    echo
    echo "== ATAPI pass $pass of $PASSES =="

    if expr "$pass" % 2 > /dev/null; then
        sort < "$LIST" > "$ORDER"
    else
        sort -r < "$LIST" > "$ORDER"
    fi

    if [ ! -s "$ORDER" ]; then
        echo "sort produced no output; using original file order"
        cp "$LIST" "$ORDER"
    fi

    ORDER_COUNT=`wc -l < "$ORDER"`
    echo "pass files: $ORDER_COUNT"
    if [ "$ORDER_COUNT" -eq 0 ]; then
        echo "$LOGMARK failed: empty pass file list"
        rm -f "$LIST" "$ORDER"
        exit 2
    fi

    ok=0
    fail=0
    exec 3<&0
    exec < "$ORDER"
    while read file
    do
        if cat "$file" > /dev/null; then
            ok=`expr "$ok" + 1`
        else
            echo "read failed: $file"
            fail=`expr "$fail" + 1`
        fi
    done
    exec 0<&3

    echo "pass $pass done: ok=$ok fail=$fail"
    if [ "$fail" -ne 0 ]; then
        echo "$LOGMARK failed"
        rm -f "$LIST" "$ORDER"
        exit 2
    fi

    pass=`expr "$pass" + 1`
done

echo
echo "$LOGMARK complete"

if [ -f "$MESSAGES" ]; then
    echo
    echo "== recent ATAPI/IDE error markers =="
    grep 'ATAPI:.*failed' "$MESSAGES"
    grep 'ATAPI:.*timeout' "$MESSAGES"
    grep 'ATAPI:.*error' "$MESSAGES"
    grep 'ATAPI:.*reset' "$MESSAGES"
    grep 'IDE:.*failed' "$MESSAGES"
    grep 'IDE:.*timeout' "$MESSAGES"
    grep 'IDE:.*error' "$MESSAGES"
    grep 'IDE:.*reset' "$MESSAGES"
fi

rm -f "$LIST" "$ORDER"
exit 0
