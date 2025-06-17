#!/bin/bash
# Setup script for the Morapi project

echo "Setting up Morapi - Morpheus API Load Testing project..."

# Check for required dependencies
echo "Checking required dependencies..."

# Array of required commands
REQUIRED_COMMANDS=("curl" "jq" "parallel" "bc")

# Check each command
MISSING_DEPS=()
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING_DEPS+=("$cmd")
        echo "❌ $cmd is not installed"
    else
        echo "✅ $cmd is installed"
    fi
done

# If missing dependencies, provide installation instructions
if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo ""
    echo "Missing dependencies: ${MISSING_DEPS[*]}"
    echo ""
    echo "Install missing dependencies:"
    echo "  On macOS with Homebrew: brew install ${MISSING_DEPS[*]}"
    echo "  On Debian/Ubuntu: sudo apt-get install ${MISSING_DEPS[*]}"
    echo "  On CentOS/RHEL: sudo yum install ${MISSING_DEPS[*]}"
    echo ""
    echo "Please install the missing dependencies and run this script again."
    exit 1
fi

# Create .env file if it doesn't exist
if [ ! -f ".env" ]; then
    echo "Creating .env file from example..."
    cp .env.example .env
    echo "Please update the .env file with your specific configuration."
fi

# Ensure directories exist
mkdir -p data results

echo "Setup complete!"
echo "You can now run the scripts:"
echo "1. Generate API keys: ./scripts/generate_keys.sh"
echo "2. Run load test: ./scripts/load_test.sh" 