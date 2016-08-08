#!/bin/bash -x

HOSTNAME_TAG=usaws
HOSTNAME_PRIM=usaws
cat > /etc/sysconfig/network << EOF
NETWORKING=yes
NETWORKING_IPV6=no
HOSTNAME=${HOSTNAME_TAG}
EOF

IP=$(curl --silent http://169.254.169.254/latest/meta-data/local-ipv4)
INST_ID=$(curl --silent http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl --silent http://169.254.169.254/latest/meta-data/placement/availability-zone)
# Chop off last char to configure aws region, as the AZ is usually us-east-1d, but we need it to be us-east-1
AZ_CONF="${AZ%?}"

echo "${IP}	${HOSTNAME_TAG}.us.kellogg.com ${HOSTNAME_TAG}" >> /etc/hosts

echo ${HOSTNAME_TAG} > /proc/sys/kernel/hostname
service network restart

sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin no/PermitRootLogin yes/g' /etc/ssh/sshd_config
service sshd restart

echo "Taking backup of up/down script if they exist"
if [ -f /rootutils/up_${HOSTNAME_PRIM} ]
then
  echo mv /rootutils/up_${HOSTNAME_PRIM} /rootutils/up_${HOSTNAME_PRIM}_primary
fi

if [ -f /rootutils/down_${HOSTNAME_PRIM} ]
then
  echo mv /rootutils/down_${HOSTNAME_PRIM} /rootutils/down_${HOSTNAME_PRIM}_primary
fi

echo "Creating up/down script for new host.  It is assumed no app related stuff is running on standby host"
echo "If this is required(app stuff running on standby DB), please manually update up/down script"
# up script
echo "#DB Startup" > /rootutils/up_${HOSTNAME_TAG}
echo "su - CHANGE_USER -c "\""/oracle/sqlutils/start_listener.ksh CHANGE_ORACLE_SID"\""" >> /rootutils/up_${HOSTNAME_TAG}
echo "su - CHANGE_USER -c "\""/oracle/sqlutils/start_db.ksh CHANGE_ORACLE_SID"\""" >> /rootutils/up_${HOSTNAME_TAG}
# down script
echo "#DB shutdown" > /rootutils/down_${HOSTNAME_TAG}
echo "su - CHANGE_USER -c "\""/oracle/sqlutils/stop_listener.ksh CHANGE_ORACLE_SID"\""" >> /rootutils/down_${HOSTNAME_TAG}
echo "su - CHANGE_USER -c "\""/oracle/sqlutils/stop_db.ksh CHANGE_ORACLE_SID"\""" >> /rootutils/down_${HOSTNAME_TAG}

cd ~
echo > .puppet_custom_profile
echo "adding custom entries to bash_profile"
if grep -i "data guard" ~/.bash_profile
then
  echo "No need to put entries in bash_profile, one already exist"
else
  echo "adding entries to .bash_profile"
  cp ~/.bash_profile ~/.bash_profile_before_dg_entries
  echo echo ------------------------------------>> ~/.bash_profile
  echo echo SPECIAL INSTRUCTIONS FOR DATA GUARD >> ~/.bash_profile
  echo echo ------------------------------------>> ~/.bash_profile
  echo echo >> ~/.bash_profile
  echo echo ---------------------------------------------------------- >> ~/.bash_profile
  echo echo - This system is part of replicated database ON ${HOSTNAME_PRIM} >> ~/.bash_profile
  echo echo - WHEN A NEW MOUNT POINT IS CREATED ON THIS SERVER >> ~/.bash_profile
  echo echo - PLEASE CREATE THE SAME MOUNT POINT ON ${HOSTNAME_PRIM} >> ~/.bash_profile
  echo echo - AS THERE IS STANDBY SERVER IN PLACE FOR THIS DB >> ~/.bash_profile
  echo echo ---------------------------------------------------------- >> ~/.bash_profile
  echo echo >> ~/.bash_profile
fi
rm -rf /etc/puppetlabs/puppet/ssl
puppet agent -t &

# Sleep 200 seconds for instance check to pass(as it takes a while)
echo sleeping 200 seconds for AWS instance prechecks to pass
sleep 200

