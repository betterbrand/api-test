#!/bin/bash
# Script to test API key generation with a small number of keys

# Set environment variables for testing
export NUM_KEYS=3
export PARALLEL_WORKERS=2

# Run the key generation script
./scripts/generate_keys.sh

# Check the results
echo ""
echo "Generated keys (first 3):"
jq '.api_keys[0:3]' data/api_keys.json

# Reset environment variables
unset NUM_KEYS
unset PARALLEL_WORKERS

echo ""
echo "Key generation test complete. Check the format of the keys to ensure they start with 'sk-'." 