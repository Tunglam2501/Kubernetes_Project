#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

IMAGE_NAME=$1
NAMESPACE="production-env"

echo -e "${YELLOW}===================================================${NC}"
echo -e "${YELLOW} DYNAMIC DEVSECOPS PIPELINE (ZERO TRUST ARCHITECTURE) ${NC}"
echo -e "${YELLOW}===================================================${NC}"

if [ -z "$IMAGE_NAME" ]; then
  echo -e "${RED}[ERROR] Image name missing! Usage: ./deploy-pipeline.sh <image-name>${NC}"
  exit 1
fi

# ==========================================
# MENU CHỌN LOẠI ỨNG DỤNG (INTERACTIVE)
# ==========================================
echo -e "${CYAN}Select the component role for this deployment:${NC}"
echo "1) Web / Frontend   (Allows Ingress from Anywhere)"
echo "2) Backend / API    (Allows Ingress ONLY from Web)"
echo "3) Database         (Allows Ingress ONLY from Backend)"
read -p "Enter choice [1-3]: " ROLE_CHOICE

case $ROLE_CHOICE in
  1) APP_ROLE="web";;
  2) APP_ROLE="backend";;
  3) APP_ROLE="database";;
  *) echo -e "${RED}[ERROR] Invalid choice. Exiting.${NC}"; exit 1;;
esac

echo -e "\n${CYAN}>> Selected Role: [${APP_ROLE^^}]${NC}"

# ==========================================
# STAGE 1: TRIVY SECURITY SCAN
# ==========================================
echo -e "\n${YELLOW}[STAGE 1] Security Scanning with Trivy (CRITICAL only)...${NC}"
trivy image --severity CRITICAL --exit-code 1 --quiet $IMAGE_NAME

if [ $? -ne 0 ]; then
  echo -e "${RED}[FAILED] CRITICAL vulnerabilities detected in image: $IMAGE_NAME.${NC}"
  echo -e "${RED}[FATAL] PIPELINE HALTED!${NC}"
  exit 1
else
  echo -e "${GREEN}[SUCCESS] Image is safe.${NC}"
fi

# ==========================================
# STAGE 2: KUBERNETES DEPLOYMENT
# ==========================================
echo -e "\n${YELLOW}[STAGE 2] Deploying to Kubernetes...${NC}"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f - > /dev/null

# Xóa Pod cũ và tạo Pod mới gắn nhãn (Label) tương ứng với ROLE
POD_NAME="${APP_ROLE}-app"
kubectl delete pod $POD_NAME -n $NAMESPACE --ignore-not-found=true > /dev/null
kubectl run $POD_NAME --image=$IMAGE_NAME -n $NAMESPACE --labels="tier=${APP_ROLE}"
echo -e "${GREEN}[SUCCESS] Pod '$POD_NAME' created with label 'tier=${APP_ROLE}'.${NC}"

# ==========================================
# STAGE 3: DYNAMIC NETWORK POLICY GENERATION
# ==========================================
echo -e "\n${YELLOW}[STAGE 3] Generating & Applying Zero Trust Network Policy...${NC}"

# Tạo biến YAML rỗng
POLICY_YAML=""

if [ "$APP_ROLE" == "web" ]; then
  # Web: Mở cửa đón khách (Cho phép tất cả kết nối Ingress)
  POLICY_YAML=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all-to-web
  namespace: $NAMESPACE
spec:
  podSelector:
    matchLabels:
      tier: web
  policyTypes:
  - Ingress
  ingress:
  - {} 
EOF
)
elif [ "$APP_ROLE" == "backend" ]; then
  # Backend: Chỉ cho phép các Pod có nhãn 'tier=web' đi vào
  POLICY_YAML=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-web-to-backend
  namespace: $NAMESPACE
spec:
  podSelector:
    matchLabels:
      tier: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: web
EOF
)
elif [ "$APP_ROLE" == "database" ]; then
  # Database: Chỉ cho phép các Pod có nhãn 'tier=backend' đi vào
  POLICY_YAML=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-to-db
  namespace: $NAMESPACE
spec:
  podSelector:
    matchLabels:
      tier: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: backend
EOF
)
fi

# Apply đoạn YAML vừa được nhào nặn vào hệ thống
echo "$POLICY_YAML" | kubectl apply -f - > /dev/null
echo -e "${GREEN}[SUCCESS] Network Policy applied strictly for ${APP_ROLE^^} role.${NC}"

echo -e "\n${YELLOW}===================================================${NC}"
echo -e "${GREEN} DEPLOYMENT COMPLETE! ${NC}"
echo -e "${YELLOW}===================================================${NC}\n"
