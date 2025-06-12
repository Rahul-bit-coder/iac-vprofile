#!/bin/bash

set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <vpc-id> [region]"
  exit 1
fi

VPC_ID=$1
REGION=${2:-us-east-1}

echo "Deleting resources in VPC: $VPC_ID in region: $REGION"

# 1. Terminate EC2 instances in the VPC
echo "Terminating EC2 instances..."
INSTANCES=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION \
  --query 'Reservations[].Instances[].InstanceId' --output text)

if [ -n "$INSTANCES" ]; then
  aws ec2 terminate-instances --instance-ids $INSTANCES --region $REGION
  echo "Waiting for instances to terminate..."
  aws ec2 wait instance-terminated --instance-ids $INSTANCES --region $REGION
else
  echo "No instances found."
fi

# 2. Delete Auto Scaling Groups in the VPC
echo "Deleting Auto Scaling Groups..."
ASGS=$(aws autoscaling describe-auto-scaling-groups --region $REGION \
  --query "AutoScalingGroups[?VPCZoneIdentifier!=null && contains(VPCZoneIdentifier, '$VPC_ID')].AutoScalingGroupName" --output text)

for ASG in $ASGS; do
  echo "Deleting ASG: $ASG"
  aws autoscaling update-auto-scaling-group --auto-scaling-group-name $ASG --min-size 0 --max-size 0 --desired-capacity 0 --region $REGION
  aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $ASG --force-delete --region $REGION
done

# 3. Delete NAT Gateways & release Elastic IPs
echo "Deleting NAT Gateways..."
NAT_GWS=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --region $REGION \
  --query 'NatGateways[].NatGatewayId' --output text)

for NAT_ID in $NAT_GWS; do
  echo "Deleting NAT Gateway: $NAT_ID"
  aws ec2 delete-nat-gateway --nat-gateway-id $NAT_ID --region $REGION

  # Wait for deletion
  echo "Waiting for NAT Gateway $NAT_ID deletion..."
  while true; do
    STATE=$(aws ec2 describe-nat-gateways --nat-gateway-ids $NAT_ID --region $REGION --query 'NatGateways[0].State' --output text 2>/dev/null || echo "deleted")
    if [ "$STATE" == "deleted" ] || [ "$STATE" == "null" ]; then
      break
    fi
    sleep 10
  done

  # Release associated EIPs
  EIPS=$(aws ec2 describe-nat-gateways --nat-gateway-ids $NAT_ID --region $REGION --query 'NatGateways[0].NatGatewayAddresses[].AllocationId' --output text 2>/dev/null)
  for EIP in $EIPS; do
    if [ -n "$EIP" ]; then
      echo "Releasing Elastic IP: $EIP"
      aws ec2 release-address --allocation-id $EIP --region $REGION
    fi
  done
done

# 4. Detach and delete Internet Gateways
echo "Detaching and deleting Internet Gateways..."
IGWS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --region $REGION --query 'InternetGateways[].InternetGatewayId' --output text)

for IGW in $IGWS; do
  echo "Detaching IGW: $IGW"
  aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC_ID --region $REGION
  echo "Deleting IGW: $IGW"
  aws ec2 delete-internet-gateway --internet-gateway-id $IGW --region $REGION
done

# 5. Delete Load Balancers in VPC (Classic, ALB, NLB)
echo "Deleting Load Balancers..."
# Classic ELBs
ELBS=$(aws elb describe-load-balancers --region $REGION --query 'LoadBalancerDescriptions[?VPCId==`'"$VPC_ID"'`].LoadBalancerName' --output text)
for ELB in $ELBS; do
  echo "Deleting Classic ELB: $ELB"
  aws elb delete-load-balancer --load-balancer-name $ELB --region $REGION
done

# ALB & NLB (ELBv2)
ELBVS=$(aws elbv2 describe-load-balancers --region $REGION --query 'LoadBalancers[?VpcId==`'"$VPC_ID"'`].LoadBalancerArn' --output text)
for ELBV in $ELBVS; do
  echo "Deleting ELBv2: $ELBV"
  aws elbv2 delete-load-balancer --load-balancer-arn $ELBV --region $REGION
done

# 6. Delete Route Tables except main
echo "Deleting non-main Route Tables..."
ROUTES=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query 'RouteTables[?Associations[?Main!=`true`]].RouteTableId' --output text)

for RTB in $ROUTES; do
  echo "Deleting Route Table: $RTB"
  aws ec2 delete-route-table --route-table-id $RTB --region $REGION
done

# 7. Delete Subnets
echo "Deleting Subnets..."
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query 'Subnets[].SubnetId' --output text)

for SUBNET in $SUBNETS; do
  echo "Deleting Subnet: $SUBNET"
  aws ec2 delete-subnet --subnet-id $SUBNET --region $REGION
done

# 8. Delete Security Groups except default
echo "Deleting Security Groups (except default)..."
SGS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)

for SG in $SGS; do
  echo "Deleting Security Group: $SG"
  aws ec2 delete-security-group --group-id $SG --region $REGION
done

# 9. Delete Network Interfaces (should be cleaned up automatically, but just in case)
echo "Deleting Network Interfaces..."
ENIS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)

for ENI in $ENIS; do
  echo "Deleting Network Interface: $ENI"
  aws ec2 delete-network-interface --network-interface-id $ENI --region $REGION || echo "Failed to delete ENI $ENI - might be in use"
done

# 10. Delete DHCP Option Sets associated with VPC (only if not default)
echo "Deleting custom DHCP Option Sets..."
DHCP_OPTIONS_ID=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --region $REGION --query 'Vpcs[0].DhcpOptionsId' --output text)
DEFAULT_DHCP_ID=$(aws ec2 describe-dhcp-options --filters Name=key,Values=domain-name --region $REGION --query 'DhcpOptions[?DhcpConfigurations==null].DhcpOptionsId' --output text)

if [ "$DHCP_OPTIONS_ID" != "dopt-xxxxxxxx" ] && [ "$DHCP_OPTIONS_ID" != "$DEFAULT_DHCP_ID" ]; then
  echo "Deleting DHCP Options Set: $DHCP_OPTIONS_ID"
  aws ec2 delete-dhcp-options --dhcp-options-id $DHCP_OPTIONS_ID --region $REGION || echo "Failed to delete DHCP options"
else
  echo "Using default DHCP Options set, no deletion needed."
fi

# 11. Finally delete the VPC
echo "Deleting VPC: $VPC_ID"
aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION

echo "VPC and dependencies deleted successfully."

