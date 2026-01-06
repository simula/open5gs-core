#!/usr/bin/bash

# This script creates a copy/paste output for you to add to the IP configuration file for neplan
# in addition to configuring all of the yaml files needed for Open5GS.
# The expectation is that the next 20 IP's in the range your server is configured on are free
# for this purpose.
# Copyright Clayton Milos (2025)

# Configure IP's
chmod +x IP/config-ip.sh
./IP/config-ip.sh

# Backup the old directories
echo "Backing up the old directories with current date and time."
cp -r /etc/open5gs /etc/open5gs-`/bin/date "+%Y-%m-%d-%H%M"`
cp -r /etc/freeDiameter /etc/freeDiameter-`/bin/date "+%Y-%m-%d-%H%M"`

# Create the yaml files
echo "Preparing yaml files"
rm yamls/*.yaml
for substitute in `ls yamls/*.template`; do
	subname=`echo $substitute| awk -F'[.]' '{ print $1 }' | cut -d "/" -f2`;
	echo "Creating" $subname "yaml configuration."
	for line in `cat IP/IPs.txt`; do
		NODENAME=`echo $line | awk -F'[=]' '{ print $1 }'`;
		NODEVALUE=`echo $line | awk -F'[=]' '{ print $2 }'`;
		if test -f yamls/$subname.yaml; then
			sed -i s/$NODENAME/$NODEVALUE/g yamls/$subname.yaml;
		else
			cat $substitute | sed s/$NODENAME/$NODEVALUE/g > yamls/$subname.yaml;
		fi
	done
	echo "Done for" $subname". Copying to /etc/open5gs."
	cp yamls/$subname.yaml /etc/open5gs/$subname.yaml
done
echo "Yaml files completed"
echo

# Create the freeDiameter files
echo "Preparing freeDiameter files"
rm freeDiameter/*.conf
for substitutes in `ls freeDiameter/*.template`; do
	subsname=`echo $substitutes| awk -F'[.]' '{ print $1 }' | cut -d "/" -f2`;
	echo "Creating" $subsname "Diameter configuration."
	for line in `cat IP/IPs.txt`; do
		NODENAME=`echo $line | awk -F'[=]' '{ print $1 }'`;
		NODEVALUE=`echo $line | awk -F'[=]' '{ print $2 }'`;
		if test -f freeDiameter/$subsname.conf; then
			sed -i s/$NODENAME/$NODEVALUE/g freeDiameter/$subsname.conf;
		else
			cat $substitutes | sed s/$NODENAME/$NODEVALUE/g > freeDiameter/$subsname.conf;
		fi
	done
	echo "Done for" $subsname". Copying to /etc/freeDiameter."
	cp freeDiameter/$subsname.conf /etc/freeDiameter/$subsname.conf
done
echo "freeDiameter files completed"
echo

# Restart the daemons so that they can read the new config files
echo "Restarting all daemons"
chmod +x restart-all-open5gs.sh
./restart-all-open5gs.sh
echo "These open5gs daemons are currently running"
ps ax|grep open5gs | grep -v grep
echo
echo

# Some last words
echo "Check logfiles with tail -n 100 -F /var/log/open5gs/*.log to see if there is any significant complaining"
echo "If nothing is complaining too much then ssh to this host using ssh -L \"127.0.0.1:9999:127.0.0.1:9999\" user@hostname"
echo "and connect to http://127.0.0.1:9999 on your local browser using admin/1423 to configure some SIM cards"


