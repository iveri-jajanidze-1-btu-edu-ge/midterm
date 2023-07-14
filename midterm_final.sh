#!/bin/bash

# Set shell options
set -o errexit      # Exit immediately if a command fails
set -o nounset      # Treat unset variables as an error
set -o pipefail     # Return value of the last (rightmost) command to exit with a non-zero status

# Enable tracing if BASH_TRACE environment variable is set to 1
if [[ "${BASH_TRACE:-0}" == "1" ]]; then
    set -o xtrace
fi

# Check if the GITHUB_PERSONAL_ACCESS_TOKEN environment variable is set
if [ -z "$GITHUB_PERSONAL_ACCESS_TOKEN" ]; then
    echo "GITHUB_PERSONAL_ACCESS_TOKEN environment variable is missing!"
    exit 1
fi

# Change to the directory where the script is located
cd "$(dirname "$0")"

# Check if the script was provided with exactly four arguments
if [ "$#" -eq 4 ]; then
    echo > /dev/null
else
    echo "The script was not provided with four arguments, exiting..."
    echo "Usage: ./mid-term.sh CODE_REPO_URL CODE_BRANCH_NAME REPORT_REPO_URL REPORT_BRANCH_NAME"
    exit 1
fi

# Assign input arguments to variables
CODE_REPO_URL="$1"
CODE_BRANCH_NAME="$2"
REPORT_REPO_URL="$3"
REPORT_BRANCH_NAME="$4"

# Extract repository names and owner from repository URLs
REPOSITORY_NAME_CODE=$(basename "$CODE_REPO_URL" .git)
REPOSITORY_OWNER=$(echo "$CODE_REPO_URL" | awk -F':' '{print $2}' | awk -F'/' '{print $1}')
REPOSITORY_NAME_REPORT=$(basename "$REPORT_REPO_URL" .git)

# Create temporary directories to clone repositories
REPOSITORY_PATH_CODE=$(mktemp --directory)
REPOSITORY_PATH_REPORT=$(mktemp --directory)

PYTEST_RESULT=0
BLACK_RESULT=0

# check if the repository or the branch, used for reporting exists:

case $(git ls-remote --exit-code "$CODE_REPO_URL" &> /dev/null; echo $?) in
  0)
    case $(git ls-remote --exit-code --heads "$CODE_REPO_URL" "$CODE_BRANCH_NAME" &> /dev/null; echo $?) in
      0)
        echo > /dev/null
        ;;
      *)
        echo "Branch '$CODE_BRANCH_NAME' does not exist"
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Repository does not exist"
    exit 1
    ;;
esac

case $(git ls-remote --exit-code "$REPORT_REPO_URL" &> /dev/null; echo $?) in
  0)
    echo > /dev/null
    case $(git ls-remote --exit-code --heads "$REPORT_REPO_URL" "$REPORT_BRANCH_NAME" &> /dev/null; echo $?) in
      0)
        echo > /dev/null
        ;;
      *)
        echo "Branch '$REPORT_BRANCH_NAME' does not exist"
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Repository does not exist"
    exit 1
    ;;
esac

# check if pytest and black are installed

if ! pytest --version >/dev/null 2>&1; then
  echo "black is not installed"
  exit 1
fi

if ! black --version >/dev/null 2>&1; then
  echo "pytest is not installed"
  exit 1
fi


# Function to perform cleanup actions
cleanup() {
  echo "Removing the unnecessary: "

  case "$REPOSITORY_PATH_CODE" in
    -*)
      ;;
    *)
      if [ -d "$REPOSITORY_PATH_CODE" ]; then
        rm -rf "$REPOSITORY_PATH_CODE"
        echo "Deleted REPOSITORY_PATH_CODE"
      fi
      ;;
  esac

  case "$REPOSITORY_PATH_REPORT" in
    -*)
      ;;
    *)
      if [ -d "$REPOSITORY_PATH_REPORT" ]; then
        rm -rf "$REPOSITORY_PATH_REPORT"
        echo "Deleted REPOSITORY_PATH_REPORT"
      fi
      ;;
  esac

  case "$PYTEST_REPORT_PATH" in
    -*)
      ;;
    *)
      if [ -f "$PYTEST_REPORT_PATH" ]; then
        rm -rf "$PYTEST_REPORT_PATH"
        echo "Deleted PYTEST_REPORT_PATH"
      fi
      ;;
  esac

  case "$BLACK_REPORT_PATH" in
    -*)
      ;;
    *)
      if [ -f "$BLACK_REPORT_PATH" ]; then
        rm -rf "$BLACK_REPORT_PATH"
        echo "Deleted BLACK_REPORT_PATH"
      fi
      ;;
  esac

  case "$BLACK_OUTPUT_PATH" in
    -*)
      ;;
    *)
      if [ -f "$BLACK_OUTPUT_PATH" ]; then
        rm -rf "$BLACK_OUTPUT_PATH"
        echo "Deleted BLACK_OUTPUT_PATH"
      fi
      ;;
  esac
}


# Set up a trap to call the cleanup function on interrupt, exit, and error
trap cleanup INT EXIT ERR SIGINT SIGTERM

# Function to make a GET request to the GitHub API
function github_api_get_request() {
    curl --request GET \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --output "$2" \
        --silent \
        "$1"
}

# Function to make a POST request to the GitHub API
function github_post_request() {
    curl --request POST \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --header "Content-Type: application/json" \
        --silent \
        --output "$3" \
        --data-binary "@$2" \
        "$1"
}

# Function to update a JSON file using jq
function jq_update() {
    local IO_PATH=$1
    local TEMP_PATH=$(mktemp)
    shift
    cat $IO_PATH | jq "$@" > $TEMP_PATH
    mv $TEMP_PATH $IO_PATH
}

# Clone the code repository to the specified path
git clone $CODE_REPO_URL $REPOSITORY_PATH_CODE

# Change to the code repository directory
cd $REPOSITORY_PATH_CODE

# Switch to the specified branch in the code repository
git switch $CODE_BRANCH_NAME

# Get the hash of the last commit
LAST_COMMIT="$(git log -n 1 --format=%H)"

# Continuously check for new commits
while true; do
    # Fetch the latest changes from the code repository
    git fetch $1 $2 > /dev/null 2>&1

    # Get the hash of the latest commit
    CHECK_COMMIT=$(git rev-parse FETCH_HEAD)

    # Compare the latest commit hash with the last commit hash
    if [ "$CHECK_COMMIT" != "$LAST_COMMIT" ]; then
        # Get the list of commits between the last commit and the latest commit
        COMMITS=$(git log --pretty=format:"%H" --reverse $LAST_COMMIT..$CHECK_COMMIT)
        echo "$COMMITS"
        LAST_COMMIT=$CHECK_COMMIT

        # Process each commit
        for COMMIT in $COMMITS; do
            PYTEST_REPORT_PATH=$(mktemp)
            BLACK_OUTPUT_PATH=$(mktemp)
            BLACK_REPORT_PATH=$(mktemp)

            # Checkout the commit
            git checkout $COMMIT

            # Get the author's email for the commit
            AUTHOR_EMAIL=$(git log -n 1 --format="%ae" HEAD)

            # Run pytest with verbose output and generate an HTML report
            if pytest --verbose --html=$PYTEST_REPORT_PATH --self-contained-html; then
                PYTEST_RESULT=$?
                echo "PYTEST SUCCEEDED $PYTEST_RESULT"
            else
                PYTEST_RESULT=$?
                echo "PYTEST FAILED $PYTEST_RESULT"
            fi

            echo "\$PYTEST_RESULT = $PYTEST_RESULT \$BLACK_RESULT=$BLACK_RESULT"

            # Run black to check the code formatting and generate a diff
            if black --check --diff *.py > $BLACK_OUTPUT_PATH; then
                BLACK_RESULT=$?
                echo "BLACK SUCCEEDED $BLACK_RESULT"
            else
                BLACK_RESULT=$?
                echo "BLACK FAILED $BLACK_RESULT"
                cat $BLACK_OUTPUT_PATH | pygmentize -l diff -f html -O full,style=solarized-light -o $BLACK_REPORT_PATH
            fi

            echo "\$PYTEST_RESULT = $PYTEST_RESULT \$BLACK_RESULT=$BLACK_RESULT"

            # Clone the report repository if it doesn't exist
            if [ "$(ls -A "$REPOSITORY_PATH_REPORT")" ]; then
                echo "Directory $REPOSITORY_PATH_REPORT exists and is not empty. Skipping cloning."
            else
                git clone "$REPORT_REPO_URL" "$REPOSITORY_PATH_REPORT"
            fi

            pushd $REPOSITORY_PATH_REPORT
            git switch $REPORT_BRANCH_NAME

            # Create a new directory for the report
            REPORT_PATH="${COMMIT}-$(date +%s)"
            mkdir --parents $REPORT_PATH

            # Copy the pytest report to the report directory
            cp $PYTEST_REPORT_PATH "$REPORT_PATH/pytest.html"

            # Copy the black report to the report directory if it exists
            if [ -s "$BLACK_REPORT_PATH" ]; then
                cp $BLACK_REPORT_PATH "$REPORT_PATH/black.html"
            fi

            # Add the report directory to the report repository
            git add $REPORT_PATH
            git commit -m "$COMMIT report."
            git push
            popd

            # Check if either pytest or black failed
            if (( ($PYTEST_RESULT != 0) || ($BLACK_RESULT != 0) )); then
                AUTHOR_USERNAME=""
                RESPONSE_PATH=$(mktemp)

                # Get the GitHub username associated with the author's email
                github_api_get_request "https://api.github.com/search/users?q=$AUTHOR_EMAIL" $RESPONSE_PATH

                TOTAL_USER_COUNT=$(cat $RESPONSE_PATH | jq ".total_count")

                if [[ $TOTAL_USER_COUNT == 1 ]]; then
                    USER_JSON=$(cat $RESPONSE_PATH | jq ".items[0]")
                    AUTHOR_USERNAME=$(cat $RESPONSE_PATH | jq --raw-output ".items[0].login")
                fi

                REQUEST_PATH=$(mktemp)
                RESPONSE_PATH=$(mktemp)
                echo "{}" > $REQUEST_PATH

                BODY+="Automatically generated message\n\n"

                if (( $PYTEST_RESULT != 0 )); then
                    if (( $BLACK_RESULT != 0 )); then
                        if [[ "$PYTEST_RESULT" -eq "5" ]]; then
                            TITLE="${COMMIT::7} Unit tests do not exist in the repository or do not work correctly and formatting test failed."
                            BODY+="${COMMIT} Unit tests do not exist in the repository or do not work correctly and formatting test failed.\n"
                        else
                            TITLE="${COMMIT::7} failed unit and formatting tests."
                            BODY+="${COMMIT} failed unit and formatting tests.\n"
                            jq_update $REQUEST_PATH '.labels = ["res_pytest", "res_black"]'
                        fi
                    else
                        if [[ "$PYTEST_RESULT" -eq "5" ]]; then
                            TITLE="${COMMIT::7} Unit tests do not exist in the repository or do not work correctly and formatting test passed."
                            BODY+="${COMMIT} Unit tests do not exist in the repository or do not work correctly and formatting test passed.\n"
                        else
                            TITLE="${COMMIT::7} failed unit tests."
                            BODY+="${COMMIT} failed unit tests.\n"
                            jq_update $REQUEST_PATH '.labels = ["res_pytest"]'
                        fi
                    fi
                else
                    TITLE="${COMMIT::7} failed formatting test."
                    BODY+="${COMMIT} failed formatting test.\n"
                    jq_update $REQUEST_PATH '.labels = ["res_black"]'
                fi

                BODY+="Pytest report: https://${REPOSITORY_OWNER}.github.io/${REPOSITORY_NAME_REPORT}/$REPORT_PATH/pytest.html\n"

                if [ -s "$BLACK_REPORT_PATH" ]; then
                    BODY+="Black report: https://${REPOSITORY_OWNER}.github.io/${REPOSITORY_NAME_REPORT}/$REPORT_PATH/black.html\n"
                fi

                jq_update $REQUEST_PATH --arg title "$TITLE" '.title = $title'
                jq_update $REQUEST_PATH --arg body  "$BODY"  '.body = $body'

                if [[ ! -z $AUTHOR_USERNAME ]]; then
                    jq_update $REQUEST_PATH --arg username "$AUTHOR_USERNAME" '.assignees = [$username]'
                fi

                # Send a POST request to create an issue on the code repository
                github_post_request "https://api.github.com/repos/${REPOSITORY_OWNER}/${REPOSITORY_NAME_CODE}/issues" $REQUEST_PATH $RESPONSE_PATH

                # Print the URL of the created issue
                cat $RESPONSE_PATH | jq ".html_url"

                # Clean up temporary files and directories
                rm $RESPONSE_PATH
                rm $REQUEST_PATH
                BODY=""
                rm -r -f $PYTEST_REPORT_PATH
                rm -r -f $BLACK_OUTPUT_PATH
                rm -r -f $BLACK_REPORT_PATH
                rm -r -f $REPORT_PATH
            else
                REMOTE_NAME=$(git remote)
                git tag --force "${CODE_BRANCH_NAME}-result-successful" $COMMIT
                git push --force $REMOTE_NAME --tags           
            fi
        done
    fi

    # Wait for 15 seconds before checking for new commits again
    sleep 15
done
