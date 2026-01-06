#!/usr/bin/bash

## Variables - This is what you need to configure
#IPADDR=10.133.211.51 # Put the IP address of the machine here, we will configure the next 18 IP's for you


# Configure IP addresses
#ip a|grep "10.133"|cut -d "." -f 4 | cut -d "/" -f 1
SPACING=`cat /etc/netplan/*.yaml|grep -A10 ethernets|grep -A1 addresses|tail -n1|awk -F'[0-9]' '{ print $1 }'`
#IPADDR=`cat /etc/netplan/*.yaml|grep -A10 ethernets|grep -A1 addresses|tail -n1|cut -d "-" -f2|cut -d " " -f2|cut -d "-" -f2|cut -d "/" -f1`
IPADDR=`cat /etc/netplan/*.yaml |grep -A5 ethernets|grep -A1 addresses|tail -n 1|cut -d "-" -f 2|cut -d "/" -f 1|sed 's/ //g'`
SUBNET=`cat /etc/netplan/*.yaml|grep -A5 ethernets|grep -A1 addresses|tail -n1|cut -d "/" -f2`
PREFIX=`echo $IPADDR |cut -d "." -f 1-3`
#PREFIX=`cat /etc/netplan/*.yaml|grep -A10 ethernets|grep -A1 addresses|tail -n1|cut -d $IPADDR -f1`
FIRSTIP=`echo $IPADDR |cut -d "." -f 4 | cut -d "/" -f 1`
#awk -F'.' '{ print $2-3 }'
LASTIP="$(($FIRSTIP + 18))"
NEXTIP=$FIRSTIP
echo First IP $PREFIX.$FIRSTIP"/"$SUBNET
echo Last IP  $PREFIX.$LASTIP"/"$SUBNET
echo Please add this to your netplan yaml file and run netplan apply
while [ $NEXTIP -ne $LASTIP ]; do
	NEXTIP="$(($FIRSTIP + 1))"
#	echo"        - "$PREFIX.$FIRSTIP"/"$SUBNET
#	sed '/^\s*-\ $FIRSTIP.*/a \ \ \ \ \ \ \ \ -\ $NEXTIP\/$SUBNET' roea.yaml
	echo \ \ \ \ \ \ \ \ -\ $PREFIX.$NEXTIP"/"$SUBNET
	FIRSTIP="$(($FIRSTIP + 1))"
done

