#!/bin/bash
LOG_FILE="infrastructure.log"

# Function to append logs to a log file
log_to_file() {
    echo "$1" >> "$LOG_FILE"
}

# Existing log function to standard output
log() {
    local level="$1"
    shift
    MESSAGE="[$(date +'%Y-%m-%d %H:%M:%S')][$level] $*"
    echo "$MESSAGE"
    log_to_file "$MESSAGE"
}

# Function to check the success of the last command executed
check_command_success() {
    if [ $? -ne 0 ]; then
        log "ERROR" "$1"
        exit 1
    fi
}

# Variables
REGION="ap-southeast-1" # fixed
VPC_ID="vpc-01815c546a44b855a" # paris2-app
APP_SUBNET_ID="subnet-0455d10880c23dabe" # 1st public subnets of the VPC
LB_SUBNET_IDS=("subnet-0455d10880c23dabe" "subnet-0abcb4594ee480890" "subnet-0e89f467d0a97bdfc") # public subnets of the VPC
DB_SUBNET_IDS=("subnet-0f1b715ad3eccd973" "subnet-0fcb5d300240fa26d" "subnet-013eb0dbb339a124a")
DB_SUBNET_GROUP_NAME="paris2-qcd-uat2-subnet-group"
DB_INSTANCE_IDENTIFIER="paris2-qcd-uat2"
SECURITY_GROUP_NAMES=("paris2-uat2-qcd-app-sg" "paris2-uat2-qcd-rds-sg" "paris2-uat2-qcd-alb-sg") # In order - app sg, rds sg, alb sg 
DESCRIPTION="Security Group for"
# AMI_ID="ami-063d7a23a4dd2e8a6"  # Ensure this is a correct Windows AMI ID
INSTANCE_TYPE="t2.large"
INSTANCE_NAME="paris2-qcd-app-uat2"
DB_INSTANCE_CLASS="db.t3.medium"
KEY_PAIR_NAME="qcd_uat_key_pair"
DB_USERNAME="admin"
DB_PASSWORD=""
DB_NAME="QCDBilling"
LB_NAME="qcd-uat2-alb"
TG_NAME="qcd-uat2-alb-tg"
DOMAIN_NAME="qcd-uat2.fleetship.com"
HOSTED_ZONE_ID="ZRODRAD5HILDX" # hsoted zone ID for fleetship.com domain in Route53
CERTIFICATE_ARN="arn:aws:acm:ap-southeast-1:621849543254:certificate/0f53418b-5c24-400f-8669-c2e6ec3e13e5"
ACCOUNT_ID=""



# Validate VPC ID
if [ -z "$VPC_ID" ]; then
    log "ERROR" "VPC ID is not set. Please specify a VPC ID."
    exit 1
fi

# Security rule configurations
SECURITY_RULES_APP_CLEAN=(
    "tcp,3389,202.149.209.34/32"  # RDP access
    "tcp,3389,49.248.143.75/32"  # RDP access
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
    log_to_file "$NAME: $SG_ID"
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
log_to_file "RDS Instance: $DB_INSTANCE_IDENTIFIER"

RDS_ARN="arn:aws:rds:$REGION:$ACCOUNT_ID:db:$DB_INSTANCE_IDENTIFIER"

log "INFO" "Tagging RDS instance..."
aws rds add-tags-to-resource \
    --resource-name "$RDS_ARN" \
    --tags Key=ApplicationID,Value="QCD" Key=CompanyID,Value="Fleet" Key=Environment,Value="UAT" Key=Module,Value="QCD" Key=Owner,Value="Akash Jain" Key=Name,Value="$DB_INSTANCE_IDENTIFIER" \
    --region "$REGION"
check_command_success "Failed to add tags to RDS instance."

# Retrieve RDS instance endpoint and port
RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --region "$REGION" \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text)
check_command_success "Failed to retrieve RDS Endpoint."
log "INFO" "RDS Endpoint: $RDS_ENDPOINT"
log_to_file "RDS Endpoint: $RDS_ENDPOINT"

RDS_PORT=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --region "$REGION" \
    --query 'DBInstances[0].Endpoint.Port' \
    --output text)
check_command_success "Failed to retrieve RDS Port."
log "INFO" "RDS Port: $RDS_PORT"
log_to_file "RDS Port: $RDS_PORT"

# User Data Script
# USER_DATA_SCRIPT=$(cat <<EOF
# <powershell>
# setx DBServer "$RDS_ENDPOINT,$RDS_PORT" /M
# setx DBName "$DB_NAME" /M
# setx DBUser "$DB_USER" /M
# setx DBPassword "$DB_PASSWORD" /M
# </powershell>
# EOF
# )

# Launch EC2 Instance
# --user-data "$USER_DATA_SCRIPT" \
log "INFO" "Launching EC2 instance with user data on Windows..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_PAIR_NAME" \
    --security-group-ids "${SG_IDS[0]}" \
    --associate-public-ip-address \
    --subnet-id "$APP_SUBNET_ID" \
    --region "$REGION" \
    --block-device-mappings '[{"DeviceName":"xvdb","Ebs":{"VolumeSize":100,"DeleteOnTermination":true}}]' \
    --query 'Instances[0].InstanceId' \
    --output text)
check_command_success "Failed to launch EC2 instance."

# # Wait for the instance to be running
log "INFO" "Waiting for EC2 instance '$INSTANCE_ID' to reach 'running' state..."
aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"
check_command_success "EC2 instance '$INSTANCE_ID' failed to reach running state."
log "INFO" "EC2 instance '$INSTANCE_ID' is running."
log_to_file "EC2 Instance: $INSTANCE_NAME ($INSTANCE_ID)"

# # Add tags to the instance
log "INFO" "Tagging EC2 instance..."
aws ec2 create-tags \
    --resources "$INSTANCE_ID" \
    --tags Key=ApplicationID,Value="QCD" Key=CompanyID,Value="Fleet" Key=Environment,Value="UAT" Key=Module,Value="QCD" Key=Owner,Value="Akash Jain" Key=Name,Value="$INSTANCE_NAME" \
    --region "$REGION"
check_command_success "Failed to add tags to EC2 instance."

# # Create a Target Group
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
log_to_file "Target Group: $TG_NAME ($TG_ARN)"

# # Register EC2 Instance with the Target Group
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
    --output text)
check_command_success "Failed to create Load Balancer '$LB_NAME'."
log "INFO" "Load Balancer '$LB_NAME' created successfully."
log_to_file "Load Balancer: $LB_NAME ($LB_ARN)"

log "INFO" "Tagging Load Balancer..."
aws elbv2 add-tags \
    --resource-arns "$LB_ARN" \
    --tags Key=ApplicationID,Value="QCD" Key=CompanyID,Value="Fleet" Key=Environment,Value="UAT" Key=Module,Value="QCD" Key=Owner,Value="Akash Jain" Key=Name,Value="$LB_NAME" \
    --region "$REGION"
check_command_success "Failed to add tags to Load Balancer."

# Get the Load Balancer DNS Name
LB_DNS_NAME=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$LB_ARN" \
    --region "$REGION" \
    --query 'LoadBalancers[0].DNSName' \
    --output text)
check_command_success "Failed to retrieve DNS Name of Load Balancer."
log "INFO" "Load Balancer DNS Name: $LB_DNS_NAME"
log_to_file "Load Balancer DNS Name: $LB_DNS_NAME"

# Create a Listener
log "INFO" "Creating Listener for Load Balancer..."
aws elbv2 create-listener \
    --load-balancer-arn "$LB_ARN" \
    --protocol HTTPS \
    --port 443 \
    --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
    --ssl-policy "ELBSecurityPolicy-2016-08" \
    --certificates CertificateArn="$CERTIFICATE_ARN" \
    --region "$REGION"
check_command_success "Failed to create Listener for Load Balancer."
log "INFO" "Listener created successfully for Load Balancer."

# # Create a Listener for HTTP traffic and redirect to HTTPS
log "INFO" "Creating HTTP to HTTPS redirect Listener..."
aws elbv2 create-listener \
 --load-balancer-arn "$LB_ARN" \
 --protocol HTTP \
 --port 80 \
 --default-actions Type=redirect,RedirectConfig="{Protocol=HTTPS,Port=443,Host=\"#{host}\",Path=\"/#{path}\",Query=\"#{query}\",StatusCode=HTTP_301}" \
--region "$REGION"
check_command_success "Failed to create HTTP to HTTPS redirect Listener."
log "INFO" "HTTP to HTTPS redirect Listener created successfully."

# Create a Route 53 Record pointing to the Load Balancer
# log "INFO" "Creating Route 53 record for domain $DOMAIN_NAME..."
# cat > change-batch.json <<EOF
# {
#   "Comment": "Creating CNAME for ALB",
#   "Changes": [
#     {
#       "Action": "UPSERT",
#       "ResourceRecordSet": {
#         "Name": "$DOMAIN_NAME",
#         "Type": "CNAME",
#         "TTL": 300,
#         "ResourceRecords": [
#           {
#             "Value": "$LB_DNS_NAME"
#           }
#         ]
#       }
#     }
#   ]
# }
# EOF

# aws route53 change-resource-record-sets \
#   --hosted-zone-id "$HOSTED_ZONE_ID" \
#   --change-batch file://change-batch.json \
#   --region "$REGION"
# check_command_success "Failed to create Route 53 DNS record for domain $DOMAIN_NAME."
# log "INFO" "Route 53 record created successfully for domain $DOMAIN_NAME."

log "INFO" "All resources created and configured successfully."
exit 0