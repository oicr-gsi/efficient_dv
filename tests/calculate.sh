#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

cd $1

echo "Count of PASS variants from the output vcf"
for v in *.vcf.gz;do zcat $v | grep -v ^# | awk '$7=="PASS" && $6>10' | wc -l | awk '{printf "%.0f\n", $0/1000}';done
