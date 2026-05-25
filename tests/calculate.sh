#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

cd $1

echo "Count of PASS variants from the output vcf"
for v in *.vcf.gz;do zcat $v | grep -v ^# | grep PASS | wc -l;done
