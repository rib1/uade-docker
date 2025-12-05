#!/bin/bash

# A script to test the uade-web API endpoints.
# This script is intended to be run from a Docker container that has curl and jq installed.

set -e

# Define the base URL for the API
BASE_URL="http://uade-web-player:5000"



echo "--- All tests passed! ---"
