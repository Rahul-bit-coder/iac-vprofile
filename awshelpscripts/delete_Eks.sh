#!/bin/bash

set -e

REGION=${1:-us-east-1}

echo "Deleting all EKS clusters in region: $REGION"

# Get all EKS cluster names
CLUSTERS=$(aws eks list-clusters --region $REGION --query "clusters" --output text)

if [ -z "$CLUSTERS" ]; then
  echo "No EKS clusters found in $REGION."
  exit 0
fi

for CLUSTER in $CLUSTERS; do
  echo "Processing cluster: $CLUSTER"

  # Delete all managed node groups
  NODEGROUPS=$(aws eks list-nodegroups --cluster-name $CLUSTER --region $REGION --query "nodegroups" --output text)
  if [ -n "$NODEGROUPS" ]; then
    for NG in $NODEGROUPS; do
      echo "Deleting node group $NG from cluster $CLUSTER..."
      aws eks delete-nodegroup --cluster-name $CLUSTER --nodegroup-name $NG --region $REGION
    done
    echo "Waiting for node groups to be deleted..."
    for NG in $NODEGROUPS; do
      aws eks wait nodegroup-deleted --cluster-name $CLUSTER --nodegroup-name $NG --region $REGION
    done
  else
    echo "No node groups found in cluster $CLUSTER."
  fi

  # Delete all Fargate profiles
  FARGATE_PROFILES=$(aws eks list-fargate-profiles --cluster-name $CLUSTER --region $REGION --query "fargateProfileNames" --output text)
  if [ -n "$FARGATE_PROFILES" ]; then
    for FP in $FARGATE_PROFILES; do
      echo "Deleting Fargate profile $FP from cluster $CLUSTER..."
      aws eks delete-fargate-profile --cluster-name $CLUSTER --fargate-profile-name $FP --region $REGION
    done
    echo "Waiting for Fargate profiles to be deleted..."
    for FP in $FARGATE_PROFILES; do
      while true; do
        STATUS=$(aws eks describe-fargate-profile --cluster-name $CLUSTER --fargate-profile-name $FP --region $REGION --query "fargateProfile.status" --output text 2>/dev/null || echo "DELETED")
        if [[ "$STATUS" == "DELETED" ]]; then
          break
        fi
        echo "Waiting for Fargate profile $FP to be deleted..."
        sleep 15
      done
    done
  else
    echo "No Fargate profiles found in cluster $CLUSTER."
  fi

  # Finally delete the EKS cluster
  echo "Deleting EKS cluster $CLUSTER..."
  aws eks delete-cluster --name $CLUSTER --region $REGION
  echo "Waiting for cluster $CLUSTER to be deleted..."
  aws eks wait cluster-deleted --name $CLUSTER --region $REGION

  echo "Cluster $CLUSTER deleted successfully."
done

echo "All EKS clusters deleted in region: $REGION."
# scriptname regionname
