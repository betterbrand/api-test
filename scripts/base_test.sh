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
    
    # Extract first 5 API keys for multi-key scenarios
    jq '{api_keys: .api_keys[0:5]}' "$API_KEYS_FILE" > "$test_dir/five_keys.json"
    
    # Create 5 keys with different models assigned
    jq --argjson models '["'"${MODELS[0]}"'","'"${MODELS[1]}"'","'"${MODELS[2]}"'","'"${MODELS[3]}"'","'"${MODELS[4]}"'"]' '
    {
        api_keys: [
            .api_keys[0:5][] | . + {model: $models[.api_keys | map(.id == .id) | index(true)]}
        ]
    }' "$API_KEYS_FILE" > "$test_dir/five_keys_models.json"
}

# Send a single request with custom model support
send_single_request() {
    local api_key="$1"
    local conversation_id="$2"
    local result_file="$3"
    local model="${4:-default}"
    
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
    
    # Process the response
    if [ $status -eq 0 ] && ! jq -e '.error' "$response_file" > /dev/null 2>&1; then
        # Success
        jq -n \
            --arg conversation_id "$conversation_id" \
            --arg status "$status" \
            --arg duration "$duration" \
            --arg model "$model" \
            --slurpfile response "$response_file" \
            '{conversation_id: $conversation_id, status: $status, duration: $duration, model: $model, response: $response[0]}' > "$result_file"
    else
        # Error
        local error_msg="Request failed"
        if [ $status -eq 0 ]; then
            error_msg=$(jq -r '.error.message // .error // "Unknown API error"' "$response_file")
        else
            error_msg="HTTP request failed with status $status"
        fi
        
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
    
    seq 1 10 | parallel -j10 \
        "$(declare -f send_single_request); send_single_request '$api_key' 'conv_${key_id}_{}' '$scenario_2a_dir/request_{}.json'"
    
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
        "$(declare -f send_single_request); send_single_request '$api_key' 'conv_${key_id}_{}' '$scenario_2b_dir/request_{}.json'"
    
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
    
    jq -n \
        --arg scenario "3a" \
        --arg description "5 keys, 10 serial requests per key (50 total)" \
        --arg total_requests "50" \
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
    
    jq -n \
        --arg scenario "3b" \
        --arg description "5 keys, 20 serial requests per key (100 total)" \
        --arg total_requests "100" \
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
    
    jq -c '.api_keys[]' "$test_dir/five_keys.json" | parallel -j5 '
        key_data={}
        api_key=$(echo "$key_data" | jq -r .key)
        key_id=$(echo "$key_data" | jq -r .id)
        
        mkdir -p "'"$scenario_4a_dir"'/$key_id"
        
        seq 1 10 | parallel -j10 \
            "$(declare -f send_single_request); send_single_request \"$api_key\" \"conv_${key_id}_{}\" \"'"$scenario_4a_dir"'/$key_id/request_{}.json\""
    '
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    jq -n \
        --arg scenario "4a" \
        --arg description "5 keys, 10 concurrent requests per key (50 total)" \
        --arg total_requests "50" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_4a_dir/summary.json"
    
    # 4b: 20 requests per key concurrently (100 total)
    local scenario_4b_dir="$scenario_dir/4b_5keys_concurrent_20_each"
    mkdir -p "$scenario_4b_dir"
    
    log_info "Scenario 4b: 20 concurrent requests per key (100 total)"
    start_time=$(date +%s.%N)
    
    jq -c '.api_keys[]' "$test_dir/five_keys.json" | parallel -j5 '
        key_data={}
        api_key=$(echo "$key_data" | jq -r .key)
        key_id=$(echo "$key_data" | jq -r .id)
        
        mkdir -p "'"$scenario_4b_dir"'/$key_id"
        
        seq 1 20 | parallel -j20 \
            "$(declare -f send_single_request); send_single_request \"$api_key\" \"conv_${key_id}_{}\" \"'"$scenario_4b_dir"'/$key_id/request_{}.json\""
    '
    
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc)
    
    jq -n \
        --arg scenario "4b" \
        --arg description "5 keys, 20 concurrent requests per key (100 total)" \
        --arg total_requests "100" \
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
    
    jq -n \
        --arg scenario "5a" \
        --arg description "5 keys with different models, 10 serial requests per key (50 total)" \
        --arg total_requests "50" \
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
    
    jq -n \
        --arg scenario "5b" \
        --arg description "5 keys with different models, 20 serial requests per key (100 total)" \
        --arg total_requests "100" \
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
    
    jq -c '.api_keys[]' "$test_dir/five_keys_models.json" | parallel -j5 '
        key_data={}
        api_key=$(echo "$key_data" | jq -r .key)
        key_id=$(echo "$key_data" | jq -r .id)
        model=$(echo "$key_data" | jq -r .model)
        
        mkdir -p "'"$scenario_6a_dir"'/$key_id"
        
        seq 1 10 | parallel -j10 \
            "$(declare -f send_single_request); send_single_request \"$api_key\" \"conv_${key_id}_{}\" \"'"$scenario_6a_dir"'/$key_id/request_{}.json\" \"$model\""
    '
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    jq -n \
        --arg scenario "6a" \
        --arg description "5 keys with different models, 10 concurrent requests per key (50 total)" \
        --arg total_requests "50" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_6a_dir/summary.json"
    
    # 6b: 20 requests per key concurrently (100 total)
    local scenario_6b_dir="$scenario_dir/6b_5keys_models_concurrent_20_each"
    mkdir -p "$scenario_6b_dir"
    
    log_info "Scenario 6b: 20 concurrent requests per key with different models (100 total)"
    start_time=$(date +%s.%N)
    
    jq -c '.api_keys[]' "$test_dir/five_keys_models.json" | parallel -j5 '
        key_data={}
        api_key=$(echo "$key_data" | jq -r .key)
        key_id=$(echo "$key_data" | jq -r .id)
        model=$(echo "$key_data" | jq -r .model)
        
        mkdir -p "'"$scenario_6b_dir"'/$key_id"
        
        seq 1 20 | parallel -j20 \
            "$(declare -f send_single_request); send_single_request \"$api_key\" \"conv_${key_id}_{}\" \"'"$scenario_6b_dir"'/$key_id/request_{}.json\" \"$model\""
    '
    
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc)
    
    jq -n \
        --arg scenario "6b" \
        --arg description "5 keys with different models, 20 concurrent requests per key (100 total)" \
        --arg total_requests "100" \
        --arg duration "$duration" \
        '{scenario: $scenario, description: $description, total_requests: $total_requests | tonumber, duration: $duration | tonumber}' > "$scenario_6b_dir/summary.json"
}

# Generate comprehensive report
generate_report() {
    local test_dir="$1"
    
    log_info "Generating comprehensive test report"
    
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
    
    for request_file in $(find "$test_dir" -name "request_*.json"); do
        total_requests=$((total_requests + 1))
        if grep -q '"error":' "$request_file"; then
            total_failed=$((total_failed + 1))
        else
            total_successful=$((total_successful + 1))
        fi
    done
    
    # Generate HTML report
    cat > "$test_dir/scenario_report.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Morpheus API Scenario Test Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1, h2 { color: #333; }
        .summary { background: #f5f5f5; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
        .scenario { background: #f9f9f9; padding: 10px; margin: 10px 0; border-left: 4px solid #007cba; }
        .success { color: green; font-weight: bold; }
        .failure { color: red; font-weight: bold; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 20px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
        tr:nth-child(even) { background-color: #f9f9f9; }
    </style>
</head>
<body>
    <h1>Morpheus API Scenario Test Report</h1>
    
    <div class="summary">
        <h2>Overall Test Summary</h2>
        <p>Test conducted on: <strong>$(date '+%Y-%m-%d %H:%M:%S')</strong></p>
        <p>Total requests across all scenarios: <strong>$total_requests</strong></p>
        <p>Successful requests: <strong class="success">$total_successful</strong></p>
        <p>Failed requests: <strong class="failure">$total_failed</strong></p>
        <p>Success rate: <strong>$(echo "scale=2; $total_successful * 100 / $total_requests" | bc -l 2>/dev/null || echo 0)%</strong></p>
    </div>
    
    <h2>Scenario Results</h2>
    
    <table>
        <tr>
            <th>Scenario</th>
            <th>Description</th>
            <th>Total Requests</th>
            <th>Duration (seconds)</th>
            <th>Requests/Second</th>
        </tr>
EOF

    # Add scenario rows to the table
    echo "[$all_summaries]" | jq -c '.[]' | while read -r scenario; do
        local scenario_id=$(echo "$scenario" | jq -r '.scenario')
        local description=$(echo "$scenario" | jq -r '.description')
        local total_req=$(echo "$scenario" | jq -r '.total_requests')
        local duration=$(echo "$scenario" | jq -r '.duration')
        local rps=$(echo "scale=2; $total_req / $duration" | bc -l 2>/dev/null || echo 0)
        
        cat >> "$test_dir/scenario_report.html" << EOF
        <tr>
            <td>$scenario_id</td>
            <td>$description</td>
            <td>$total_req</td>
            <td>$duration</td>
            <td>$rps</td>
        </tr>
EOF
    done
    
    cat >> "$test_dir/scenario_report.html" << EOF
    </table>
    
    <h2>Scenario Details</h2>
EOF

    # Add detailed scenario information
    echo "[$all_summaries]" | jq -c '.[]' | while read -r scenario; do
        local scenario_id=$(echo "$scenario" | jq -r '.scenario')
        local description=$(echo "$scenario" | jq -r '.description')
        
        cat >> "$test_dir/scenario_report.html" << EOF
    <div class="scenario">
        <h3>Scenario $scenario_id</h3>
        <p><strong>Description:</strong> $description</p>
        <p><strong>Purpose:</strong> $(get_scenario_purpose "$scenario_id")</p>
    </div>
EOF
    done
    
    cat >> "$test_dir/scenario_report.html" << EOF
</body>
</html>
EOF

    log_info "HTML report generated at $test_dir/scenario_report.html"
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