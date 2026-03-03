#!/usr/bin/env bash

if [ $# -ne 1 ]; then
    echo "Usage: $0 <logfile>"
    exit 1
fi

logfile="$1"

compute_sum=0
compute_count=0
write_sum=0
write_count=0

while IFS= read -r line; do
    if [[ "$line" == *"compute before cngns write actual solution file"* ]]; then
        # Extract time inside parentheses (e.g., 2181.818ms)
        time=$(echo "$line" | sed -n 's/.*(\([0-9.]*\)ms).*/\1/p')
        compute_sum=$(awk "BEGIN {print $compute_sum + $time}")
        ((compute_count++))
    fi

    if [[ "$line" == *"cngns write actual solution file"* ]] && \
       [[ "$line" != *"compute before"* ]]; then
        time=$(echo "$line" | sed -n 's/.*(\([0-9.]*\)ms).*/\1/p')
        write_sum=$(awk "BEGIN {print $write_sum + $time}")
        ((write_count++))
    fi
done < "$logfile"

if [ "$compute_count" -gt 0 ]; then
    compute_avg=$(awk "BEGIN {print $compute_sum / $compute_count}")
else
    compute_avg=0
fi

if [ "$write_count" -gt 0 ]; then
    write_avg=$(awk "BEGIN {print $write_sum / $write_count}")
else
    write_avg=0
fi

echo "Compute before CGNS write:"
echo "  Count  : $compute_count"
echo "  Average: ${compute_avg} ms"

echo
echo "CGNS write actual solution file:"
echo "  Count  : $write_count"
echo "  Average: ${write_avg} ms"
