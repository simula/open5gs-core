#!/usr/bin/bash

# This script creates a copy/paste output for you to add to the IP configuration file for neplan
# in addition to configuring all of the yaml files needed for Open5GS.
# The expectation is that the next 20 IP's in the range your server is configured on are free
# for this purpose.
# Copyright Clayton Milos (2025)

# Read the MNC's
echo "Enter current MNC"
read current
if [[ $current =~ ^[[:digit:]]{2,3}$ && $current -gt 0 && $current -le 999 ]]; then
	echo "Seems reasonable, enter new MNC";
	read new
	if [[ $new =~ ^[[:digit:]]{2,3}$ && $new -gt 0 && $new -le 999 ]]; then
		echo "Both are feasible, continuing"
	else
		echo "Error, MNC should be between 01 and 999"; exit
	fi
else
	echo "Error, MNC should be between 01 and 999"; exit
fi

if [ $new -ne $current ]; then
	echo ""
	echo "Backing up the old directories with current date and time"
	cp -r /etc/open5gs /etc/open5gs-`/bin/date "+%Y-%m-%d-%H%M"`
	echo ""
	echo Changing MNC from $current to $new for AMF, MME and NRF
	sed -i s/mnc:\ $current/mnc:\ $new/g /etc/open5gs/amf.yaml
	sed -i s/mnc:\ $current/mnc:\ $new/g /etc/open5gs/mme.yaml
	sed -i s/mnc:\ $current/mnc:\ $new/g /etc/open5gs/nrf.yaml
	echo ""
	echo "Restarting AMF, MME and NRF"
	systemctl restart open5gs-nrfd
	systemctl restart open5gs-amfd
	systemctl restart open5gs-mmed
else
	echo "Old and new MNC's should probably be different."
fi


echo "These changed open5gs daemons are currently running"
ps ax | egrep "nrf|mme|amf" | grep -v grep
echo ""
echo ""
# Some last words
echo "Check logfiles with tail -n 100 -F /var/log/open5gs/*.log to see if there is any significant complaining"
echo ""

