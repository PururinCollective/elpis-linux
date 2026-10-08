#!/bin/sh
#
# Print the build string the resolver's own Makefile would give a build made
# in the checkout at $1: the tag when HEAD is exactly on one, otherwise
# branch@hash, otherwise the bare hash on a detached HEAD.
#
# Prints nothing when $1 is not itself the top of a git checkout, and never
# looks further up: there it would find another repository's history.

d=$1
[ -n "$d" ] && [ -d "$d" ] || exit 0

top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ "$(cd "$top" && pwd -P)" = "$(cd "$d" && pwd -P)" ] || exit 0

rev=$(git -C "$d" describe --tags --exact-match HEAD 2>/dev/null)
if [ -z "$rev" ]; then
    hash=$(git -C "$d" rev-parse --short=12 HEAD 2>/dev/null)
    branch=$(git -C "$d" symbolic-ref --short -q HEAD 2>/dev/null)
    if [ -n "$branch" ] && [ -n "$hash" ]; then
        rev=$branch@$hash
    else
        rev=$hash
    fi
fi
printf '%s\n' "$rev"
