#!/bin/bash

# script was originally written so it can be ran on a newly created instance and hence we see the loop statement
# We have moved running this script from newly created instance to an existing instance which already have IAM role
# assigned and hence we dont need to wait to get temp IAM credential..

INST_ID=CHANGE_ME
AZ=$(curl --silent http://169.254.169.254/latest/meta-data/placement/availability-zone)
# Chop off last char to configure aws region, as the AZ is usually us-east-1d, but we need it to be us-east-1
AZ_CONF="${AZ%?}"

T_BU=
T_ENV=
T_REGION=
T_ROLE=
T_HOSTNAME=

# Create tag for instance
echo sleeping for 5 seconds for running prechecks
nc -z ec2.us-east-1.amazonaws.com 443 > conn_ec2_stat &
sleep 5
grep succeeded conn_ec2_stat
CONN_EC2_STATUS=$?
if [ $CONN_EC2_STATUS -eq 0 ] && [ -f /usr/local/aws/bin/aws ]
then
	/usr/local/aws/bin/aws configure set region ${AZ_CONF}

	# We need to run this ins a loop as it takes a little bit for the EC2 instance to acquire temp IAM credential thru the role assigned
	for (( c=1; c<=30; c++ ))
	do
	/usr/local/aws/bin/aws ec2 describe-instances --instance-id ${INST_ID} > /dev/null
	if [ "$?" -eq 0 ]
	then
		# Create tag for instance
		echo ""
		echo "Tagging EC2 Secondary Instance-id: ${INST_ID}"
		/usr/local/aws/bin/aws ec2 create-tags --resources ${INST_ID} --tags Key=Name,Value=${T_HOSTNAME} Key=BU,Value=${T_BU} Key=Region,Value=${T_REGION} Key=Role,Value=${T_ROLE} Key=Env,Value=${T_ENV}

		# Create tag for volumes
		/usr/local/aws/bin/aws ec2 describe-instances --instance-id ${INST_ID} | grep -oP 'vol-\w+'  > /tmp/list_volumes
		for i in $(cat /tmp/list_volumes);do
		echo ""
		echo "Tagging volume attached to secondary Instance, Volume-id: $i"
		/usr/local/aws/bin/aws ec2 create-tags --resources $i --tags Key=Name,Value=${T_HOSTNAME} Key=BU,Value=${T_BU} Key=Region,Value=${T_REGION} Key=Role,Value=${T_ROLE} Key=Env,Value=${T_ENV}
		done

		# Create tag for Nics
		/usr/local/aws/bin/aws ec2 describe-instances --instance-id ${INST_ID}  | grep -v attach | grep -oP 'eni-\w+'  > /tmp/list_enis
		for j in $(cat /tmp/list_enis);do
		echo ""
		echo "Tagging ENI attached to secondary Instance, ENI-id: $j"			
		/usr/local/aws/bin/aws ec2 create-tags --resources $j --tags Key=Name,Value=${T_HOSTNAME} Key=BU,Value=${T_BU} Key=Region,Value=${T_REGION} Key=Role,Value=${T_ROLE} Key=Env,Value=${T_ENV}
		done
		echo ""
		echo "tagging of instance resources finished...."
		# Break out of loop after tagging the instance	
		break
	else
		echo "Trying to Tag instance resource, stilling failing to acquire temp credential thru IAM role, Try# $c"
		sleep 30
	fi
	done
else
		#AWS CLI download and Installation if CLI is not installed.  
		nc -z s3.amazonaws.com 443 > conn_s3_stat &
		sleep 5
		grep succeeded conn_s3_stat
		CONN_S3_STATUS=$?
		if [ $CONN_S3_STATUS -eq 0 ]
		then
			curl "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o "/usr/awscli-bundle.zip"
			unzip /usr/awscli-bundle.zip -d /usr/awscmdline/
			/usr/awscmdline/awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws
			/usr/local/aws/bin/aws configure set region ${AZ_CONF}
			
			# We need to run this ins a loop as it takes a little bit for the EC2 instance to acquire temp IAM credential thru the role assigned
			for (( c=1; c<=30; c++ ))
			do
			/usr/local/aws/bin/aws ec2 describe-instances --instance-id ${INST_ID} > /dev/null
			if [ "$?" -eq 0 ]
			then

				# Create tag for instance
				echo ""
				echo "Tagging EC2 Secondary Instance-id: ${INST_ID}"				
				/usr/local/aws/bin/aws ec2 create-tags --resources ${INST_ID} --tags Key=Name,Value=${T_HOSTNAME} Key=BU,Value=${T_BU} Key=Region,Value=${T_REGION} Key=Role,Value=${T_ROLE} Key=Env,Value=${T_ENV}

				# Create tag for volumes
				/usr/local/aws/bin/aws ec2 describe-instances --instance-id ${INST_ID} | grep -oP 'vol-\w+'  > /tmp/list_volumes
				for i in $(cat /tmp/list_volumes);do
				echo ""
				echo "Tagging volume attached to secondary Instance, Volume-id: $i"				
				/usr/local/aws/bin/aws ec2 create-tags --resources $i --tags Key=Name,Value=${T_HOSTNAME} Key=BU,Value=${T_BU} Key=Region,Value=${T_REGION} Key=Role,Value=${T_ROLE} Key=Env,Value=${T_ENV}
				done

				# Create tag for Nics
				/usr/local/aws/bin/aws ec2 describe-instances --instance-id ${INST_ID}  | grep -v attach | grep -oP 'eni-\w+'  > /tmp/list_enis
				for j in $(cat /tmp/list_enis);do
				echo ""
				echo "Tagging ENI attached to secondary Instance, ENI-id: $j"					
				/usr/local/aws/bin/aws ec2 create-tags --resources $j --tags Key=Name,Value=${T_HOSTNAME} Key=BU,Value=${T_BU} Key=Region,Value=${T_REGION} Key=Role,Value=${T_ROLE} Key=Env,Value=${T_ENV}
				done
				echo ""
				echo "tagging of instance resources finished...."
				break
			else
				echo "Trying to Tag instance resource, stilling failing to acquire temp credential thru IAM role, Try# $c"
				sleep 30
			fi
			done
		else
				echo "Looks like we cannot make an API call to S3 to download AWS CLI.."		
				echo "Please fix that issue, UNABLE TO TAG RESOURCE ON THIS ISNTANCE"
		fi
fi
