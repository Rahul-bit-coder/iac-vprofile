#!/bin/bash

echo "⚠️  WARNING: This will delete ALL AWS resources and may incur irreversible data loss!"
read -p "Type 'DELETE ALL' to confirm: " confirm
if [[ "$confirm" != "DELETE ALL" ]]; then
    echo "Aborted."
    exit 1
fi

read -p "Enter your AWS Access Key ID: " access_key
read -s -p "Enter your AWS Secret Access Key: " secret_key
echo ""
read -p "Enter default AWS region (e.g. us-east-1): " default_region

# Configure AWS CLI
aws configure set aws_access_key_id "$access_key"
aws configure set aws_secret_access_key "$secret_key"
aws configure set default.region "$default_region"
aws configure set default.output json

# Get all regions
regions=$(aws ec2 describe-regions --query "Regions[*].RegionName" --output text)

for region in $regions; do
    echo "🔄 Cleaning region: $region"

    ## EC2 Instances
    for instance in $(aws ec2 describe-instances --region $region --query "Reservations[*].Instances[*].InstanceId" --output text); do
        echo "🖥️ Terminating instance: $instance"
        aws ec2 terminate-instances --instance-ids $instance --region $region
    done

    ## Auto Scaling Groups
    for asg in $(aws autoscaling describe-auto-scaling-groups --region $region --query "AutoScalingGroups[*].AutoScalingGroupName" --output text); do
        echo "📉 Deleting Auto Scaling Group: $asg"
        aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $asg --force-delete --region $region
    done

    ## Launch Configurations
    for lc in $(aws autoscaling describe-launch-configurations --region $region --query "LaunchConfigurations[*].LaunchConfigurationName" --output text); do
        echo "🧰 Deleting Launch Configuration: $lc"
        aws autoscaling delete-launch-configuration --launch-configuration-name $lc --region $region
    done

    ## Load Balancers (Classic & ALB/NLB)
    for elb in $(aws elb describe-load-balancers --region $region --query "LoadBalancerDescriptions[*].LoadBalancerName" --output text); do
        echo "⚖️ Deleting Classic Load Balancer: $elb"
        aws elb delete-load-balancer --load-balancer-name $elb --region $region
    done
    for elbv2 in $(aws elbv2 describe-load-balancers --region $region --query "LoadBalancers[*].LoadBalancerArn" --output text); do
        echo "⚖️ Deleting Load Balancer V2: $elbv2"
        aws elbv2 delete-load-balancer --load-balancer-arn $elbv2 --region $region
    done

    ## EIPs
    for eip in $(aws ec2 describe-addresses --region $region --query "Addresses[*].AllocationId" --output text); do
        echo "🔌 Releasing Elastic IP: $eip"
        aws ec2 release-address --allocation-id $eip --region $region
    done

    ## NAT Gateways
    for nat in $(aws ec2 describe-nat-gateways --region $region --query "NatGateways[*].NatGatewayId" --output text); do
        echo "🧱 Deleting NAT Gateway: $nat"
        aws ec2 delete-nat-gateway --nat-gateway-id $nat --region $region
    done

    ## Security Groups (excluding default)
    for sg in $(aws ec2 describe-security-groups --region $region --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
        echo "🔒 Deleting Security Group: $sg"
        aws ec2 delete-security-group --group-id $sg --region $region
    done

    ## Internet Gateways
    for igw in $(aws ec2 describe-internet-gateways --region $region --query "InternetGateways[*].InternetGatewayId" --output text); do
        for vpcid in $(aws ec2 describe-internet-gateways --internet-gateway-ids $igw --region $region --query "InternetGateways[*].Attachments[*].VpcId" --output text); do
            aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $vpcid --region $region
        done
        echo "🌐 Deleting IGW: $igw"
        aws ec2 delete-internet-gateway --internet-gateway-id $igw --region $region
    done

    ## Subnets
    for subnet in $(aws ec2 describe-subnets --region $region --query "Subnets[*].SubnetId" --output text); do
        echo "📡 Deleting Subnet: $subnet"
        aws ec2 delete-subnet --subnet-id $subnet --region $region
    done

    ## Route Tables (except main)
    for rt in $(aws ec2 describe-route-tables --region $region --query "RouteTables[?Associations[?Main!=\`true\`]].RouteTableId" --output text); do
        echo "🗺️ Deleting Route Table: $rt"
        aws ec2 delete-route-table --route-table-id $rt --region $region
    done

    ## VPCs
    for vpc in $(aws ec2 describe-vpcs --region $region --query "Vpcs[*].VpcId" --output text); do
        echo "🧱 Attempting to delete VPC: $vpc"
        aws ec2 delete-vpc --vpc-id $vpc --region $region
    done

    ## S3 Buckets
    for bucket in $(aws s3api list-buckets --query "Buckets[*].Name" --output text); do
        location=$(aws s3api get-bucket-location --bucket $bucket --query "LocationConstraint" --output text)
        if [[ "$location" == "None" || "$location" == "$region" ]]; then
            echo "🪣 Deleting S3 bucket: $bucket"
            aws s3 rb s3://$bucket --force
        fi
    done

    ## DHCP Options
    for dhcp in $(aws ec2 describe-dhcp-options --region $region --query "DhcpOptions[*].DhcpOptionsId" --output text); do
        if [[ "$dhcp" != "dopt-*" ]]; then
            echo "⚙️ Deleting DHCP Options Set: $dhcp"
            aws ec2 delete-dhcp-options --dhcp-options-id $dhcp --region $region
        fi
    done

    ## Placement Groups
    for pg in $(aws ec2 describe-placement-groups --region $region --query "PlacementGroups[*].GroupName" --output text); do
        echo "📦 Deleting Placement Group: $pg"
        aws ec2 delete-placement-group --group-name $pg --region $region
    done

    ## EKS Clusters
    for eks in $(aws eks list-clusters --region $region --query "clusters" --output text); do
        echo "🧯 Deleting EKS cluster: $eks"
        aws eks delete-cluster --name $eks --region $region
    done

done

echo "✅ Cleanup complete across all regions."

