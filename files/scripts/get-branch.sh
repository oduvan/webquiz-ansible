#!/bin/bash

# Script to get the branch for ansible-pull from data file
# Falls back to 'master' if no branch file exists

BRANCH_FILE="/mnt/data/ansible-branch"
DEFAULT_BRANCH="master"

# Check if branch file exists and is readable
if [[ -f "$BRANCH_FILE" && -r "$BRANCH_FILE" ]]; then
    # Read branch from file, removing any trailing whitespace
    BRANCH=$(cat "$BRANCH_FILE" | tr -d '[:space:]')
    
    # Validate branch name (basic validation)
    if [[ -n "$BRANCH" && "$BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
        echo "$BRANCH"
        exit 0
    fi
fi

# Fall back to default branch
echo "$DEFAULT_BRANCH"