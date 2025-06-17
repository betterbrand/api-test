#!/bin/bash
# Test script to verify the API endpoints for the Morpheus API Gateway

# Load environment variables
source .env 2>/dev/null || echo "No .env file found, using defaults"

# Constants
BASE_URL="${API_BASE_URL:-https://openbeta.kyletest.com}"

# Logging function
log_info() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
}

log_error() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

# Check the API endpoints available
check_api_endpoints() {
  log_info "Checking available API endpoints..."
  
  # Get the OpenAPI spec if available
  log_info "Checking API documentation"
  local docs_response=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/docs")
  
  if [ "$docs_response" == "200" ]; then
    log_info "API documentation available at $BASE_URL/api/docs"
  else
    log_info "API documentation not available at standard endpoint (HTTP $docs_response)"
  fi
  
  # Check basic endpoints
  local endpoints=(
    "/api/auth/register"
    "/api/auth/login"
    "/api/keys/generate"
    "/api/chat"
  )
  
  for endpoint in "${endpoints[@]}"; do
    local response=$(curl -s -o /dev/null -I -w "%{http_code}" "$BASE_URL$endpoint")
    log_info "Endpoint $endpoint: HTTP $response"
  done
}

# Test basic chat without authentication
test_basic_chat() {
  log_info "Testing basic chat without authentication..."
  
  local chat_response=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "{
      \"message\": \"Hello, this is a test message\"
    }" \
    "$BASE_URL/api/chat")
  
  log_info "Basic chat response: $chat_response"
}

# Test authentication endpoints
test_auth_endpoints() {
  log_info "Testing authentication endpoints..."
  
  # Generate a unique username and email for registration
  local username="morapi_test_$(date +%s)"
  local email="${username}@loadtest.com"
  local password="MorapiTest123!"
  
  log_info "Registering test user: $username"
  
  # Step 1: Try to register a new user
  log_info "Step 1: Register user"
  local register_response=$(curl -v -X POST \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$username\",\"email\":\"$email\",\"password\":\"$password\"}" \
    "$BASE_URL/api/auth/register" 2>&1)
  
  echo "Registration verbose response:"
  echo "$register_response"
  
  # Check available authentication endpoints
  log_info "Exploring authentication endpoints"
  local auth_endpoints=(
    "/api/auth"
    "/api/auth/register"
    "/api/auth/login"
    "/api/auth/me"
    "/api/auth/token"
  )
  
  for endpoint in "${auth_endpoints[@]}"; do
    local response=$(curl -s -o /dev/null -I -w "%{http_code}" "$BASE_URL$endpoint")
    log_info "Auth endpoint $endpoint: HTTP $response"
  done
}

# Test direct API key access
test_direct_key_access() {
  log_info "Testing direct API key access..."
  
  # Try with a dummy key
  local test_key="test_key_$(date +%s)"
  
  local key_response=$(curl -v -X GET \
    -H "Authorization: Api-Key $test_key" \
    "$BASE_URL/api/keys/me" 2>&1)
  
  echo "API key test response:"
  echo "$key_response"
}

# Main function
main() {
  log_info "Starting API tests for $BASE_URL"
  
  # First check what endpoints are available
  check_api_endpoints
  
  # Test basic chat without authentication
  test_basic_chat
  
  # Test authentication endpoints
  test_auth_endpoints
  
  # Test direct API key access
  test_direct_key_access
  
  log_info "API tests completed"
}

# Run main function
main 