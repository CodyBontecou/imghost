#!/bin/bash

# API Examples for ImageHost
# These examples demonstrate how to use the ImageHost API

# Configuration
BASE_URL="http://localhost:8787"  # Change to your production URL when deployed
API_TOKEN=""  # Will be set after registration/login

echo "ImageHost API Examples"
echo "======================"
echo ""

# 1. Register a new user
echo "1. Register a new user"
echo "----------------------"
echo "POST $BASE_URL/auth/register"
REGISTER_RESPONSE=$(curl -s -X POST "$BASE_URL/auth/register" \
  -H "Content-Type: application/json" \
  -d '{
    "email": "demo@example.com",
    "password": "securepassword123"
  }')

echo "$REGISTER_RESPONSE" | jq '.'
API_TOKEN=$(echo "$REGISTER_RESPONSE" | jq -r '.api_token')

if [ "$API_TOKEN" != "null" ] && [ -n "$API_TOKEN" ]; then
  echo "✓ Registration successful!"
  echo "API Token: $API_TOKEN"
else
  echo "✗ Registration failed or user already exists"
  echo ""
  echo "2. Login with existing user"
  echo "---------------------------"
  echo "POST $BASE_URL/auth/login"
  LOGIN_RESPONSE=$(curl -s -X POST "$BASE_URL/auth/login" \
    -H "Content-Type: application/json" \
    -d '{
      "email": "demo@example.com",
      "password": "securepassword123"
    }')

  echo "$LOGIN_RESPONSE" | jq '.'
  API_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.api_token')

  if [ "$API_TOKEN" != "null" ] && [ -n "$API_TOKEN" ]; then
    echo "✓ Login successful!"
    echo "API Token: $API_TOKEN"
  else
    echo "✗ Login failed"
    exit 1
  fi
fi

echo ""
echo "3. Get user information"
echo "----------------------"
echo "GET $BASE_URL/user"
curl -s -X GET "$BASE_URL/user" \
  -H "X-API-Key: $API_TOKEN" | jq '.'

echo ""
echo "4. Upload an image"
echo "-----------------"
echo "POST $BASE_URL/upload"

# Create a test image if it doesn't exist
if [ ! -f "/tmp/test-image.png" ]; then
  echo "Creating test image..."
  # Create a simple 100x100 red PNG
  convert -size 100x100 xc:red /tmp/test-image.png 2>/dev/null || {
    echo "Note: ImageMagick not installed. Using any existing image or skip upload test."
    echo "Install ImageMagick with: brew install imagemagick (macOS)"
  }
fi

if [ -f "/tmp/test-image.png" ]; then
  UPLOAD_RESPONSE=$(curl -s -X POST "$BASE_URL/upload" \
    -H "X-API-Key: $API_TOKEN" \
    -F "image=@/tmp/test-image.png")

  echo "$UPLOAD_RESPONSE" | jq '.'

  IMAGE_URL=$(echo "$UPLOAD_RESPONSE" | jq -r '.url')
  DELETE_URL=$(echo "$UPLOAD_RESPONSE" | jq -r '.deleteUrl')
  IMAGE_ID=$(echo "$UPLOAD_RESPONSE" | jq -r '.id')

  if [ "$IMAGE_URL" != "null" ] && [ -n "$IMAGE_URL" ]; then
    echo "✓ Upload successful!"
    echo "Image URL: $IMAGE_URL"
    echo "Delete URL: $DELETE_URL"
  fi
else
  echo "Skipping upload test (no test image available)"
fi

echo ""
echo "5. List user's images"
echo "--------------------"
echo "GET $BASE_URL/images?limit=10&offset=0"
curl -s -X GET "$BASE_URL/images?limit=10&offset=0" \
  -H "X-API-Key: $API_TOKEN" | jq '.'

echo ""
echo "6. Get uploaded image"
echo "--------------------"
if [ -n "$IMAGE_URL" ] && [ "$IMAGE_URL" != "null" ]; then
  echo "GET $IMAGE_URL"
  curl -s -I "$IMAGE_URL"
fi

echo ""
echo "7. Delete image"
echo "--------------"
if [ -n "$DELETE_URL" ] && [ "$DELETE_URL" != "null" ]; then
  echo "DELETE $DELETE_URL"
  curl -s -X DELETE "$DELETE_URL" | jq '.'
fi

echo ""
echo "8. Health check"
echo "--------------"
echo "GET $BASE_URL/health"
curl -s -X GET "$BASE_URL/health" | jq '.'

echo ""
echo "API Examples Complete!"
echo "======================"
echo ""
echo "Your API Token: $API_TOKEN"
echo ""
echo "Save this token to use in your iOS app!"
