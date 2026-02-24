#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="us-east-2"
ECR_REPOSITORY="webrtc/janus-base-dev"
IMAGE_TAG="${1:-latest}"

# Get the ECR registry URI from the caller's AWS account
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "AWS Account:  ${AWS_ACCOUNT_ID}"
echo "ECR Registry: ${ECR_REGISTRY}"
echo "Repository:   ${ECR_REPOSITORY}"
echo "Tag:          ${IMAGE_TAG}"
echo ""

# Create ECR repository if it doesn't exist
if ! aws ecr describe-repositories --region "${AWS_REGION}" --repository-names "${ECR_REPOSITORY}" &>/dev/null; then
  echo "Creating ECR repository ${ECR_REPOSITORY}..."
  aws ecr create-repository --region "${AWS_REGION}" --repository-name "${ECR_REPOSITORY}"
fi

# Login to ECR
echo "Logging in to ECR..."
aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# Build
echo ""
echo "Building Docker image..."
docker build --platform linux/amd64 \
             -t "${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}" \
             -t "${ECR_REGISTRY}/${ECR_REPOSITORY}:latest" \
             .

# Push
echo ""
echo "Pushing ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}..."
docker push "${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"

echo "Pushing ${ECR_REGISTRY}/${ECR_REPOSITORY}:latest..."
docker push "${ECR_REGISTRY}/${ECR_REPOSITORY}:latest"

echo ""
echo "Done. Image pushed as:"
echo "  ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"
echo "  ${ECR_REGISTRY}/${ECR_REPOSITORY}:latest"
