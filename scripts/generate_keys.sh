#!/bin/bash
# Script to automatically generate API keys from the Morpheus API Gateway.
#
# This script will interact with the https://openbeta.kyletest.com/ website
# to create 1000 API keys and store them in a JSON file for testing purposes.

# Load environment variables
source .env 2>/dev/null || echo "No .env file found, using defaults"

# Constants
BASE_URL="${API_BASE_URL:-https://openbeta.kyletest.com}"
OUTPUT_DIR="$(dirname "$0")/../data"
OUTPUT_FILE="$OUTPUT_DIR/api_keys.json"
NUM_KEYS="${NUM_KEYS:-1000}"
COOKIE_JAR="/tmp/morapi_cookies_$$.txt"
USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36"
PARALLEL_WORKERS="${PARALLEL_WORKERS:-${MAX_WORKERS:-10}}"  # Number of parallel workers to create keys (override with PARALLEL_WORKERS or MAX_WORKERS env vars)

# Credentials from environment variables
EMAIL="${ACCOUNT_EMAIL}"
PASSWORD="${ACCOUNT_PASSWORD}"

if [ -z "$EMAIL" ] || [ -z "$PASSWORD" ]; then
  echo "Error: ACCOUNT_EMAIL and ACCOUNT_PASSWORD must be set in .env file"
  exit 1
fi

# Logging functions
log_info() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
}

log_error() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

log_warning() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $1" >&2
}

# Setup function
setup() {
  log_info "Setting up environment"
  
  # Check for required commands
  for cmd in curl jq grep sed awk; do
    if ! command -v $cmd &> /dev/null; then
      log_error "$cmd is required but not installed."
      exit 1
    fi
  done
  
  # Check for GNU parallel
  if ! command -v parallel &> /dev/null; then
    log_warning "GNU parallel not found. Parallel key generation will be disabled."
    PARALLEL_WORKERS=1
  fi
  
  # Ensure output directory exists
  mkdir -p "$OUTPUT_DIR"
  
  # Check if we already have API keys stored
  if [ -f "$OUTPUT_FILE" ]; then
    log_warning "API keys file already exists at $OUTPUT_FILE"
    read -p "Do you want to overwrite? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Exiting without changes"
      return 1
    fi
  fi
  
  # Initialize the JSON file with an empty array
  echo '{"api_keys":[]}' > "$OUTPUT_FILE"
  
  return 0
}

# Login to the website
login_to_website() {
  log_info "Logging in to $BASE_URL as $EMAIL"
  
  # First visit the home page to get cookies
  curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" -A "$USER_AGENT" "$BASE_URL" > /dev/null
  
  # Visit the login page to get CSRF token if needed
  local login_page=$(curl -s -L -c "$COOKIE_JAR" -b "$COOKIE_JAR" -A "$USER_AGENT" "$BASE_URL/login")
  
  # Look for CSRF token
  local csrf_token=$(echo "$login_page" | grep -o 'name="csrf[^"]*" value="[^"]*"' | sed 's/.*value="\([^"]*\)".*/\1/')
  
  local csrf_param=""
  if [ -n "$csrf_token" ]; then
    log_info "Found CSRF token: ${csrf_token:0:10}..."
    csrf_param="-d csrf_token=$csrf_token"
  fi
  
  # Submit login form
  local login_response=$(curl -s -L -c "$COOKIE_JAR" -b "$COOKIE_JAR" -A "$USER_AGENT" \
    -e "$BASE_URL/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "email=$EMAIL" \
    -d "password=$PASSWORD" \
    $csrf_param \
    -L "$BASE_URL/login")
  
  # Check if login was successful by looking for indicators
  if echo "$login_response" | grep -qiE "incorrect|failed|invalid|password"; then
    log_error "Login failed. Check credentials."
    return 1
  fi
  
  # Verify we have access to admin page
  local admin_page=$(curl -s -L -c "$COOKIE_JAR" -b "$COOKIE_JAR" -A "$USER_AGENT" "$BASE_URL/admin")
  
  if echo "$admin_page" | grep -qiE "login|sign in|unauthorized"; then
    log_error "Failed to access admin page after login."
    return 1
  fi
  
  log_info "Login successful"
  return 0
}

# Create an API key
create_api_key() {
  local index=$1
  local cookie_file=$2
  
  log_info "Creating API key $index"
  
  # Add random delay to prevent rate limiting
  sleep $(awk -v min=0.5 -v max=1.5 'BEGIN{srand(); print min+rand()*(max-min)}')
  
  # Visit the API key page
  local key_page=$(curl -s -c "$cookie_file" -b "$cookie_file" -A "$USER_AGENT" "$BASE_URL/admin/keys")
  
  # Look for CSRF token
  local csrf_token=$(echo "$key_page" | grep -o 'name="csrf[^"]*" value="[^"]*"' | sed 's/.*value="\([^"]*\)".*/\1/')
  
  local csrf_param=""
  if [ -n "$csrf_token" ]; then
    csrf_param="-d csrf_token=$csrf_token"
  fi
  
  # Create description for the key
  local description="Load Test Key $index (Generated on $(date '+%Y-%m-%d'))"
  
  # Submit the create key form
  local create_response=$(curl -s -c "$cookie_file" -b "$cookie_file" -A "$USER_AGENT" \
    -e "$BASE_URL/admin/keys" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "description=$description" \
    $csrf_param \
    "$BASE_URL/admin/keys/create")
  
  # Try to find the newly created key
  local api_key=""
  
  # First check if the key is directly in the response
  if echo "$create_response" | grep -q "sk-"; then
    api_key=$(echo "$create_response" | grep -o "sk-[a-zA-Z0-9]*" | head -1)
  fi
  
  # If we didn't find the key, try fetching the keys page
  if [ -z "$api_key" ]; then
    local keys_page=$(curl -s -c "$cookie_file" -b "$cookie_file" -A "$USER_AGENT" "$BASE_URL/admin/keys")
    
    # Look for the key with our description
    local key_line=$(echo "$keys_page" | grep -A 5 "$description" | grep -o "sk-[a-zA-Z0-9]*" | head -1)
    
    if [ -n "$key_line" ]; then
      api_key="$key_line"
    fi
  fi
  
  if [ -z "$api_key" ]; then
    log_error "Failed to extract API key for index $index"
    return 1
  fi
  
  # Record the key
  local key_id="key_$index"
  local created_at=$(date +"%Y-%m-%d %H:%M:%S")
  
  # Create the key JSON
  local key_json=$(jq -n \
    --arg id "$key_id" \
    --arg key "$api_key" \
    --arg description "$description" \
    --arg created_at "$created_at" \
    '{id: $id, key: $key, description: $description, created_at: $created_at}')
  
  # Append to our keys file (using a lock to prevent race conditions)
  (
    flock -x 200
    local temp_file=$(mktemp)
    jq ".api_keys += [$key_json]" "$OUTPUT_FILE" > "$temp_file" && mv "$temp_file" "$OUTPUT_FILE"
  ) 200>"/tmp/morapi_keys_lock_$$"
  
  log_info "Successfully created API key: ${api_key:0:10}..."
  return 0
}

# Process a batch of keys
process_key_batch() {
  local start_idx=$1
  local end_idx=$2
  local worker_id=$3
  local worker_cookie_jar="/tmp/morapi_cookies_worker_${worker_id}_$$.txt"
  
  # Copy the main cookie jar to worker-specific cookie jar
  cp "$COOKIE_JAR" "$worker_cookie_jar"
  
  log_info "Worker $worker_id starting to process keys $start_idx to $end_idx"
  
  local success_count=0
  
  for ((i=start_idx; i<end_idx; i++)); do
    if create_api_key $i "$worker_cookie_jar"; then
      success_count=$((success_count+1))
    fi
  done
  
  log_info "Worker $worker_id completed with $success_count successful keys"
  
  # Clean up
  rm -f "$worker_cookie_jar"
  
  return 0
}

# Main function
main() {
  if ! setup; then
    log_error "Setup failed. Exiting."
    exit 1
  fi
  
  # Login to the website
  if ! login_to_website; then
    log_error "Login failed. Exiting."
    exit 1
  fi
  
  log_info "Starting generation of $NUM_KEYS API keys using $PARALLEL_WORKERS workers"
  
  # Calculate batch size for each worker
  local batch_size=$(( (NUM_KEYS + PARALLEL_WORKERS - 1) / PARALLEL_WORKERS ))
  
  # Generate keys in parallel
  if [ "$PARALLEL_WORKERS" -gt 1 ]; then
    # Using parallel workers
    local pids=()
    
    for ((worker=0; worker<PARALLEL_WORKERS; worker++)); do
      local start_idx=$((worker * batch_size))
      local end_idx=$(( (worker + 1) * batch_size ))
      
      if [ "$end_idx" -gt "$NUM_KEYS" ]; then
        end_idx=$NUM_KEYS
      fi
      
      # Skip if no keys to generate
      if [ "$start_idx" -ge "$end_idx" ]; then
        continue
      fi
      
      # Start worker in background
      process_key_batch $start_idx $end_idx $worker &
      pids+=($!)
      
      log_info "Started worker $worker (PID: ${pids[-1]}) for keys $start_idx to $end_idx"
    done
    
    # Wait for all workers to complete
    log_info "Waiting for all workers to complete..."
    for pid in "${pids[@]}"; do
      wait $pid
      log_info "Worker with PID $pid completed"
    done
  else
    # Single worker mode
    process_key_batch 0 $NUM_KEYS 0
  fi
  
  # Count the total number of keys generated
  local total_keys=$(jq '.api_keys | length' "$OUTPUT_FILE")
  
  log_info "Key generation completed. Total keys generated: $total_keys"
  log_info "API keys saved to $OUTPUT_FILE"
  
  # Clean up
  rm -f "$COOKIE_JAR" "/tmp/morapi_keys_lock_$$"
}

# Run main function
main 