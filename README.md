# Morapi - Morpheus API Gateway Load Testing Suite

## Overview
Morapi is a collection of shell-based scripts designed to automate functional and load/performance testing of the Morpheus Compute Marketplace API Gateway Chat API. With Morapi, you can:

- Generate API keys at scale
- Validate API endpoints and authentication flows
- Run single and batch conversation tests
- Conduct high-throughput load tests with concurrent requests
- Collect and analyze detailed performance metrics
- Generate human-readable reports

## Project Goals
- **Automation**: Provide repeatable, script-driven testing without manual intervention.
- **Scalability**: Support variable load sizes from a few conversations to thousands.
- **Flexibility**: Easily customize prompts, request parameters, and concurrency settings.
- **Data Collection**: Capture detailed timing, status, and error information for analysis.
- **Developer-Friendly**: Simple, portable scripts with minimal dependencies.

## Repository Structure
```text
morapi/
├── .env                  # Environment variables (generated from .env.example)
├── .env.example          # Template for environment configuration
├── README.md             # Project documentation (this file)
├── setup.sh              # One-time setup and dependency check
├── requirements.txt      # Project dependencies (none for Python)
├── data/                 # Data files
│   ├── api_keys.json     # Generated API keys (output of generate_keys.sh)
│   └── api_keys_temp.json# Temporary/test API keys
├── results/              # Output directory for test runs
├── scripts/              # Automation and test scripts
│   ├── generate_keys.sh      # Generate API keys via web interface
│   ├── load_test.sh          # Perform concurrent load testing
│   ├── test_api.sh           # Verify API endpoints and auth flows
│   ├── test_single_call.sh   # Test a single chat call
│   └── test_key_generation.sh# Test API key generation script
└── requirements.txt      # Python dependencies (none)
```

## Prerequisites
- Bash (v4 or later)
- curl
- jq
- GNU parallel
- bc
- flock (for safe file locking)
- grep, sed, awk (standard Unix utilities)

Install missing tools via your package manager. Example for macOS:
```bash
brew install curl jq parallel bc
```

## Setup
1. Clone the repository:
   ```bash
   git clone https://github.com/your-org/morapi.git
   cd morapi
   ```
2. Run the setup script to verify dependencies and create `.env`:
   ```bash
   ./setup.sh
   ```
3. Edit `.env` to configure:
   - `API_BASE_URL` — Base URL of the Morpheus API
   - `MAX_CONCURRENT_REQUESTS` — Max parallel chat requests
   - `MAX_WORKERS` — Number of worker processes
   - `NUM_KEYS` — Number of keys to generate
   - `ACCOUNT_EMAIL` & `ACCOUNT_PASSWORD` — Credentials for key generation

## Usage

### 1. Generate API Keys
Automatically create and store API keys:
```bash
./scripts/generate_keys.sh
```
- Generates `NUM_KEYS` keys (default: 1000)
- Stores results in `data/api_keys.json`
- Override with environment variables `NUM_KEYS` and `PARALLEL_WORKERS`
- **Note:** The `scripts/generate_keys.sh` script is incomplete and needs further testing and bugfixing; until then, manually create and populate `data/api_keys.json` or `data/api_keys_temp.json` with valid API key entries for testing.

### 2. Functional API Tests
- **Verify endpoints**:
  ```bash
  ./scripts/test_api.sh
  ```
- **Test single chat call**:
  ```bash
  ./scripts/test_single_call.sh
  ```
- **Test key generation**:
  ```bash
  ./scripts/test_key_generation.sh
  ```

### 3. Load Testing
Execute concurrent conversations using generated keys:
```bash
./scripts/load_test.sh
```
- Splits `data/api_keys.json` into batches
- Runs up to `MAX_CONCURRENT_REQUESTS` in parallel
- Stores results under `results/test_<timestamp>/`
- Summary JSON and HTML report generated for analysis

## Results and Reporting
After a load test, view:
- `results/test_<timestamp>/summary.json` — Machine-readable summary
- `results/test_<timestamp>/report.html` — Human-friendly HTML report with metrics

Fields in `summary.json`:
- `total_conversations`
- `successful_conversations`
- `failed_conversations`
- `total_exchanges`
- `successful_exchanges`
- `failed_exchanges`
- `total_test_duration`
- `average_conversation_time`

## Contributing
- **Add new prompts**: Edit `CONVERSATION_PROMPTS` array in `scripts/load_test.sh`.
- **Extend tests**: Create new scripts following the naming convention `test_*.sh`.
- **Follow shell best practices**: Quote variables, check exit codes, use logging helpers.
- Submit pull requests and report issues via GitHub.

## Troubleshooting
- **GNU Parallel citation notice**: Run `parallel --citation` or the script suppresses it automatically.
- **Key generation failures**: Ensure `ACCOUNT_EMAIL` & `ACCOUNT_PASSWORD` are correct in `.env`.
- **Endpoint errors**: Verify `API_BASE_URL` and network connectivity.
- **Missing dependencies**: Run `./setup.sh` again.

## License
Specify your project's license here (e.g., MIT, Apache 2.0).

## Acknowledgements
- GNU Parallel — citation 20250422 ("Tariffs")
- Contributors and testers 