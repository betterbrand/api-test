#!/bin/bash
# Scenario-based load testing script for the Morpheus API Gateway
# Implements 6 different testing scenarios with varying concurrency and API key patterns
#
# Scenarios:
# 1) Single API Key - 10/100 requests serially
# 2) Single API Key - 10/100 requests concurrently  
# 3) 5 API Keys - 10/20 requests serially per key (50/100 total)
# 4) 5 API Keys - 10/20 requests concurrently per key (50/100 total)
# 5) 5 API Keys (different models) - 10/20 requests serially per key (50/100 total)
# 6) 5 API Keys (different models) - 10/20 requests concurrently per key (50/100 total)

# Load environment variables
source .env 2>/dev/null || echo "No .env file found, using defaults"

# Constants
SCRIPT_DIR="$(dirname "$0")"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
API_KEYS_FILE="$BASE_DIR/data/api_keys_temp.json"
RESULTS_DIR="$BASE_DIR/results"
LOAD_TEST_SCRIPT="$SCRIPT_DIR/load_test.sh"

# Test configuration
MODELS=("llama-3.1-8b" "llama-3.1-70b" "qwen-2.5-coder-32b" "llama-3.1-405b" "gpt-4o-mini")
# Default model for requests without explicit model parameter
DEFAULT_MODEL="${MODELS[0]}"
export DEFAULT_MODEL

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

# Check prerequisites
check_prerequisites() {
    for cmd in curl jq parallel bc; do
        if ! command -v $cmd &> /dev/null; then
            log_error "$cmd is required but not installed."
            return 1
        fi
    done
    
    if [ ! -f "$API_KEYS_FILE" ]; then
        log_error "API keys file not found at $API_KEYS_FILE"
        return 1
    fi
    
    if [ ! -f "$LOAD_TEST_SCRIPT" ]; then
        log_error "Load test script not found at $LOAD_TEST_SCRIPT"
        return 1
    fi
    
    # Suppress GNU Parallel citation notice if it hasn't been acknowledged
    if [ ! -f ~/.parallel/will-cite ]; then
        mkdir -p ~/.parallel
        touch ~/.parallel/will-cite
        log_info "Suppressed GNU Parallel citation notice"
    fi
    
    return 0
}

# Create API key subsets for testing
prepare_api_keys() {
    local test_dir="$1"
    
    # Extract first API key for single-key scenarios
    jq '.api_keys[0]' "$API_KEYS_FILE" > "$test_dir/single_key.json"
    
    # Check how many keys we actually have
    local available_keys=$(jq '.api_keys | length' "$API_KEYS_FILE")
    log_info "Available API keys: $available_keys"
    
    # Use all available keys (up to 5) for multi-key scenarios
    jq --arg max_keys "$([ $available_keys -gt 5 ] && echo 5 || echo $available_keys)" '
    {api_keys: .api_keys[0:($max_keys | tonumber)]}' "$API_KEYS_FILE" > "$test_dir/five_keys.json"
    
    # Create keys with different models assigned (cycling through models if we have fewer keys)
    jq --argjson models '["'"${MODELS[0]}"'","'"${MODELS[1]}"'","'"${MODELS[2]}"'","'"${MODELS[3]}"'","'"${MODELS[4]}"'"]' '
    {
        api_keys: [
            .api_keys | to_entries | map(.value + {model: $models[.key % ($models | length)]}) | .[]
        ]
    }' "$test_dir/five_keys.json" > "$test_dir/five_keys_models.json"
}

# Send a single request with custom model support
send_single_request() {
    local api_key="$1"
    local conversation_id="$2"
    local result_file="$3"
    local model="${4:-$DEFAULT_MODEL}"
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [REQUEST] Starting request for $conversation_id with key $api_key, model $model"
    
    local start_time=$(date +%s.%N)
    
    # Build the API request
    local response_file=$(mktemp)
    local request_body="{
        \"model\": \"$model\",
        \"messages\": [
            {
                \"role\": \"system\",
                \"content\": \"You are a helpful assistant.\"
            },
            {
                \"role\": \"user\",
                \"content\": \"Tell me about artificial intelligence in one sentence.\"
            }
        ],
        \"stream\": false
    }"
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [REQUEST_BODY] $conversation_id: $request_body"
    
    # Use curl to send the request
    curl -s -X 'POST' \
        "https://api.mor.org/api/v1/chat/completions" \
        -H 'accept: application/json' \
        -H "Authorization: $api_key" \
        -H 'Content-Type: application/json' \
        -d "$request_body" > "$response_file" 2>/dev/null
    
    local status=$?
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    # Log the raw response
    local response_content=$(cat "$response_file")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [RESPONSE] $conversation_id (status: $status, duration: ${duration}s): $response_content"
    
    # Process the response
    local has_error=false
    local error_msg=""
    
    if [ $status -ne 0 ]; then
        has_error=true
        error_msg="HTTP request failed with status $status"
    elif jq -e '.error' "$response_file" > /dev/null 2>&1; then
        has_error=true
        error_msg=$(jq -r '.error.message // .error // "API error"' "$response_file")
    elif jq -e '.detail' "$response_file" > /dev/null 2>&1; then
        has_error=true
        error_msg=$(jq -r '.detail // "API detail error"' "$response_file")
    elif ! jq -e '.choices' "$response_file" > /dev/null 2>&1; then
        has_error=true
        error_msg="No choices in response - likely an error"
    fi
    
    if [ "$has_error" = false ]; then
        # Success
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] Request succeeded for $conversation_id"
        jq -n \
            --arg conversation_id "$conversation_id" \
            --arg status "$status" \
            --arg duration "$duration" \
            --arg model "$model" \
            --slurpfile response "$response_file" \
            '{conversation_id: $conversation_id, status: $status, duration: $duration, model: $model, response: $response[0]}' > "$result_file"
    else
        # Error
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Request failed for $conversation_id: $error_msg"
        jq -n \
            --arg conversation_id "$conversation_id" \
            --arg status "$status" \
            --arg duration "$duration" \
            --arg model "$model" \
            --arg error "$error_msg" \
            '{conversation_id: $conversation_id, status: $status, duration: $duration, model: $model, error: $error}' > "$result_file"
    fi
    
    rm -f "$response_file"
}

# Scenario 1: Single API Key - Serial requests
run_scenario_1() {
    local test_dir="$1"
    local scenario_dir="$test_dir/scenario_1"
    
    log_info "Running Scenario 1: Single API Key - Serial requests"
    
    local api_key=$(jq -r '.key' "$test_dir/single_key.json")
    local key_id=$(jq -r '.id' "$test_dir/single_key.json")
    
    # 1a: 10 requests serially
    local scenario_1a_dir="$scenario_dir/1a_serial_10"
    mkdir -p "$scenario_1a_dir"
    
    log_info "Scenario 1a: 10 serial requests"
    local start_time=$(date +%s.%N)
    
    for i in $(seq 1 10); do
        send_single_request "$api_key" "conv_${key_id}_$i" "$scenario_1a_dir/request_$i.json"
    done
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    jq -n \
        --arg scenario "1a" \
        --arg description "Single key, 10 serial requests" \
        --arg total_requests "10" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_1a_dir/summary.json"
    
    # 1b: 100 requests serially
    local scenario_1b_dir="$scenario_dir/1b_serial_100"
    mkdir -p "$scenario_1b_dir"
    
    log_info "Scenario 1b: 100 serial requests"
    start_time=$(date +%s.%N)
    
    for i in $(seq 1 100); do
        send_single_request "$api_key" "conv_${key_id}_$i" "$scenario_1b_dir/request_$i.json"
    done
    
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc)
    
    jq -n \
        --arg scenario "1b" \
        --arg description "Single key, 100 serial requests" \
        --arg total_requests "100" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_1b_dir/summary.json"
}

# Scenario 2: Single API Key - Concurrent requests
run_scenario_2() {
    local test_dir="$1"
    local scenario_dir="$test_dir/scenario_2"
    
    log_info "Running Scenario 2: Single API Key - Concurrent requests"
    
    local api_key=$(jq -r '.key' "$test_dir/single_key.json")
    local key_id=$(jq -r '.id' "$test_dir/single_key.json")
    
    # 2a: 10 requests concurrently
    local scenario_2a_dir="$scenario_dir/2a_concurrent_10"
    mkdir -p "$scenario_2a_dir"
    
    log_info "Scenario 2a: 10 concurrent requests"
    local start_time=$(date +%s.%N)
    
    export -f send_single_request
    seq 1 10 | parallel -j10 \
        send_single_request "'$api_key'" "'conv_${key_id}_{}'" "'$scenario_2a_dir/request_{}.json'"
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    jq -n \
        --arg scenario "2a" \
        --arg description "Single key, 10 concurrent requests" \
        --arg total_requests "10" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_2a_dir/summary.json"
    
    # 2b: 100 requests concurrently
    local scenario_2b_dir="$scenario_dir/2b_concurrent_100"
    mkdir -p "$scenario_2b_dir"
    
    log_info "Scenario 2b: 100 concurrent requests"
    start_time=$(date +%s.%N)
    
    seq 1 100 | parallel -j100 \
        send_single_request "'$api_key'" "'conv_${key_id}_{}'" "'$scenario_2b_dir/request_{}.json'"
    
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc)
    
    jq -n \
        --arg scenario "2b" \
        --arg description "Single key, 100 concurrent requests" \
        --arg total_requests "100" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_2b_dir/summary.json"
}

# Scenario 3: 5 API Keys - Serial requests per key
run_scenario_3() {
    local test_dir="$1"
    local scenario_dir="$test_dir/scenario_3"
    
    log_info "Running Scenario 3: 5 API Keys - Serial requests per key"
    
    # 3a: 10 requests per key serially (50 total)
    local scenario_3a_dir="$scenario_dir/3a_5keys_serial_10_each"
    mkdir -p "$scenario_3a_dir"
    
    log_info "Scenario 3a: 10 serial requests per key (50 total)"
    local start_time=$(date +%s.%N)
    
    jq -c '.api_keys[]' "$test_dir/five_keys.json" | while read -r key_data; do
        local api_key=$(echo "$key_data" | jq -r '.key')
        local key_id=$(echo "$key_data" | jq -r '.id')
        
        mkdir -p "$scenario_3a_dir/$key_id"
        
        for i in $(seq 1 10); do
            send_single_request "$api_key" "conv_${key_id}_$i" "$scenario_3a_dir/$key_id/request_$i.json"
        done
    done
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    # Calculate actual total requests made
    local actual_requests=$(find "$scenario_3a_dir" -name "request_*.json" | wc -l)
    
    jq -n \
        --arg scenario "3a" \
        --arg description "5 keys, 10 serial requests per key (50 total)" \
        --arg total_requests "$actual_requests" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_3a_dir/summary.json"
    
    # 3b: 20 requests per key serially (100 total)
    local scenario_3b_dir="$scenario_dir/3b_5keys_serial_20_each"
    mkdir -p "$scenario_3b_dir"
    
    log_info "Scenario 3b: 20 serial requests per key (100 total)"
    start_time=$(date +%s.%N)
    
    jq -c '.api_keys[]' "$test_dir/five_keys.json" | while read -r key_data; do
        local api_key=$(echo "$key_data" | jq -r '.key')
        local key_id=$(echo "$key_data" | jq -r '.id')
        
        mkdir -p "$scenario_3b_dir/$key_id"
        
        for i in $(seq 1 20); do
            send_single_request "$api_key" "conv_${key_id}_$i" "$scenario_3b_dir/$key_id/request_$i.json"
        done
    done
    
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc)
    
    # Calculate actual total requests made
    actual_requests=$(find "$scenario_3b_dir" -name "request_*.json" | wc -l)
    
    jq -n \
        --arg scenario "3b" \
        --arg description "5 keys, 20 serial requests per key (100 total)" \
        --arg total_requests "$actual_requests" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_3b_dir/summary.json"
}

# Scenario 4: 5 API Keys - Concurrent requests per key
run_scenario_4() {
    local test_dir="$1"
    local scenario_dir="$test_dir/scenario_4"
    
    log_info "Running Scenario 4: 5 API Keys - Concurrent requests per key"
    
    # 4a: 10 requests per key concurrently (50 total)
    local scenario_4a_dir="$scenario_dir/4a_5keys_concurrent_10_each"
    mkdir -p "$scenario_4a_dir"
    
    log_info "Scenario 4a: 10 concurrent requests per key (50 total)"
    local start_time=$(date +%s.%N)
    
    # Use a temporary file approach which is more reliable
    export -f send_single_request
    
    # Create a temporary file with all requests
    local request_file=$(mktemp)
    
    # Read keys and create requests
    local keys_json=$(cat "$test_dir/five_keys.json")
    local key_count=$(echo "$keys_json" | jq '.api_keys | length')
    
    for ((k=0; k<key_count; k++)); do
        local api_key=$(echo "$keys_json" | jq -r ".api_keys[$k].key")
        local key_id=$(echo "$keys_json" | jq -r ".api_keys[$k].id")
        
        mkdir -p "$scenario_4a_dir/$key_id"
        
        # Add each request to the file (space-separated for parallel -N3)
        for i in $(seq 1 10); do
            echo "$api_key conv_${key_id}_$i $scenario_4a_dir/$key_id/request_$i.json" >> "$request_file"
        done
    done
    
    # Execute all requests in parallel from the file
    cat "$request_file" | xargs -n3 -P30 bash -c 'send_single_request "$1" "$2" "$3"' _
    
    # Clean up
    rm -f "$request_file"
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    # Calculate actual total requests made
    local actual_requests=$(find "$scenario_4a_dir" -name "request_*.json" | wc -l)
    
    jq -n \
        --arg scenario "4a" \
        --arg description "5 keys, 10 concurrent requests per key (50 total)" \
        --arg total_requests "$actual_requests" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_4a_dir/summary.json"
    
    # 4b: 20 requests per key concurrently (100 total)
    local scenario_4b_dir="$scenario_dir/4b_5keys_concurrent_20_each"
    mkdir -p "$scenario_4b_dir"
    
    log_info "Scenario 4b: 20 concurrent requests per key (100 total)"
    start_time=$(date +%s.%N)
    
    # Use a temporary file approach which is more reliable
    local request_file=$(mktemp)
    
    # Read keys and create requests
    local keys_json=$(cat "$test_dir/five_keys.json")
    local key_count=$(echo "$keys_json" | jq '.api_keys | length')
    
    for ((k=0; k<key_count; k++)); do
        local api_key=$(echo "$keys_json" | jq -r ".api_keys[$k].key")
        local key_id=$(echo "$keys_json" | jq -r ".api_keys[$k].id")
        
        mkdir -p "$scenario_4b_dir/$key_id"
        
        # Add each request to the file (space-separated for parallel -N3)
        for i in $(seq 1 20); do
            echo "$api_key conv_${key_id}_$i $scenario_4b_dir/$key_id/request_$i.json" >> "$request_file"
        done
    done
    
    # Execute all requests in parallel from the file
    cat "$request_file" | xargs -n3 -P60 bash -c 'send_single_request "$1" "$2" "$3"' _
    
    # Clean up
    rm -f "$request_file"
    
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc)
    
    # Calculate actual total requests made
    actual_requests=$(find "$scenario_4b_dir" -name "request_*.json" | wc -l)
    
    jq -n \
        --arg scenario "4b" \
        --arg description "5 keys, 20 concurrent requests per key (100 total)" \
        --arg total_requests "$actual_requests" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_4b_dir/summary.json"
}

# Scenario 5: 5 API Keys with different models - Serial requests
run_scenario_5() {
    local test_dir="$1"
    local scenario_dir="$test_dir/scenario_5"
    
    log_info "Running Scenario 5: 5 API Keys (different models) - Serial requests"
    
    # 5a: 10 requests per key serially (50 total)
    local scenario_5a_dir="$scenario_dir/5a_5keys_models_serial_10_each"
    mkdir -p "$scenario_5a_dir"
    
    log_info "Scenario 5a: 10 serial requests per key with different models (50 total)"
    local start_time=$(date +%s.%N)
    
    jq -c '.api_keys[]' "$test_dir/five_keys_models.json" | while read -r key_data; do
        local api_key=$(echo "$key_data" | jq -r '.key')
        local key_id=$(echo "$key_data" | jq -r '.id')
        local model=$(echo "$key_data" | jq -r '.model')
        
        mkdir -p "$scenario_5a_dir/$key_id"
        
        for i in $(seq 1 10); do
            send_single_request "$api_key" "conv_${key_id}_$i" "$scenario_5a_dir/$key_id/request_$i.json" "$model"
        done
    done
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    # Calculate actual total requests made
    local actual_requests=$(find "$scenario_5a_dir" -name "request_*.json" | wc -l)
    
    jq -n \
        --arg scenario "5a" \
        --arg description "5 keys with different models, 10 serial requests per key (50 total)" \
        --arg total_requests "$actual_requests" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_5a_dir/summary.json"
    
    # 5b: 20 requests per key serially (100 total)
    local scenario_5b_dir="$scenario_dir/5b_5keys_models_serial_20_each"
    mkdir -p "$scenario_5b_dir"
    
    log_info "Scenario 5b: 20 serial requests per key with different models (100 total)"
    start_time=$(date +%s.%N)
    
    jq -c '.api_keys[]' "$test_dir/five_keys_models.json" | while read -r key_data; do
        local api_key=$(echo "$key_data" | jq -r '.key')
        local key_id=$(echo "$key_data" | jq -r '.id')
        local model=$(echo "$key_data" | jq -r '.model')
        
        mkdir -p "$scenario_5b_dir/$key_id"
        
        for i in $(seq 1 20); do
            send_single_request "$api_key" "conv_${key_id}_$i" "$scenario_5b_dir/$key_id/request_$i.json" "$model"
        done
    done
    
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc)
    
    # Calculate actual total requests made
    actual_requests=$(find "$scenario_5b_dir" -name "request_*.json" | wc -l)
    
    jq -n \
        --arg scenario "5b" \
        --arg description "5 keys with different models, 20 serial requests per key (100 total)" \
        --arg total_requests "$actual_requests" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_5b_dir/summary.json"
}

# Scenario 6: 5 API Keys with different models - Concurrent requests
run_scenario_6() {
    local test_dir="$1"
    local scenario_dir="$test_dir/scenario_6"
    
    log_info "Running Scenario 6: 5 API Keys (different models) - Concurrent requests"
    
    # 6a: 10 requests per key concurrently (50 total)
    local scenario_6a_dir="$scenario_dir/6a_5keys_models_concurrent_10_each"
    mkdir -p "$scenario_6a_dir"
    
    log_info "Scenario 6a: 10 concurrent requests per key with different models (50 total)"
    local start_time=$(date +%s.%N)
    
    # Use a temporary file approach which is more reliable
    local request_file=$(mktemp)
    
    # Read keys and create requests
    local keys_json=$(cat "$test_dir/five_keys_models.json")
    local key_count=$(echo "$keys_json" | jq '.api_keys | length')
    
    for ((k=0; k<key_count; k++)); do
        local api_key=$(echo "$keys_json" | jq -r ".api_keys[$k].key")
        local key_id=$(echo "$keys_json" | jq -r ".api_keys[$k].id")
        local model=$(echo "$keys_json" | jq -r ".api_keys[$k].model")
        
        mkdir -p "$scenario_6a_dir/$key_id"
        
        # Add each request to the file (space-separated for parallel -N4)
        for i in $(seq 1 10); do
            echo "$api_key conv_${key_id}_$i $scenario_6a_dir/$key_id/request_$i.json $model" >> "$request_file"
        done
    done
    
    # Execute all requests in parallel from the file
    cat "$request_file" | xargs -n4 -P30 bash -c 'send_single_request "$1" "$2" "$3" "$4"' _
    
    # Clean up
    rm -f "$request_file"
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    # Calculate actual total requests made
    local actual_requests=$(find "$scenario_6a_dir" -name "request_*.json" | wc -l)
    
    jq -n \
        --arg scenario "6a" \
        --arg description "5 keys with different models, 10 concurrent requests per key (50 total)" \
        --arg total_requests "$actual_requests" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_6a_dir/summary.json"
    
    # 6b: 20 requests per key concurrently (100 total)
    local scenario_6b_dir="$scenario_dir/6b_5keys_models_concurrent_20_each"
    mkdir -p "$scenario_6b_dir"
    
    log_info "Scenario 6b: 20 concurrent requests per key with different models (100 total)"
    start_time=$(date +%s.%N)
    
    # Use a temporary file approach which is more reliable
    local request_file=$(mktemp)
    
    # Read keys and create requests
    local keys_json=$(cat "$test_dir/five_keys_models.json")
    local key_count=$(echo "$keys_json" | jq '.api_keys | length')
    
    for ((k=0; k<key_count; k++)); do
        local api_key=$(echo "$keys_json" | jq -r ".api_keys[$k].key")
        local key_id=$(echo "$keys_json" | jq -r ".api_keys[$k].id")
        local model=$(echo "$keys_json" | jq -r ".api_keys[$k].model")
        
        mkdir -p "$scenario_6b_dir/$key_id"
        
        # Add each request to the file (space-separated for parallel -N4)
        for i in $(seq 1 20); do
            echo "$api_key conv_${key_id}_$i $scenario_6b_dir/$key_id/request_$i.json $model" >> "$request_file"
        done
    done
    
    # Execute all requests in parallel from the file
    cat "$request_file" | xargs -n4 -P60 bash -c 'send_single_request "$1" "$2" "$3" "$4"' _
    
    # Clean up
    rm -f "$request_file"
    
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc)
    
    # Calculate actual total requests made
    actual_requests=$(find "$scenario_6b_dir" -name "request_*.json" | wc -l)
    
    jq -n \
        --arg scenario "6b" \
        --arg description "5 keys with different models, 20 concurrent requests per key (100 total)" \
        --arg total_requests "$actual_requests" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_6b_dir/summary.json"
}

# Generate comprehensive report with dynamic error details
generate_report() {
    local test_dir="$1"
    
    log_info "Generating comprehensive test report with dynamic error analysis"
    
    # Collect all scenario summaries
    local all_summaries=""
    for scenario_dir in "$test_dir"/scenario_*/*/; do
        if [ -f "$scenario_dir/summary.json" ]; then
            local summary=$(cat "$scenario_dir/summary.json")
            if [ -n "$all_summaries" ]; then
                all_summaries="$all_summaries,$summary"
            else
                all_summaries="$summary"
            fi
        fi
    done
    
    # Create master summary
    echo "[$all_summaries]" | jq '.' > "$test_dir/master_summary.json"
    
    # Count total requests and calculate success rates across all scenarios
    local total_requests=0
    local total_successful=0
    local total_failed=0
    local error_summary=""
    
    # Analyze all request files for errors
    for request_file in $(find "$test_dir" -name "request_*.json" | sort); do
        total_requests=$((total_requests + 1))
        if grep -q '"error":' "$request_file"; then
            total_failed=$((total_failed + 1))
        else
            total_successful=$((total_successful + 1))
        fi
    done
    
    # Calculate success rate
    local success_rate=0
    if [ $total_requests -gt 0 ]; then
        success_rate=$(echo "scale=2; $total_successful * 100 / $total_requests" | bc -l 2>/dev/null || echo 0)
    fi
    
    # Generate HTML report
    cat > "$test_dir/scenario_report.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Morpheus API Scenario Test Report - Dynamic Error Analysis</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; line-height: 1.6; }
        h1, h2, h3 { color: #333; }
        .summary { background: #f5f5f5; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
        .critical-error { background: #ffebee; padding: 15px; border-radius: 5px; margin-bottom: 20px; border-left: 4px solid #f44336; }
        .scenario-section { background: #f9f9f9; padding: 15px; margin: 15px 0; border-left: 4px solid #007cba; border-radius: 5px; }
        .error-detail { background: #fff3cd; padding: 10px; margin: 10px 0; border-radius: 3px; font-family: monospace; font-size: 0.9em; border-left: 3px solid #ffc107; }
        .request-error { background: #ffebee; padding: 8px; margin: 5px 0; border-radius: 3px; font-size: 0.85em; }
        .success { color: green; font-weight: bold; }
        .failure { color: red; font-weight: bold; }
        .warning { color: orange; font-weight: bold; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 20px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
        tr:nth-child(even) { background-color: #f9f9f9; }
        .error-count { background: #ffcdd2; padding: 5px; border-radius: 3px; }
        .collapsible { background-color: #e3f2fd; color: #000; cursor: pointer; padding: 10px; width: 100%; border: none; text-align: left; outline: none; font-size: 14px; border-radius: 5px; margin: 5px 0; }
        .collapsible:hover { background-color: #bbdefb; }
        .content { padding: 0 18px; display: none; overflow: hidden; background-color: #f1f8ff; }
        .scenario-list { list-style: none; padding: 0; margin: 0; }
        .scenario-item { margin-bottom: 20px; }
    </style>
    <script>
        function toggleContent(element) {
            var content = element.nextElementSibling;
            if (content.style.display === "block") {
                content.style.display = "none";
                element.innerHTML = element.innerHTML.replace("▼", "▶");
            } else {
                content.style.display = "block";
                element.innerHTML = element.innerHTML.replace("▶", "▼");
            }
        }
    </script>
</head>
<body>
    <h1>🚨 Morpheus API Scenario Test Report - Dynamic Error Analysis</h1>
    
    <div class="summary">
        <h2>Overall Test Summary</h2>
        <p><strong>Test Date:</strong> $(date '+%Y-%m-%d %H:%M:%S')</p>
        <p><strong>Total Scenarios:</strong> $(echo "[$all_summaries]" | jq '. | length')</p>
        <p><strong>Total Requests:</strong> $total_requests</p>
        <p><strong>Successful Requests:</strong> <span class="success">$total_successful</span></p>
        <p><strong>Failed Requests:</strong> <span class="failure">$total_failed</span></p>
        <p><strong>Success Rate:</strong> <span class="$([ $(echo "$success_rate > 80" | bc -l 2>/dev/null || echo 0) -eq 1 ] && echo "success" || echo "failure")">$success_rate%</span></p>
    </div>
EOF

    # Add critical alert if success rate is low
    if [ $(echo "$success_rate < 50" | bc -l 2>/dev/null || echo 1) -eq 1 ]; then
        cat >> "$test_dir/scenario_report.html" << EOF
    <div class="critical-error">
        <h2>🔥 Critical System Alert</h2>
        <p><strong>WARNING:</strong> Success rate below 50% indicates significant system issues</p>
        <p><strong>Impact:</strong> $([ $total_successful -eq 0 ] && echo "Complete system failure - no requests successful" || echo "Partial system failure - reliability compromised")</p>
    </div>
EOF
    fi
    
    cat >> "$test_dir/scenario_report.html" << EOF
    <h2>📊 Scenario Performance Overview</h2>
    
    <table>
        <tr>
            <th>Scenario</th>
            <th>Description</th>
            <th>Requests</th>
            <th>Duration (s)</th>
            <th>Rate (req/s)</th>
            <th>Success Rate</th>
        </tr>
EOF

    # Add scenario rows to the table with success rate calculation
    echo "[$all_summaries]" | jq -c '.[]' | while read -r scenario; do
        local scenario_id=$(echo "$scenario" | jq -r '.scenario')
        local description=$(echo "$scenario" | jq -r '.description')
        local total_req=$(echo "$scenario" | jq -r '.total_requests')
        local duration=$(echo "$scenario" | jq -r '.duration')
        local rps=$(echo "scale=2; $total_req / $duration" | bc -l 2>/dev/null || echo 0)
        
        # Calculate success rate for this scenario
        local scenario_successful=0
        local scenario_failed=0
        for request_file in $(find "$test_dir" -path "*${scenario_id}_*" -name "request_*.json" 2>/dev/null); do
            if grep -q '"error":' "$request_file"; then
                scenario_failed=$((scenario_failed + 1))
            else
                scenario_successful=$((scenario_successful + 1))
            fi
        done
        
        local scenario_success_rate=0
        if [ $total_req -gt 0 ]; then
            scenario_success_rate=$(echo "scale=1; $scenario_successful * 100 / $total_req" | bc -l 2>/dev/null || echo 0)
        fi
        
        cat >> "$test_dir/scenario_report.html" << EOF
        <tr>
            <td>$scenario_id</td>
            <td>$description</td>
            <td>$total_req</td>
            <td>$duration</td>
            <td>$rps</td>
            <td class="$([ $(echo "$scenario_success_rate > 80" | bc -l 2>/dev/null || echo 0) -eq 1 ] && echo "success" || echo "failure")">$scenario_success_rate%</td>
        </tr>
EOF
    done
    
    cat >> "$test_dir/scenario_report.html" << EOF
    </table>
    
    <h2>🔍 Detailed Scenario Analysis with Error Breakdown</h2>
    <ol class="scenario-list">
EOF

    # Generate detailed scenario analysis with dynamic error reporting
    echo "[$all_summaries]" | jq -c '.[]' | while read -r scenario; do
        local scenario_id=$(echo "$scenario" | jq -r '.scenario')
        local description=$(echo "$scenario" | jq -r '.description')
        local total_req=$(echo "$scenario" | jq -r '.total_requests')
        local duration=$(echo "$scenario" | jq -r '.duration')
        
        # Find all request files for this scenario
        local scenario_requests=($(find "$test_dir" -path "*${scenario_id}_*" -name "request_*.json" 2>/dev/null | sort))
        
        # Count successes and failures for this scenario
        local scenario_successful=0
        local scenario_failed=0
        local error_types=()
        local error_samples=()
        
        for request_file in "${scenario_requests[@]}"; do
            if grep -q '"error":' "$request_file"; then
                scenario_failed=$((scenario_failed + 1))
                local error_msg=$(jq -r '.error // "Unknown error"' "$request_file" 2>/dev/null | head -1)
                error_samples+=("$error_msg")
            else
                scenario_successful=$((scenario_successful + 1))
            fi
        done
        
        local scenario_success_rate=0
        if [ $total_req -gt 0 ]; then
            scenario_success_rate=$(echo "scale=1; $scenario_successful * 100 / $total_req" | bc -l 2>/dev/null || echo 0)
        fi
        
        cat >> "$test_dir/scenario_report.html" << EOF
    <li class="scenario-item">
        <div class="scenario-section">
            <h3>Scenario $scenario_id: $(echo "$description" | sed 's/^./\U&/')</h3>
            <p><strong>Purpose:</strong> $(get_scenario_purpose "$scenario_id")</p>
            <p><strong>Results:</strong> 
                <span class="$([ $scenario_successful -gt 0 ] && echo "success" || echo "failure")">$scenario_successful successful</span> / 
                <span class="$([ $scenario_failed -eq 0 ] && echo "success" || echo "failure")">$scenario_failed failed</span> 
                ($scenario_success_rate% success rate)
            </p>
            <p><strong>Performance:</strong> $total_req requests in ${duration}s ($(echo "scale=2; $total_req / $duration" | bc -l 2>/dev/null || echo 0) req/s)</p>
EOF

        # Add error details if there are failures
        if [ $scenario_failed -gt 0 ]; then
            cat >> "$test_dir/scenario_report.html" << EOF
            
            <button type="button" class="collapsible" onclick="toggleContent(this)">▶ Show Error Details ($scenario_failed errors)</button>
            <div class="content">
                <h4>Error Analysis:</h4>
EOF

            # Collect unique request/response/error combinations
            local temp_combinations=$(mktemp)
            local temp_details=$(mktemp)
            
            # Process all failed requests to extract unique patterns
            for request_file in "${scenario_requests[@]}"; do
                if grep -q '"error":' "$request_file"; then
                    local model=$(jq -r ".model // \"$DEFAULT_MODEL\"" "$request_file" 2>/dev/null)
                    local error_msg=$(jq -r '.error // "Unknown error"' "$request_file" 2>/dev/null | head -1)
                    
                    # Create standardized request body (what was sent to API)
                    local request_body=$(jq -n \
                        --arg model "$model" \
                        '{
                             model: $model,
                             messages: [
                                 {role: "system", content: "You are a helpful assistant."},
                                 {role: "user", content: "Tell me about artificial intelligence in one sentence."}
                             ],
                             stream: false
                         }')
                    
                    # Try to extract response if available (for non-HTTP errors)
                    local response_content=""
                    if jq -e '.response' "$request_file" > /dev/null 2>&1; then
                        response_content=$(jq -c '.response' "$request_file" 2>/dev/null)
                    else
                        response_content="null"
                    fi
                    
                    # Create a unique combination key
                    local combo_key=$(echo "${model}||${error_msg}" | md5sum | cut -d' ' -f1)
                    
                    # Store combination details
                    echo "$combo_key" >> "$temp_combinations"
                    if ! grep -q "^$combo_key:" "$temp_details" 2>/dev/null; then
                        # Base64 encode the components to handle special characters safely
                        local encoded_error=$(echo "$error_msg" | base64)
                        local encoded_request=$(echo "$request_body" | base64)
                        local encoded_response=$(echo "$response_content" | base64)
                        echo "$combo_key:$model:$encoded_error:$encoded_request:$encoded_response" >> "$temp_details"
                    fi
                fi
            done
            
            # Generate unique error pattern reports
            local pattern_count=0
            while read -r line; do
                if [ -z "$line" ]; then continue; fi
                
                # Split the line using : as delimiter
                IFS=':' read -r combo_key model encoded_error encoded_request encoded_response <<< "$line"
                
                if [ -z "$combo_key" ]; then continue; fi
                pattern_count=$((pattern_count + 1))
                local occurrence_count=$(grep -c "^$combo_key$" "$temp_combinations")
                
                # Base64 decode the components
                local error_msg=$(echo "$encoded_error" | base64 -d 2>/dev/null || echo "$encoded_error")
                local request_body=$(echo "$encoded_request" | base64 -d 2>/dev/null || echo "$encoded_request")
                local response_content=$(echo "$encoded_response" | base64 -d 2>/dev/null || echo "$encoded_response")
                
                cat >> "$test_dir/scenario_report.html" << EOF
            <div class="error-detail">
                <strong>Error Pattern #$pattern_count ($occurrence_count occurrences):</strong><br>
                <strong>Model:</strong> $model<br>
                <strong>Error:</strong> $(echo "$error_msg" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')<br>
                
                <button type="button" class="collapsible" onclick="toggleContent(this)" style="margin-top: 10px; background-color: #fff3cd;">▶ Show Request/Response Details</button>
                <div class="content" style="background-color: #fffbf0; margin-top: 5px;">
                    <h5>Request Body:</h5>
                    <pre style="background: #f8f9fa; padding: 10px; border-radius: 3px; overflow-x: auto; font-size: 0.8em;">$(echo "$request_body" | jq '.' 2>/dev/null | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' || echo "$request_body" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>
EOF
                
                if [ -n "$response_content" ] && [ "$response_content" != "null" ] && [ "$response_content" != "" ]; then
                    cat >> "$test_dir/scenario_report.html" << EOF
                    <h5>Response Body:</h5>
                    <pre style="background: #f8f9fa; padding: 10px; border-radius: 3px; overflow-x: auto; font-size: 0.8em;">$(echo "$response_content" | jq '.' 2>/dev/null | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' || echo "$response_content" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>
EOF
                else
                    cat >> "$test_dir/scenario_report.html" << EOF
                    <h5>Response Body:</h5>
                    <pre style="background: #f8f9fa; padding: 10px; border-radius: 3px; overflow-x: auto; font-size: 0.8em; color: #666;">No response received (likely connection/HTTP error)</pre>
EOF
                fi
                
                cat >> "$test_dir/scenario_report.html" << EOF
                </div>
            </div>
EOF
            done < "$temp_details"
            
            # Clean up temp files
            rm -f "$temp_combinations" "$temp_details"
            
            cat >> "$test_dir/scenario_report.html" << EOF
            </div>
EOF
        fi
        
        cat >> "$test_dir/scenario_report.html" << EOF
        </div>
    </li>
EOF
    done
    
    cat >> "$test_dir/scenario_report.html" << EOF
    </ol>
EOF
    
    # Add summary recommendations
    cat >> "$test_dir/scenario_report.html" << EOF
    
    <h2>📋 Summary & Recommendations</h2>
    
    <div class="scenario-section">
        <h3>Test Results Summary</h3>
        <p>This test analyzed <strong>$total_requests</strong> total API requests across multiple scenarios.</p>
        $(if [ $total_failed -gt 0 ]; then
            echo "<p class=\"warning\"><strong>Issues Detected:</strong> $total_failed requests failed ($total_successful successful). This indicates potential API reliability issues.</p>"
            if [ $total_successful -eq 0 ]; then
                echo "<p class=\"failure\"><strong>Critical:</strong> Zero successful requests suggests complete API infrastructure failure.</p>"
            fi
        else
            echo "<p class=\"success\"><strong>All requests successful!</strong> API is performing well under all tested load scenarios.</p>"
        fi)
        
        <h4>Key Findings:</h4>
        <ul>
EOF

    # Generate dynamic recommendations based on results
    if [ $total_failed -gt 0 ]; then
        cat >> "$test_dir/scenario_report.html" << EOF
            <li>API reliability issues detected - $total_failed out of $total_requests requests failed</li>
            <li>Success rate of $success_rate% $([ $(echo "$success_rate < 90" | bc -l 2>/dev/null || echo 1) -eq 1 ] && echo "is below recommended 90% threshold")</li>
EOF
        if [ $total_successful -eq 0 ]; then
            cat >> "$test_dir/scenario_report.html" << EOF
            <li style="color: red;"><strong>Critical Infrastructure Failure:</strong> No successful requests across any scenario</li>
            <li style="color: red;"><strong>Immediate Action Required:</strong> Complete system investigation needed</li>
EOF
        fi
    else
        cat >> "$test_dir/scenario_report.html" << EOF
            <li style="color: green;">Excellent API reliability - 100% success rate across all scenarios</li>
            <li style="color: green;">All load patterns (serial, concurrent, multi-key, multi-model) performing well</li>
EOF
    fi
    
    cat >> "$test_dir/scenario_report.html" << EOF
        </ul>
    </div>
    
    <div class="summary">
        <h3>Test Metadata</h3>
        <p><strong>Test Directory:</strong> $test_dir</p>
        <p><strong>Report Generated:</strong> $(date)</p>
        <p><strong>Total Test Duration:</strong> $(find "$test_dir" -name "summary.json" -exec jq -r '.duration' {} \; | awk '{sum += $1} END {printf "%.2f seconds", sum}')</p>
    </div>
    
</body>
</html>
EOF

    log_info "Comprehensive HTML report with dynamic error analysis generated at $test_dir/scenario_report.html"
}

# Get scenario purpose description
get_scenario_purpose() {
    case "$1" in
        "1a"|"1b") echo "Test API performance with a single key under serial load" ;;
        "2a"|"2b") echo "Test API performance with a single key under concurrent load" ;;
        "3a"|"3b") echo "Test API performance with multiple keys under serial load per key" ;;
        "4a"|"4b") echo "Test API performance with multiple keys under concurrent load per key" ;;
        "5a"|"5b") echo "Test API performance with multiple keys using different models under serial load" ;;
        "6a"|"6b") echo "Test API performance with multiple keys using different models under concurrent load" ;;
        *) echo "Unknown scenario purpose" ;;
    esac
}

# Main function
main() {
    log_info "Starting Morpheus API Scenario Testing"
    
    # Check prerequisites
    if ! check_prerequisites; then
        log_error "Prerequisites check failed. Exiting."
        exit 1
    fi
    
    # Create test directory
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local test_dir="$RESULTS_DIR/scenario_test_$timestamp"
    mkdir -p "$test_dir"
    
    log_info "Test results will be saved to: $test_dir"
    
    # Prepare API key files for testing
    prepare_api_keys "$test_dir"
    
    # Run all scenarios
    run_scenario_1 "$test_dir"
    run_scenario_2 "$test_dir"
    run_scenario_3 "$test_dir"
    run_scenario_4 "$test_dir"
    run_scenario_5 "$test_dir"
    run_scenario_6 "$test_dir"
    
    # Generate comprehensive report
    generate_report "$test_dir"
    
    log_info "All scenarios completed successfully!"
    log_info "Results available at: $test_dir"
    log_info "HTML report available at: $test_dir/scenario_report.html"
}

# Run main function
main "$@" 