#!/bin/bash
#
# Parameters: No Parameters required.  
#
# For any comments look at dg_driver.sh script
# 
# This script just calls dg_driver.sh script, so we can output STDOUT to a log file
#
# Run this script as the OWNER OF THE DATABASE
# eg.. if oraprd owns the database, then run this as oraprd user

${PWD}/dg_driver.sh | tee dg_output$$.log
