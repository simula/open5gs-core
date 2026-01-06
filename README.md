# open5gs-core
Open 5GS Core deployment scripts

These scripts are intended to install and configure the Open5GS software on Ubuntu. They should work on any Debian flavour but have been tested in Ubuntu 20.04 and 22.04.
Run install.sh to install the pre-requisites and packages and then run the config.sh script to configure the elements.

Things to do:
1. Make the IP additions to netplan automatic.
2. Make the IP additions for the elements automatic.
3. Make the script roaming-setup friendly once we have roaming between cores configured.
