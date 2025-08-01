#!/bin/bash

# Function for logging
log() {
    local level="$1"
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')][$level] $*"
}

# Function to check the success of the last command executed
check_command_success() {
    if [ $? -ne 0 ]; then
        log "ERROR" "$1"
        exit 1
    fi
}

# Variables
REGION="us-east-1"
VPC_ID="vpc-0ada3a48e907c65ed"
APP_SUBNET_ID="subnet-029b1f3ccfe1c0481"
LB_SUBNET_IDS=("subnet-029b1f3ccfe1c0481" "subnet-0686a5c591b2ab525" "subnet-0612ce6f070c2e964")
DB_SUBNET_IDS=("subnet-055a0f533b6bb664c" "subnet-02d30c7b942ee9115" "subnet-08da6b7a2aa1e7a2c")
DB_SUBNET_GROUP_NAME="Paris2-qcd-db-subnetgrp-uat2"
DB_INSTANCE_IDENTIFIER="Paris2-qcd-db-uat2"
SECURITY_GROUP_NAMES=("Paris2-qcd-app-uat2" "Paris2-qcd-db-uat2" "Paris2-qcd-lb-uat2")
DESCRIPTION="Security Group for"
AMI_ID="ami-0623bc4c9a53fe562"  # Ensure this is a correct Windows AMI ID
INSTANCE_TYPE="t3.micro"
DB_INSTANCE_CLASS="db.t3.medium"
KEY_PAIR_NAME="testkey"
DB_USERNAME="admin"
DB_PASSWORD="admin321456"
DB_NAME="QCDBilling"
LB_NAME="https-load-balancer"
TG_NAME="app-target-group"
DOMAIN_NAME="qcd.fleetship.com"
HOSTED_ZONE_ID="Z04254561JAWPAYE6J53M"
EMAIL_CC="sandeepchauhan1@yahoo.in"
EMAIL_TEMPLATE_FOLDER="D:\\QCD_WebAPI_Publish\\Templates\\"
KEYCLOAK_AUTH_URL="https://auth-uat2.fleetship.com/auth"
KEYCLOAK_CLIENT_SECRET="rrAnqD1bROSEEXTlqsV8GPBObAwAitM8"
KEYCLOAK_REDIRECT="https://qcd-uat2.fleetship.com/Home/GetDashboardScreen"
KEYCLOAK_REALM="paris2"
KEYCLOAK_CLIENT_ID="qcd-client"
KEYCLOAK_USERNAME="qcd-application"
KEYCLOAK_PASSWORD="chCzlNHT5J+g/Z4A"
NOTIFY_URL="https://notification-uat2.fleetship.com/api/notify"
LOGSTASH_URL="http://logstash-uat2.fleetship.com"
LOGSTASH_PORT="5003"
WEBAPI_URL="http://localhost:8080/api/"
WEBAPP_URL="http://localhost/"
WEBAPP_FOLDER="QCD_WebApp_Publish"
WEBAPI_FOLDER="QCD_WebAPI_Publish"
ADMIN_ROLE="qcd|adm"
USER_ROLE="qcd|fi|mng"
REQUIRE_HTTPS="false"
CERTIFICATE_ARN="arn:aws:acm:REGION:ACCOUNT_ID:certificate/CERTIFICATE_ID"

# Validate VPC ID
if [ -z "$VPC_ID" ]; then
    log "ERROR" "VPC ID is not set. Please specify a VPC ID."
    exit 1
fi

# Security rule configurations
SECURITY_RULES_APP_CLEAN=(
    "tcp,3389,162.222.204.140/32"  # RDP access
)
SECURITY_RULES_LB=(
    "tcp,80,0.0.0.0/0"
    "tcp,443,0.0.0.0/0"
)

# Create Security Groups
declare -a SG_IDS
for NAME in "${SECURITY_GROUP_NAMES[@]}"; do
    log "INFO" "Creating Security Group $NAME in VPC $VPC_ID..."
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$NAME" \
        --description "$DESCRIPTION $NAME" \
        --vpc-id "$VPC_ID" \
        --region "$REGION" \
        --query 'GroupId' \
        --output text)
    check_command_success "Failed to create Security Group $NAME."
    log "INFO" "Security Group $NAME created successfully with ID $SG_ID."
    SG_IDS+=("$SG_ID")
done

# Function to apply security rules
apply_security_rules() {
    local SG_ID=$1
    shift
    local RULES=("$@")
    for RULE in "${RULES[@]}"; do
        IFS="," read -r PROTOCOL PORT CIDR <<< "$RULE"
        log "INFO" "Adding rule $PROTOCOL | port $PORT | CIDR $CIDR to SG $SG_ID..."
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol "$PROTOCOL" \
            --port "$PORT" \
            --cidr "$CIDR" \
            --region "$REGION"
        check_command_success "Failed to add rule: Allow $PROTOCOL on port $PORT from $CIDR to Security Group $SG_ID."
    done
}

# Apply security rules
apply_security_rules "${SG_IDS[0]}" "${SECURITY_RULES_APP_CLEAN[@]}"
apply_security_rules "${SG_IDS[2]}" "${SECURITY_RULES_LB[@]}"
log "INFO" "Security rules applied successfully."

# Intraservice Communication Setup
APP_SG_ID="${SG_IDS[0]}"
DB_SG_ID="${SG_IDS[1]}"
LB_SG_ID="${SG_IDS[2]}"
log "INFO" "Configuring inter-service rules..."

# App to DB SG communication
aws ec2 authorize-security-group-ingress \
    --group-id "$DB_SG_ID" \
    --protocol tcp \
    --port 1433 \
    --source-group "$APP_SG_ID" \
    --region "$REGION"
check_command_success "Failed inbound App to DB rule on port 1433."

aws ec2 authorize-security-group-egress \
    --group-id "$APP_SG_ID" \
    --protocol tcp \
    --port 1433 \
    --source-group "$DB_SG_ID" \
    --region "$REGION"
check_command_success "Failed outbound App to DB rule on port 1433."

# LB to App SG communication
aws ec2 authorize-security-group-ingress \
    --group-id "$APP_SG_ID" \
    --protocol tcp \
    --port 80 \
    --source-group "$LB_SG_ID" \
    --region "$REGION"
check_command_success "Failed inbound LB to App rule on port 80."

aws ec2 authorize-security-group-egress \
    --group-id "$LB_SG_ID" \
    --protocol tcp \
    --port 80 \
    --source-group "$APP_SG_ID" \
    --region "$REGION"
check_command_success "Failed outbound LB to App rule on port 80."
log "INFO" "Intraservice rules configured."

# Create the RDS Subnet Group
log "INFO" "Creating RDS Subnet Group '$DB_SUBNET_GROUP_NAME'..."
output=$(aws rds create-db-subnet-group \
    --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
    --db-subnet-group-description "Subnet group for $DB_SUBNET_GROUP_NAME" \
    --subnet-ids "${DB_SUBNET_IDS[@]}" \
    --region "$REGION")
check_command_success "Failed to create RDS Subnet Group. Error: $output"
if echo "$output" | grep -q '"DBSubnetGroupName":'; then
    log "INFO" "RDS Subnet Group '$DB_SUBNET_GROUP_NAME' created successfully."
else
    log "ERROR" "Failed to verify RDS Subnet Group creation. Unexpected response: $output"
    exit 1
fi

# Launch an RDS instance with SQL Server Express Edition
log "INFO" "Launching RDS instance with SQL Server Express Edition..."
aws rds create-db-instance \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --db-instance-class "$DB_INSTANCE_CLASS" \
    --engine "sqlserver-ex" \
    --master-username "$DB_USERNAME" \
    --master-user-password "$DB_PASSWORD" \
    --allocated-storage 20 \
    --max-allocated-storage 20 \
    --vpc-security-group-ids "${SG_IDS[1]}" \
    --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
    --no-publicly-accessible \
    --region "$REGION"
check_command_success "Failed to launch RDS instance."

# Wait for the RDS instance to be in 'available' state
log "INFO" "Waiting for RDS instance '$DB_INSTANCE_IDENTIFIER' to become available..."
aws rds wait db-instance-available \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --region "$REGION"
check_command_success "RDS instance '$DB_INSTANCE_IDENTIFIER' did not become available. Exiting."
log "INFO" "RDS instance '$DB_INSTANCE_IDENTIFIER' is now available."

# Retrieve RDS instance endpoint and port
RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --region "$REGION" \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text)
check_command_success "Failed to retrieve RDS Endpoint."

RDS_PORT=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --region "$REGION" \
    --query 'DBInstances[0].Endpoint.Port' \
    --output text)
check_command_success "Failed to retrieve RDS Port."

# User Data Script
USER_DATA_SCRIPT=$(cat <<EOF
<powershell>
setx EMAIL_TEMPLATE_FOLDER "$EMAIL_TEMPLATE_FOLDER" /M
setx EMAIL_CC "$EMAIL_CC" /M
setx KEYCLOAK_AUTH_URL "$KEYCLOAK_AUTH_URL" /M
setx KEYCLOAK_CLIENT_SECRET "$KEYCLOAK_CLIENT_SECRET" /M
setx KEYCLOAK_REDIRECT "$KEYCLOAK_REDIRECT" /M
setx KEYCLOAK_REALM "$KEYCLOAK_REALM" /M
setx KEYCLOAK_CLIENT_ID "$KEYCLOAK_CLIENT_ID" /M
setx KEYCLOAK_USERNAME "$KEYCLOAK_USERNAME" /M
setx KEYCLOAK_PASSWORD "$KEYCLOAK_PASSWORD" /M
setx NOTIFY_URL "$NOTIFY_URL" /M
setx LOGSTASH_URL "$LOGSTASH_URL" /M
setx LOGSTASH_PORT "$LOGSTASH_PORT" /M
setx WEBAPI_URL "$WEBAPI_URL" /M
setx WEBAPP_URL "$WEBAPP_URL" /M
setx WEBAPP_FOLDER "$WEBAPP_FOLDER" /M
setx WEBAPI_FOLDER "$WEBAPI_FOLDER" /M
setx ADMIN_ROLE "$ADMIN_ROLE" /M
setx USER_ROLE "$USER_ROLE" /M
setx REQUIRE_HTTPS "$REQUIRE_HTTPS" /M
setx DB_SERVER "$RDS_ENDPOINT,$RDS_PORT" /M
setx DB_NAME "$DB_NAME" /M
setx DB_USER "$DB_USER" /M
setx DB_PASSWORD "$DB_PASSWORD" /M
</powershell>
EOF
)

# Launch EC2 Instance
log "INFO" "Launching EC2 instance with user data on Windows..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_PAIR_NAME" \
    --security-group-ids "${SG_IDS[0]}" \
    --associate-public-ip-address \
    --subnet-id "$APP_SUBNET_ID" \
    --region "$REGION" \
    --block-device-mappings '[{"DeviceName":"xvdb","Ebs":{"VolumeSize":50,"DeleteOnTermination":true}}]' \
    --user-data "$USER_DATA_SCRIPT" \
    --query 'Instances[0].InstanceId' \
    --output text)
check_command_success "Failed to launch EC2 instance."

# Wait for the instance to be running
log "INFO" "Waiting for EC2 instance '$INSTANCE_ID' to reach 'running' state..."
aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"
check_command_success "EC2 instance '$INSTANCE_ID' failed to reach running state."
log "INFO" "EC2 instance '$INSTANCE_ID' is running."

# Add tags to the instance
log "INFO" "Tagging EC2 instance..."
aws ec2 create-tags \
    --resources "$INSTANCE_ID" \
    --tags Key=Application-ID,Value="QCD" Key=Company-ID,Value="Fleet" Key=Environment,Value="UAT" Key=Module,Value="QCD" Key=Owner,Value="Akash Jain"  \
    --region "$REGION"
check_command_success "Failed to add tags to EC2 instance."

# Create a Target Group
log "INFO" "Creating Target Group '$TG_NAME'..."
TG_ARN=$(aws elbv2 create-target-group \
    --name "$TG_NAME" \
    --protocol HTTP \
    --port 80 \
    --vpc-id "$VPC_ID" \
    --health-check-protocol "HTTP" \
    --health-check-path "/HealthCheck.html" \
    --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)
check_command_success "Failed to create Target Group '$TG_NAME'."
log "INFO" "Target Group '$TG_NAME' created successfully."

# Register EC2 Instance with the Target Group
log "INFO" "Registering EC2 Instance with the Target Group..."
aws elbv2 register-targets \
    --target-group-arn "$TG_ARN" \
    --targets Id="$INSTANCE_ID" \
    --region "$REGION"
check_command_success "Failed to register EC2 Instance with Target Group."
log "INFO" "EC2 Instance registered successfully with the Target Group."

# Create an HTTPS Load Balancer
log "INFO" "Creating HTTPS Load Balancer '$LB_NAME'..."
LB_ARN=$(aws elbv2 create-load-balancer \
    --name "$LB_NAME" \
    --subnets "${LB_SUBNET_IDS[@]}" \
    --security-groups "${SG_IDS[2]}" \
    --scheme internet-facing \
    --type application \
    --region "$REGION" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --ssl-policy "ELBSecurityPolicy-2016-08" \
    --certificates CertificateArn="$CERTIFICATE_ARN" \
    --output text)
check_command_success "Failed to create Load Balancer '$LB_NAME'."
log "INFO" "Load Balancer '$LB_NAME' created successfully."

# Get the Load Balancer DNS Name
LB_DNS_NAME=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$LB_ARN" \
    --region "$REGION" \
    --query 'LoadBalancers[0].DNSName' \
    --output text)
check_command_success "Failed to retrieve DNS Name of Load Balancer."
log "INFO" "Load Balancer DNS Name: $LB_DNS_NAME"

# Create a Listener
log "INFO" "Creating Listener for Load Balancer..."
aws elbv2 create-listener \
    --load-balancer-arn "$LB_ARN" \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
    --region "$REGION"
check_command_success "Failed to create Listener for Load Balancer."
log "INFO" "Listener created successfully for Load Balancer."

# Create a Route 53 Record pointing to the Load Balancer
log "INFO" "Creating Route 53 record for domain $DOMAIN_NAME..."
cat > change-batch.json <<EOF
{
  "Comment": "Creating CNAME for ALB",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$DOMAIN_NAME",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "$LB_DNS_NAME"
          }
        ]
      }
    }
  ]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://change-batch.json \
  --region "$REGION"
check_command_success "Failed to create Route 53 DNS record for domain $DOMAIN_NAME."
log "INFO" "Route 53 record created successfully for domain $DOMAIN_NAME."

log "INFO" "All resources created and configured successfully."
exit 0