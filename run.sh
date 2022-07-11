#!/bin/bash

set -euxo pipefail

while true; do
    echo "Testing Build"

    rm -f run.plan

    terraform plan -out run.plan
    terraform apply run.plan

    sleep 60

    terraform destroy --auto-approve

    sleep 30
done