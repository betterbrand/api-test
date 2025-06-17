#!/bin/bash
# Script to perform load testing on the Morpheus API Gateway Chat API.
#
# This script will run concurrent conversations using the
# chat API provided by https://openbeta.kyletest.com/

# Load environment variables
source .env 2>/dev/null || echo "No .env file found, using defaults"

# Constants
BASE_URL="https://api.mor.org"
API_KEYS_FILE="$(dirname "$0")/../data/api_keys_temp.json"
RESULTS_DIR="$(dirname "$0")/../results"
MAX_CONCURRENT_REQUESTS="${MAX_CONCURRENT_REQUESTS:-100}"  # Adjust based on API limitations
MAX_WORKERS="${MAX_WORKERS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"  # Number of parallel processes
API_ENDPOINT="$BASE_URL/api/v1/chat/completions"

# Example conversation prompts for testing
CONVERSATION_PROMPTS=(
    "Tell me about artificial intelligence"
    "What's the weather like today?"
    "Explain quantum computing"
    "How do I bake a chocolate cake?"
    "What are the benefits of exercise?"
    "Tell me a joke"
    "What's the capital of France?"
    "Explain blockchain technology"
    "How do I learn to code?"
    "What is machine learning?"
)

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

log_request() {
  echo -e "\n[$(date '+%Y-%m-%d %H:%M:%S')] [REQUEST] $1"
}

log_response() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [RESPONSE] $1\n"
}

log_json() {
  # Pretty print JSON with jq if available, fallback to cat
  if command -v jq &> /dev/null; then
    echo "$1" | jq . 2>/dev/null || echo "$1"
  else
    echo "$1"
  fi
}

# Load API keys from the JSON file
load_api_keys() {
  if [ ! -f "$API_KEYS_FILE" ]; then
    log_error "API keys file not found at $API_KEYS_FILE"
    return 1
  fi
  
  # Check if jq is installed
  if ! command -v jq &> /dev/null; then
    log_error "jq is required but not installed."
    return 1
  fi
  
  # Count the number of API keys
  local key_count=$(jq '.api_keys | length' "$API_KEYS_FILE")
  
  if [ "$key_count" -eq 0 ]; then
    log_error "No API keys found in $API_KEYS_FILE"
    return 1
  fi
  
  log_info "Loaded $key_count API keys"
  return 0
}

# Send a message to the chat API and get the response
send_message() {
  local api_key="$1"
  local conversation_id="$2"
  local message="$3"
  local result_file="$4"
  
  local start_time=$(date +%s.%N)
  
  # Build the API request
  local response_file=$(mktemp)
  local request_body="{
    \"model\": \"default\",
    \"messages\": [
      {
        \"role\": \"system\",
        \"content\": \"You are a helpful assistant.\"
      },
      {
        \"role\": \"user\",
        \"content\": \"$message\"
      }
    ],
    \"stream\": false
  }"
  
  # Log the request details to terminal
  log_request "CONVERSATION: $conversation_id | ENDPOINT: $API_ENDPOINT"
  log_request "REQUEST HEADERS:"
  echo "accept: application/json"
  echo "Authorization: $api_key"
  echo "Content-Type: application/json"
  log_request "REQUEST BODY:"
  log_json "$request_body"
  
  # Use curl with exact same format as the working example
  curl -s -X 'POST' \
    "$API_ENDPOINT" \
    -H 'accept: application/json' \
    -H "Authorization: $api_key" \
    -H 'Content-Type: application/json' \
    -d "$request_body" > "$response_file" 2>/dev/null
  
  local status=$?
  
  local end_time=$(date +%s.%N)
  local duration=$(echo "$end_time - $start_time" | bc)
  
  # Process the response
  if [ $status -eq 0 ]; then
    # Log the response details to terminal
    log_response "CONVERSATION: $conversation_id | DURATION: ${duration}s | STATUS: $status"
    log_response "RESPONSE BODY:"
    log_json "$(cat "$response_file")"
    
    # Check if the response contains an error
    if jq -e '.error' "$response_file" > /dev/null 2>&1; then
      local error_msg=$(jq -r '.error.message // .error' "$response_file")
      log_error "Request failed: $error_msg"
      
      jq -n \
        --arg prompt "$message" \
        --arg conversation_id "$conversation_id" \
        --arg status "$status" \
        --arg duration "$duration" \
        --arg error "$error_msg" \
        '{prompt: $prompt, conversation_id: $conversation_id, status: $status, duration: $duration, error: $error}' > "$result_file"
    else
      # Write to the result file
      jq -n \
        --arg prompt "$message" \
        --arg conversation_id "$conversation_id" \
        --arg status "$status" \
        --arg duration "$duration" \
        --slurpfile response "$response_file" \
        '{prompt: $prompt, conversation_id: $conversation_id, status: $status, duration: $duration, response: $response[0]}' > "$result_file"
    fi
  else
    # Log the error to terminal with specific details
    case $status in
      3)
        log_error "URL malformed error (code 3) for conversation $conversation_id. URL: $API_ENDPOINT"
        ;;
      6)
        log_error "Could not resolve host error (code 6) for conversation $conversation_id. Host: $BASE_URL"
        ;;
      7)
        log_error "Failed to connect error (code 7) for conversation $conversation_id. API endpoint: $API_ENDPOINT"
        ;;
      28)
        log_error "Operation timeout error (code 28) for conversation $conversation_id."
        ;;
      *)
        log_error "Unknown curl error (code $status) for conversation $conversation_id."
        ;;
    esac
    
    # Write error to the result file
    jq -n \
      --arg prompt "$message" \
      --arg conversation_id "$conversation_id" \
      --arg status "$status" \
      --arg duration "$duration" \
      --arg error "API request failed with status $status" \
      '{prompt: $prompt, conversation_id: $conversation_id, status: $status, duration: $duration, error: $error}' > "$result_file"
  fi
  
  # Clean up
  rm -f "$response_file"
}

# Run a conversation with multiple exchanges
run_conversation() {
  local api_key="$1"
  local conversation_id="$2"
  local result_dir="$3"
  
  # Create result directory for this conversation
  mkdir -p "$result_dir"
  
  local start_time=$(date +%s.%N)
  
  # Choose random prompts for this conversation (3 prompts)
  local num_prompts=${#CONVERSATION_PROMPTS[@]}
  local indices=()
  
  # Select 3 random indices (or all if we have fewer)
  local max_prompts=3
  if [ $num_prompts -lt $max_prompts ]; then
    max_prompts=$num_prompts
  fi
  
  for ((i=0; i<max_prompts; i++)); do
    local index=$(($RANDOM % $num_prompts))
    indices+=($index)
  done
  
  # Run each prompt in the conversation
  for i in "${!indices[@]}"; do
    local index=${indices[$i]}
    local prompt="${CONVERSATION_PROMPTS[$index]}"
    local result_file="$result_dir/exchange_$((i+1)).json"
    
    send_message "$api_key" "$conversation_id" "$prompt" "$result_file"
    
    # Add a short delay between messages
    if [ $i -lt $((max_prompts-1)) ]; then
      sleep $(awk 'BEGIN{srand(); print 1+rand()*2}')
    fi
  done
  
  local end_time=$(date +%s.%N)
  local total_duration=$(echo "$end_time - $start_time" | bc)
  
  # Create summary for this conversation
  jq -n \
    --arg conversation_id "$conversation_id" \
    --arg api_key "${api_key:0:10}..." \
    --arg total_duration "$total_duration" \
    --arg exchange_count "${#indices[@]}" \
    '{conversation_id: $conversation_id, api_key: $api_key, total_duration: $total_duration, exchange_count: $exchange_count}' > "$result_dir/summary.json"
}

# Process a batch of API keys
process_batch() {
  local batch_file="$1"
  local batch_results_dir="$2"
  local batch_number="$3"
  
  log_info "Processing batch $batch_number with endpoint: $API_ENDPOINT"
  
  # Create results directory for this batch
  mkdir -p "$batch_results_dir"
  
  # Process each API key in parallel
  jq -c '.[]' "$batch_file" | parallel -j "$MAX_CONCURRENT_REQUESTS" --line-buffer '
    api_key=$(echo {} | jq -r .key)
    key_id=$(echo {} | jq -r .id)
    conversation_id="conv_$(date +%s)_$RANDOM"
    result_dir="'"$batch_results_dir"'/conv_${key_id}"
    echo "[$(date '"'"'+%Y-%m-%d %H:%M:%S'"'"')] [INFO] Starting conversation ${key_id} with key ${api_key:0:10}..."
    source "'"$(dirname "$0")"'/load_test.sh" run_conversation "$api_key" "$conversation_id" "$result_dir"
    echo "[$(date '"'"'+%Y-%m-%d %H:%M:%S'"'"')] [INFO] Completed conversation ${key_id}"
  '
  
  log_info "Completed batch $batch_number"
}

# Main function to run the load test
main() {
  # Check for required commands
  for cmd in curl jq parallel bc grep; do
    if ! command -v $cmd &> /dev/null; then
      log_error "$cmd is required but not installed."
      exit 1
    fi
  done

  # Check if verbose mode is enabled
  VERBOSE_OUTPUT="${VERBOSE_OUTPUT:-0}"
  if [ "$VERBOSE_OUTPUT" != "1" ]; then
    # Override logging functions if not in verbose mode
    log_request() { :; }
    log_response() { :; }
    log_json() { :; }
    log_info "Verbose output disabled. Set VERBOSE_OUTPUT=1 to see detailed API requests and responses."
  else
    log_info "Verbose output enabled. All API requests and responses will be displayed."
  fi
  
  # Suppress GNU Parallel citation notice if it hasn't been acknowledged
  if [ ! -f ~/.parallel/will-cite ]; then
    mkdir -p ~/.parallel
    touch ~/.parallel/will-cite
    log_info "Suppressed GNU Parallel citation notice"
  fi
  
  # Log API endpoint we're using
  log_info "Using API endpoint: $API_ENDPOINT"
  
  # Create results directory if it doesn't exist
  mkdir -p "$RESULTS_DIR"
  
  # Timestamp for this test run
  timestamp=$(date +"%Y%m%d_%H%M%S")
  test_dir="$RESULTS_DIR/test_$timestamp"
  mkdir -p "$test_dir"
  
  # Save test configuration
  jq -n \
    --arg timestamp "$(date -Iseconds)" \
    --arg api_endpoint "$API_ENDPOINT" \
    --arg max_concurrent_requests "$MAX_CONCURRENT_REQUESTS" \
    --arg verbose_output "$VERBOSE_OUTPUT" \
    '{
      timestamp: $timestamp,
      api_endpoint: $api_endpoint,
      max_concurrent_requests: $max_concurrent_requests | tonumber,
      verbose_output: $verbose_output | tonumber
    }' > "$test_dir/config.json"
  
  # Load API keys
  if ! load_api_keys; then
    log_error "Failed to load API keys. Exiting."
    exit 1
  fi
  
  # Split API keys into batches for processing
  local batch_size="$MAX_CONCURRENT_REQUESTS"
  local batches_dir="$test_dir/batches"
  mkdir -p "$batches_dir"
  
  # Use jq to split the API keys into separate files
  local batch_count=0
  jq -c ".api_keys | _nwise($batch_size)" "$API_KEYS_FILE" | 
  while read -r batch; do
    # Save the batch as is, it's already a JSON array
    echo "$batch" > "$batches_dir/batch_$((++batch_count)).json"
  done
  
  # Count the number of batch files
  batch_count=$(ls "$batches_dir"/batch_*.json 2>/dev/null | wc -l)
  if [ "$batch_count" -eq 0 ]; then
    log_error "Failed to create batch files"
    exit 1
  fi
  
  log_info "Split into $batch_count batches of up to $batch_size conversations each"
  
  # Start time for the entire test
  local test_start_time=$(date +%s.%N)
  
  # Process each batch (currently sequential, but could be made parallel)
  for ((i=1; i<=batch_count; i++)); do
    local batch_file="$batches_dir/batch_$i.json"
    local batch_results_dir="$test_dir/batch_$i"
    
    if [ -f "$batch_file" ]; then
      process_batch "$batch_file" "$batch_results_dir" "$i"
    fi
  done
  
  # End time for the entire test
  local test_end_time=$(date +%s.%N)
  local total_test_time=$(echo "$test_end_time - $test_start_time" | bc)
  
  # Generate test summary
  # Count total conversations and successful conversations
  local total_conversations=$(find "$test_dir" -path "*/conv_*" -type d | wc -l)
  
  # Count all exchanges (successful or not)
  local total_exchanges=$(find "$test_dir" -path "*/conv_*/exchange_*.json" | wc -l)
  
  # Count successful and failed exchanges
  local successful_exchanges=0
  local failed_exchanges=0
  
  # Process each exchange file individually
  for exchange_file in $(find "$test_dir" -path "*/conv_*/exchange_*.json"); do
    if grep -q '"error":' "$exchange_file"; then
      failed_exchanges=$((failed_exchanges + 1))
    else
      successful_exchanges=$((successful_exchanges + 1))
    fi
  done
  
  # Define a successful conversation as one where at least one exchange was successful
  local successful_conversations=0
  for conv_dir in $(find "$test_dir" -path "*/conv_*" -type d); do
    # Check if any exchange in this conversation doesn't contain an error field
    if ! grep -q '"error":' "$conv_dir"/exchange_*.json 2>/dev/null; then
      successful_conversations=$((successful_conversations + 1))
    elif grep -q '"status": "0"' "$conv_dir"/exchange_*.json 2>/dev/null; then
      # As a fallback, check for status 0 which indicates success
      successful_conversations=$((successful_conversations + 1))
    fi
  done
  
  local failed_conversations=$((total_conversations - successful_conversations))
  
  # Create summary JSON
  jq -n \
    --arg timestamp "$(date -Iseconds)" \
    --arg total_conversations "$total_conversations" \
    --arg successful_conversations "$successful_conversations" \
    --arg failed_conversations "$failed_conversations" \
    --arg total_exchanges "$total_exchanges" \
    --arg successful_exchanges "$successful_exchanges" \
    --arg failed_exchanges "$failed_exchanges" \
    --arg total_test_duration "$total_test_time" \
    --arg average_conversation_time "$(echo "$total_test_time / $total_conversations" | bc -l 2>/dev/null || echo 0)" \
    '{
      timestamp: $timestamp,
      total_conversations: $total_conversations | tonumber,
      successful_conversations: $successful_conversations | tonumber,
      failed_conversations: $failed_conversations | tonumber,
      total_exchanges: $total_exchanges | tonumber,
      successful_exchanges: $successful_exchanges | tonumber,
      failed_exchanges: $failed_exchanges | tonumber,
      total_test_duration: $total_test_duration | tonumber,
      average_conversation_time: $average_conversation_time | tonumber
    }' > "$test_dir/summary.json"
  
  log_info "Test completed in $total_test_time seconds"
  log_info "Successful conversations: $successful_conversations/$total_conversations"
  log_info "Results saved to $test_dir"
  
  # Collect failed conversation details for the HTML report
  failed_convs_html=""
  for conv_dir in $(find "$test_dir" -path "*/conv_*" -type d); do
    conv_id=$(basename "$conv_dir")
    # Get conversation summary
    conv_summary=$(cat "$conv_dir/summary.json" 2>/dev/null)
    conv_key=$(echo "$conv_summary" | jq -r '.api_key // "Unknown"')
    
    # Check if any exchange in this conversation has an error
    has_error=false
    for exchange_file in "$conv_dir"/exchange_*.json; do
      if grep -q '"error":' "$exchange_file" 2>/dev/null; then
        has_error=true
        break
      fi
    done
    
    if $has_error; then
      # Start HTML for this failed conversation
      failed_convs_html+="<div class='failed-conversation'>"
      failed_convs_html+="<h3>Conversation ID: $conv_id (API Key: $conv_key)</h3>"
      failed_convs_html+="<table class='error-log'>"
      failed_convs_html+="<tr><th>Exchange</th><th>Prompt</th><th>Status</th><th>Duration</th><th>Error</th></tr>"
      
      # Add each exchange
      for exchange_file in "$conv_dir"/exchange_*.json; do
        if [ -f "$exchange_file" ]; then
          exchange_num=$(basename "$exchange_file" | sed 's/exchange_\(.*\)\.json/\1/')
          prompt=$(jq -r '.prompt // "Unknown"' "$exchange_file")
          status=$(jq -r '.status // "Unknown"' "$exchange_file")
          duration=$(jq -r '.duration // "Unknown"' "$exchange_file")
          error=$(jq -r '.error // "None"' "$exchange_file")
          
          # Add row to table
          failed_convs_html+="<tr>"
          failed_convs_html+="<td>$exchange_num</td>"
          failed_convs_html+="<td>$prompt</td>"
          failed_convs_html+="<td>$status</td>"
          failed_convs_html+="<td>$duration</td>"
          failed_convs_html+="<td class='error-message'>$error</td>"
          failed_convs_html+="</tr>"
        fi
      done
      
      failed_convs_html+="</table></div><hr>"
    fi
  done
  
  # Generate HTML report
  cat > "$test_dir/report.html" << EOF
<!DOCTYPE html>
<html>
<head>
  <title>Morpheus API Load Test Report</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 20px; }
    h1 { color: #333; }
    .summary { background: #f5f5f5; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
    .success { color: green; }
    .failure { color: red; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 20px; }
    th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
    th { background-color: #f2f2f2; }
    tr:nth-child(even) { background-color: #f9f9f9; }
    .failed-conversation { margin-bottom: 20px; }
    .error-message { color: red; font-family: monospace; }
    .error-log { font-size: 0.9em; }
    hr { margin: 30px 0; border: 0; border-top: 1px dashed #ccc; }
  </style>
</head>
<body>
  <h1>Morpheus API Load Test Report</h1>
  <div class="summary">
    <h2>Summary</h2>
    <p>Test conducted on: <strong>$(date '+%Y-%m-%d %H:%M:%S')</strong></p>
    <p>API Endpoint: <strong>$API_ENDPOINT</strong></p>
    <p>Total conversations: <strong>$total_conversations</strong></p>
    <p>Successful conversations: <strong class="success">$successful_conversations</strong></p>
    <p>Failed conversations: <strong class="failure">$failed_conversations</strong></p>
    <p>Total exchanges: <strong>$total_exchanges</strong></p>
    <p>Successful exchanges: <strong class="success">$successful_exchanges</strong></p>
    <p>Failed exchanges: <strong class="failure">$failed_exchanges</strong></p>
    <p>Total test duration: <strong>$total_test_time seconds</strong></p>
    <p>Average conversation time: <strong>$(echo "$total_test_time / $total_conversations" | bc -l 2>/dev/null || echo 0) seconds</strong></p>
  </div>

  <div class="failed-logs">
    <h2>Failed Conversation Logs</h2>
    ${failed_convs_html}
  </div>
</body>
</html>
EOF
  
  log_info "HTML report generated at $test_dir/report.html"
}

# Run specific function if specified, otherwise run main
if [ "$1" = "run_conversation" ]; then
  run_conversation "$2" "$3" "$4"
else
  main
fi 