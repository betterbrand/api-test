#!/bin/bash
# Script to test a single API call to the Morpheus API Gateway Chat API.

# Load environment variables
source .env 2>/dev/null || echo "No .env file found, using defaults"

# Constants
API_URL="${API_URL:-https://api.mor.org/api/v1}"

# Generate a simulated API key
api_key="mor_$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)"

# Test message
test_message="Hello, this is a test message. Please provide a brief response."

echo "Testing API call with simulated key: $api_key"
echo "Endpoint: $API_URL/chat/completions"
echo "Message: $test_message"
echo ""

# Make the API call
response=$(curl -v -X POST \
  -H "Authorization: $api_key" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"default\",
    \"messages\": [
      {
        \"role\": \"system\",
        \"content\": \"You are a helpful assistant.\"
      },
      {
        \"role\": \"user\",
        \"content\": \"$test_message\"
      }
    ],
    \"stream\": false
  }" \
  "$API_URL/chat/completions" 2>&1)

echo "API Response:"
echo "$response"

# Extract and display any error message
error=$(echo "$response" | grep -o '"error":[^}]*' || echo "No error found")
if [ "$error" != "No error found" ]; then
  echo ""
  echo "Error detected: $error"
fi

echo ""
echo "Test completed. Check your real API key if this test failed."
echo "To obtain real API keys, register at https://openbeta.kyletest.com and request keys through the admin interface." 