#!/bin/bash
# test-api-credential.sh
#
# Standalone, manual pre-flight check for a 3rd-party API credential —
# run this BEFORE add-agent.sh/master-setup.sh, before the credential ever
# touches Secrets Manager. Nothing here writes to AWS; it's read-only
# against the 3rd-party API itself.
#
# Usage: bash test-api-credential.sh

set -e

echo "=================================================="
echo " API Credential Test"
echo "=================================================="
echo ""
echo "This tests a credential against a real API before you store it."
echo "Nothing is saved anywhere — this is a one-time check."
echo ""

echo "Auth type:"
echo "  1) Bearer token           (one string, e.g. HubSpot private app token)"
echo "  2) OAuth2 client-credentials  (account/client id + secret, e.g. Zoom Server-to-Server)"
echo "  3) Basic auth             (username + password)"
echo "  4) API key in query param (e.g. ?api_key=...)"
read -p "Choose (1-4): " AUTH_TYPE < /dev/tty
echo ""

case "$AUTH_TYPE" in

  1)
    read -s -p "Bearer token: " TOKEN < /dev/tty
    echo ""
    read -p "Test URL (a real, low-risk GET endpoint, e.g. https://api.hubapi.com/crm/v3/objects/contacts?limit=1): " TEST_URL < /dev/tty
    echo ""
    echo "Testing..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $TOKEN" "$TEST_URL")
    STATUS=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    ;;

  2)
    read -p "Token endpoint URL (e.g. https://zoom.us/oauth/token): " TOKEN_URL < /dev/tty
    read -p "Does the token endpoint need an account_id query param? (y/n): " NEEDS_ACCOUNT < /dev/tty
    if [ "$NEEDS_ACCOUNT" = "y" ]; then
      read -p "Account ID: " ACCOUNT_ID < /dev/tty
      GRANT_QUERY="grant_type=account_credentials&account_id=${ACCOUNT_ID}"
    else
      GRANT_QUERY="grant_type=client_credentials"
    fi
    read -p "Client ID: " CLIENT_ID < /dev/tty
    read -s -p "Client Secret: " CLIENT_SECRET < /dev/tty
    echo ""
    echo ""
    echo "Exchanging for access token..."
    TOKEN_RESPONSE=$(curl -s -X POST "${TOKEN_URL}?${GRANT_QUERY}" \
      -H "Authorization: Basic $(printf '%s' "${CLIENT_ID}:${CLIENT_SECRET}" | base64)")
    ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

    if [ -z "$ACCESS_TOKEN" ]; then
      echo ""
      echo "✗ Token exchange failed. Raw response:"
      echo "$TOKEN_RESPONSE"
      exit 1
    fi
    echo "  ✓ Access token obtained"
    echo ""
    read -p "Test URL (a real, low-risk GET endpoint to call with the access token): " TEST_URL < /dev/tty
    echo ""
    echo "Testing..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $ACCESS_TOKEN" "$TEST_URL")
    STATUS=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    ;;

  3)
    read -p "Username: " BASIC_USER < /dev/tty
    read -s -p "Password: " BASIC_PASS < /dev/tty
    echo ""
    read -p "Test URL: " TEST_URL < /dev/tty
    echo ""
    echo "Testing..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -u "${BASIC_USER}:${BASIC_PASS}" "$TEST_URL")
    STATUS=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    ;;

  4)
    read -s -p "API key: " API_KEY < /dev/tty
    echo ""
    read -p "Query param name (e.g. api_key): " PARAM_NAME < /dev/tty
    read -p "Test URL WITHOUT the query param (it will be appended): " BASE_URL < /dev/tty
    echo ""
    SEP="?"
    [[ "$BASE_URL" == *"?"* ]] && SEP="&"
    TEST_URL="${BASE_URL}${SEP}${PARAM_NAME}=${API_KEY}"
    echo "Testing..."
    RESPONSE=$(curl -s -w "\n%{http_code}" "$TEST_URL")
    STATUS=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    ;;

  *)
    echo "Invalid choice."
    exit 1
    ;;
esac

echo ""
echo "=================================================="
echo " Result"
echo "=================================================="
echo ""
echo "HTTP status: $STATUS"
echo ""

if [[ "$STATUS" =~ ^2 ]]; then
  echo "✓ PASS — credential works against this endpoint."
elif [ "$STATUS" = "401" ]; then
  echo "✗ FAIL — 401 Unauthorized. The credential is invalid, expired, or revoked."
elif [ "$STATUS" = "403" ]; then
  echo "✗ FAIL — 403 Forbidden. Credential is valid but lacks permission/scope for this endpoint."
elif [ "$STATUS" = "404" ]; then
  echo "⚠ 404 Not Found — check the test URL itself; this may not indicate a bad credential."
else
  echo "✗ FAIL — unexpected status. Response body below:"
fi

echo ""
echo "Response body (truncated to 500 chars):"
echo "${BODY:0:500}"
echo ""
echo "No credentials were stored or saved anywhere by this script."
