#! /usr/bin/env bash

# IPV4
sed -e 's/\([0-9]\{1,3\}\.\)\{2\}/X.Y./g' | \
# IPv6
rev | sed -E 's/^([0-9a-fA-F]{1,4}:[0-9a-fA-F]{1,4}):.*/\1:Y:X:Y:X:Y:X/' | rev
