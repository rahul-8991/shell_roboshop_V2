#!/bin/bash

# Get all instance names from all instances in any state
INSTANCES=($(aws ec2 describe-instances \
  --query "Reservations[*].Instances[*].Tags[?Key=='Name'].Value[]" \
  --output text))

for instance in "${INSTANCES[@]}"
do
        IP=$(aws ec2 describe-instances \
            --filters "Name=tag:Name,Values=$instance" \
            --query "Reservations[0].Instances[0].PublicIpAddress" \
            --output text)
    echo "$instance IP address: $IP"
done
