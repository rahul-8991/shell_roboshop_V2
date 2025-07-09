#!/bin/bash

read -s -p "Enter SSH password: " PASSWORD
echo -e "\n🔐 Password captured. Proceeding..."

AMI_ID="ami-09c813fb71547fc4f"
SG_ID="sg-0c353a79d89785c5b"
ZONE_ID="Z0176514X7F0V5F420IF"
DOMAIN_NAME="rahuldaws.shop"
USER="ec2-user"
GIT_REPO="https://github.com/rahul-8991/shell_roboshop_V2.git"
CLONE_DIR="/home/ec2-user/shell_roboshop_V2"
INSTANCES=("mongodb" "catalogue" "frontend")

for instance in "${INSTANCES[@]}"
do
  echo "🚀 Launching EC2 instance: $instance"
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type t2.micro \
    --security-group-ids $SG_ID \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$instance}]" \
    --query "Instances[0].InstanceId" \
    --output text)

  echo "⏳ Waiting 20 seconds for public IP assignment..."
  sleep 20

  IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

  echo "🌐 $instance Public IP: $IP"

  RECORD_NAME=$([[ "$instance" == "frontend" ]] && echo "$DOMAIN_NAME" || echo "$instance.$DOMAIN_NAME")

  echo "📡 Updating DNS: $RECORD_NAME → $IP"
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --change-batch '{
      "Comment": "Update DNS for EC2 instance",
      "Changes": [ {
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "'"$RECORD_NAME"'",
          "Type": "A",
          "TTL": 1,
          "ResourceRecords": [{"Value": "'"$IP"'"}]
        }
      }]
    }'

  echo "🔐 Connecting to $instance and running setup..."

  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USER@$IP" <<EOF
set -e

rm -rf $CLONE_DIR
git clone $GIT_REPO $CLONE_DIR

sudo INSTANCE_NAME="$instance" CLONE_DIR="$CLONE_DIR" bash -c '
cd "\$CLONE_DIR" || exit 1
source "\$CLONE_DIR/common.sh"

if [ "\$INSTANCE_NAME" == "mongodb" ]; then
  app_name=mongodb
  check_root

  cp "\$CLONE_DIR/mongo.repo" /etc/yum.repos.d/mongodb.repo
  VALIDATE \$? "Copying MongoDB repo"

  dnf makecache -y &>>\$LOG_FILE
  dnf install mongodb-org -y &>>\$LOG_FILE
  VALIDATE \$? "Installing mongodb server"

  systemctl enable mongod &>>\$LOG_FILE
  systemctl start mongod &>>\$LOG_FILE
  VALIDATE \$? "Starting MongoDB"

  sed -i "s/127.0.0.1/0.0.0.0/g" /etc/mongod.conf
  systemctl restart mongod &>>\$LOG_FILE
  VALIDATE \$? "Restarting MongoDB"

  print_time

elif [ "\$INSTANCE_NAME" == "catalogue" ]; then
  app_name=catalogue
  check_root
  app_setup
  nodejs_setup
  systemd_setup

  cp "\$CLONE_DIR/mongo.repo" /etc/yum.repos.d/mongo.repo 
  dnf install mongodb-mongosh -y &>>\$LOG_FILE
  VALIDATE \$? "Installing MongoDB Client"

  STATUS=\$(mongosh --host mongodb.rahuldaws.shop --eval "db.getMongo().getDBNames().indexOf('catalogue')")
  if [ \$STATUS -lt 0 ]; then
    mongosh --host mongodb.rahuldaws.shop </app/db/master-data.js &>>\$LOG_FILE
    VALIDATE \$? "Loading data into MongoDB"
  else
    echo -e "Data already loaded ... \$Y SKIPPING \$N"
  fi

  print_time

elif [ "\$INSTANCE_NAME" == "frontend" ]; then
  check_root

  dnf module disable nginx -y &>>\$LOG_FILE
  dnf module enable nginx:1.24 -y &>>\$LOG_FILE
  dnf install nginx -y &>>\$LOG_FILE
  systemctl enable nginx &>>\$LOG_FILE
  systemctl start nginx
  VALIDATE \$? "Starting Nginx"

  rm -rf /usr/share/nginx/html/* &>>\$LOG_FILE
  curl -o /tmp/frontend.zip https://roboshop-artifacts.s3.amazonaws.com/frontend-v3.zip &>>\$LOG_FILE
  cd /usr/share/nginx/html
  unzip /tmp/frontend.zip &>>\$LOG_FILE

  rm -rf /etc/nginx/nginx.conf &>>\$LOG_FILE
  cp "\$CLONE_DIR/nginx.conf" /etc/nginx/nginx.conf
  systemctl restart nginx
  VALIDATE \$? "Restarting nginx"

  print_time
fi
'
EOF

  echo "✅ Completed setup for: $instance"
done
