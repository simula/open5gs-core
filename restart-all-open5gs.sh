#!/usr/bin/bash

# Script to restart all Open5GS services in an order that they should be least unhappy about

systemctl restart open5gs-hssd
systemctl restart open5gs-nrfd
systemctl restart open5gs-udmd
systemctl restart open5gs-nssfd
systemctl restart open5gs-seppd
systemctl restart open5gs-pcrfd
systemctl restart open5gs-pcfd
systemctl restart open5gs-upfd
systemctl restart open5gs-sgwud
systemctl restart open5gs-sgwcd
systemctl restart open5gs-udrd
systemctl restart open5gs-bsfd
systemctl restart open5gs-scpd
systemctl restart open5gs-smfd
systemctl restart open5gs-ausfd
systemctl restart open5gs-amfd
systemctl restart open5gs-mmed

