#!/bin/bash

# Legacy disposable-environment helper: creates accounts and prints credentials.
# Never run against production or publish its output. CI uses tests/*.test.ts.
# Test Authentication API Endpoints
# Usage: ./examples/test-auth.sh [base_url]
# Example: ./examples/test-auth.sh http://localhost:8787

BASE_URL=${1:-"http://localhost:8787"}
TEST_EMAIL="test-$(date +%s)@example.com"
TEST_PASSWORD="SecurePassword123"

echo "================================"
echo "Testing Authentication API"
echo "================================"
echo "Base URL: $BASE_URL"
echo "Test Email: $TEST_EMAIL"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test 1: Register
echo -e "${YELLOW}[1/7] Testing Registration${NC}"
REGISTER_RESPONSE=$(curl -s -X POST "$BASE_URL/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}")

echo "Response: $REGISTER_RESPONSE"

if echo "$REGISTER_RESPONSE" | grep -q "access_token"; then
  echo -e "${GREEN}✓ Registration successful${NC}"
  ACCESS_TOKEN=$(echo "$REGISTER_RESPONSE" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)
  REFRESH_TOKEN=$(echo "$REGISTER_RESPONSE" | grep -o '"refresh_token":"[^"]*' | cut -d'"' -f4)
  API_TOKEN=$(echo "$REGISTER_RESPONSE" | grep -o '"api_token":"[^"]*' | cut -d'"' -f4)
  USER_ID=$(echo "$REGISTER_RESPONSE" | grep -o '"user_id":"[^"]*' | cut -d'"' -f4)
  echo "Access Token: ${ACCESS_TOKEN:0:50}..."
  echo "Refresh Token: ${REFRESH_TOKEN:0:50}..."
  echo "API Token: $API_TOKEN"
else
  echo -e "${RED}✗ Registration failed${NC}"
  exit 1
fi

echo ""

# Test 2: Login
echo -e "${YELLOW}[2/7] Testing Login${NC}"
LOGIN_RESPONSE=$(curl -s -X POST "$BASE_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}")

echo "Response: $LOGIN_RESPONSE"

if echo "$LOGIN_RESPONSE" | grep -q "access_token"; then
  echo -e "${GREEN}✓ Login successful${NC}"
  ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)
  NEW_REFRESH_TOKEN=$(echo "$LOGIN_RESPONSE" | grep -o '"refresh_token":"[^"]*' | cut -d'"' -f4)
else
  echo -e "${RED}✗ Login failed${NC}"
  exit 1
fi

echo ""

# Test 3: Get User Info (with JWT)
echo -e "${YELLOW}[3/7] Testing Get User Info (JWT Auth)${NC}"
USER_RESPONSE=$(curl -s -X GET "$BASE_URL/user" \
  -H "Authorization: Bearer $ACCESS_TOKEN")

echo "Response: $USER_RESPONSE"

if echo "$USER_RESPONSE" | grep -q "user_id"; then
  echo -e "${GREEN}✓ JWT authentication working${NC}"
else
  echo -e "${RED}✗ JWT authentication failed${NC}"
fi

echo ""

# Test 4: Get User Info (with API token - backward compatibility)
echo -e "${YELLOW}[4/7] Testing Get User Info (API Token Auth)${NC}"
USER_RESPONSE_API=$(curl -s -X GET "$BASE_URL/user" \
  -H "Authorization: Bearer $API_TOKEN")

echo "Response: $USER_RESPONSE_API"

if echo "$USER_RESPONSE_API" | grep -q "user_id"; then
  echo -e "${GREEN}✓ API token authentication working (backward compatible)${NC}"
else
  echo -e "${RED}✗ API token authentication failed${NC}"
fi

echo ""

# Test 5: Refresh Token
echo -e "${YELLOW}[5/7] Testing Token Refresh${NC}"
REFRESH_RESPONSE=$(curl -s -X POST "$BASE_URL/auth/refresh" \
  -H "Content-Type: application/json" \
  -d "{\"refresh_token\":\"$NEW_REFRESH_TOKEN\"}")

echo "Response: $REFRESH_RESPONSE"

if echo "$REFRESH_RESPONSE" | grep -q "access_token"; then
  echo -e "${GREEN}✓ Token refresh successful${NC}"
  NEW_ACCESS_TOKEN=$(echo "$REFRESH_RESPONSE" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)
  echo "New Access Token: ${NEW_ACCESS_TOKEN:0:50}..."
else
  echo -e "${RED}✗ Token refresh failed${NC}"
fi

echo ""

# Test 6: Forgot Password
echo -e "${YELLOW}[6/7] Testing Forgot Password${NC}"
FORGOT_RESPONSE=$(curl -s -X POST "$BASE_URL/auth/forgot-password" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\"}")

echo "Response: $FORGOT_RESPONSE"

if echo "$FORGOT_RESPONSE" | grep -q "message"; then
  echo -e "${GREEN}✓ Forgot password request successful${NC}"
  echo -e "${YELLOW}Note: Copy the reset code from the received test email, never server logs${NC}"
else
  echo -e "${RED}✗ Forgot password request failed${NC}"
fi

echo ""

# Test 7: Resend Verification Email
echo -e "${YELLOW}[7/7] Testing Resend Verification${NC}"
RESEND_RESPONSE=$(curl -s -X POST "$BASE_URL/auth/resend-verification" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\"}")

echo "Response: $RESEND_RESPONSE"

if echo "$RESEND_RESPONSE" | grep -q "message"; then
  echo -e "${GREEN}✓ Resend verification successful${NC}"
  echo -e "${YELLOW}Note: Copy the verification code from the received test email${NC}"
else
  echo -e "${RED}✗ Resend verification failed${NC}"
fi

echo ""

# Test 8: Rate Limiting (Registration)
echo -e "${YELLOW}[8/7 Bonus] Testing Rate Limiting${NC}"
echo "Attempting 6 rapid registration requests (limit is 5 per hour)..."

for i in {1..6}; do
  TEST_EMAIL_SPAM="spam-$i-$(date +%s)@example.com"
  RESPONSE=$(curl -s -X POST "$BASE_URL/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$TEST_EMAIL_SPAM\",\"password\":\"$TEST_PASSWORD\"}")

  if echo "$RESPONSE" | grep -q "Too many"; then
    echo -e "${GREEN}✓ Rate limiting working (request $i blocked)${NC}"
    break
  elif [ $i -eq 6 ]; then
    echo -e "${YELLOW}! Rate limiting not triggered within 6 requests${NC}"
  else
    echo "  Request $i succeeded"
  fi
done

echo ""
echo "================================"
echo "Test Summary"
echo "================================"
echo "Test User ID: $USER_ID"
echo "Test Email: $TEST_EMAIL"
echo "API Token: $API_TOKEN"
echo ""
echo -e "${GREEN}All critical tests passed!${NC}"
echo ""
echo "Next steps:"
echo "1. Check the received test email for the verification code"
echo "2. Test email verification in the app or POST /auth/verify-email with that code"
echo "3. Test password reset with the code from the received test email"
echo ""
