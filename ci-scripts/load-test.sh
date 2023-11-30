#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "$(dirname "$0")/lib.sh"

info "Setup"
cd tests/scaling-pipelines/
kubectl create ns benchmark
kubectl config set-context --current --namespace=benchmark
kubectl apply -f pipeline.yaml

info "Benchmark"
time ./benchmark-tekton.sh --total "${TEST_TOTAL:-100}" --concurrent "${TEST_CONCURRENT:-10}" --run "${TEST_RUN:-./run.yaml}" --debug

info "Dump Pods"
kubectl get pods -o=json >pods.json

info "Cleanup PipelineRuns: $TEST_DO_CLEANUP"
if ${TEST_DO_CLEANUP:-true}; then
    kubectl delete --all PipelineRuns
fi
