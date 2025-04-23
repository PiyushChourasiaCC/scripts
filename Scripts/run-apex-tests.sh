#!/bin/bash


# run_salesforce_tests.sh
# A script to run Salesforce Apex tests with various options


# Default values
TARGET_ORG=""  # Will use default configured org if not specified
TEST_LEVEL="RunLocalTests"  # Default test level
FORMAT="human"             # Default output format
OUTPUT_DIR="test-results"  # Default output directory
CODE_COVERAGE=false        # Code coverage disabled by default
DETAILED_COVERAGE=false    # Detailed coverage disabled by default
SYNCHRONOUS=true          # Run tests synchronously by default
CONCISE=false              # Full output by default
WAIT_TIME=10                # Set a default wait time of 10 minutes


# Function to display usage information
show_help() {
   echo "Usage: ./run_salesforce_tests.sh [options]"
   echo ""
   echo "Options:"
   echo "  -o, --org <alias>            Target Salesforce org alias"
   echo "  -c, --class <classname>      Specific test class to run (can be used multiple times)"
   echo "  -s, --suite <suitename>      Test suite to run (can be used multiple times)"
   echo "  -t, --test <classname.method> Specific test method to run (can be used multiple times)"
   echo "  -l, --level <level>          Test level: RunLocalTests, RunAllTestsInOrg, RunSpecifiedTests"
   echo "  -f, --format <format>        Result format: human, tap, junit, json"
   echo "  -d, --dir <directory>        Output directory for test results"
   echo "  -v, --coverage               Include code coverage results"
   echo "  -e, --detailed-coverage      Include detailed code coverage results"
   echo "  -y, --synchronous            Run tests synchronously"
   echo "  -w, --wait <minutes>         Wait time in minutes for test results"
   echo "  -z, --concise                Display only failed test results (works with human format only)"
   echo "  -h, --help                   Show this help message"
   echo ""
   echo "Examples:"
   echo "  Run all local tests:"
   echo "    ./run_salesforce_tests.sh"
   echo ""
   echo "  Run specific test class with code coverage:"
   echo "    ./run_salesforce_tests.sh -c MyTestClass -v"
   echo ""
   echo "  Run tests from multiple classes and get detailed coverage in JSON format:"
   echo "    ./run_salesforce_tests.sh -c Class1 -c Class2 -f json -v -e"
   echo ""
   echo "  Run specific test method:"
   echo "    ./run_salesforce_tests.sh -t MyClass.testMethod"
   echo ""
   echo "  Run tests synchronously with a specific org:"
   echo "    ./run_salesforce_tests.sh -o myOrgAlias -y"
}


# Parse command line arguments
CLASS_NAMES=()
SUITE_NAMES=()
TEST_NAMES=()


while [[ $# -gt 0 ]]; do
   key="$1"
   case $key in
       -o|--org)
           TARGET_ORG="$2"
           shift
           shift
           ;;
       -c|--class)
           CLASS_NAMES+=("$2")
           shift
           shift
           ;;
       -s|--suite)
           SUITE_NAMES+=("$2")
           shift
           shift
           ;;
       -t|--test)
           TEST_NAMES+=("$2")
           shift
           shift
           ;;
       -l|--level)
           TEST_LEVEL="$2"
           shift
           shift
           ;;
       -f|--format)
           FORMAT="$2"
           shift
           shift
           ;;
       -d|--dir)
           OUTPUT_DIR="$2"
           shift
           shift
           ;;
       -v|--coverage)
           CODE_COVERAGE=true
           shift
           ;;
       -e|--detailed-coverage)
           DETAILED_COVERAGE=true
           shift
           ;;
       -y|--synchronous)
           SYNCHRONOUS=true
           shift
           ;;
       -w|--wait)
           WAIT_TIME="$2"
           shift
           shift
           ;;
       -z|--concise)
           CONCISE=true
           shift
           ;;
       -h|--help)
           show_help
           exit 0
           ;;
       *)
           echo "Unknown option: $1"
           show_help
           exit 1
           ;;
   esac
done


# Build the command
CMD="sf apex run test"


# Add target org if specified
if [ -n "$TARGET_ORG" ]; then
   CMD="$CMD --target-org $TARGET_ORG"
fi


# Add test level
CMD="$CMD --test-level $TEST_LEVEL"


# Add class names if specified
for class in "${CLASS_NAMES[@]}"; do
   CMD="$CMD --class-names \"$class\""
done


# Add suite names if specified
for suite in "${SUITE_NAMES[@]}"; do
   CMD="$CMD --suite-names \"$suite\""
done


# Add test names if specified
for test in "${TEST_NAMES[@]}"; do
   CMD="$CMD --tests \"$test\""
done


# Add result format
CMD="$CMD --result-format $FORMAT"


# Add output directory
if [ -n "$OUTPUT_DIR" ]; then
   # Create the output directory if it doesn't exist
   mkdir -p "$OUTPUT_DIR"
   CMD="$CMD --output-dir \"$OUTPUT_DIR\""
fi


# Add code coverage if requested
if [ "$CODE_COVERAGE" = true ]; then
   CMD="$CMD --code-coverage"
fi


# Add detailed coverage if requested
if [ "$DETAILED_COVERAGE" = true ]; then
   CMD="$CMD --detailed-coverage"
fi


# Add synchronous flag if requested
if [ "$SYNCHRONOUS" = true ]; then
   CMD="$CMD --synchronous"
fi


# Add wait time if specified
if [ "$WAIT_TIME" -gt 0 ]; then
   CMD="$CMD --wait $WAIT_TIME"
fi


# Add concise flag if requested
if [ "$CONCISE" = true ]; then
   CMD="$CMD --concise"
fi


# Print the command being executed
echo "Executing: $CMD"
echo "---------------------------------------------"


# Execute the command
eval $CMD


# Check the exit status
exit_status=$?
if [ $exit_status -ne 0 ]; then
   echo "Tests failed with exit code: $exit_status"
   exit $exit_status
fi