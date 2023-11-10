#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "$(dirname "$0")/lib.sh"

function entity_by_selector_exists() {
    local ns
    local entity
    local l
    local count

    ns="$1"
    entity="$2"
    l="$3"
    count=$( kubectl -n "$ns" get "$entity" -l "$l" -o name 2>/dev/null | wc -l )

    debug "Number of $entity entities in $ns with label $l: $count"
    [ "$count" -gt 0 ]
}

function wait_for_entity_by_selector() {
    local timeout
    local ns
    local entity
    local l
    local before
    local now

    timeout="$1"
    ns="$2"
    entity="$3"
    l="$4"
    before=$(date --utc +%s)

    while ! entity_by_selector_exists "$ns" "$entity" "$l"; do
        now=$(date --utc +%s)
        if [[ $(( now - before )) -ge "$timeout" ]]; then
            fatal "Required $entity did not appeared before timeout"
        fi
        debug "Still not ready ($(( now - before ))/$timeout), waiting and trying again"
        sleep 3
    done
}

DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES="${DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES:-1/2Gi/1/2Gi}"   # In form of "requests.cpu/requests.memory/limits.cpu/limits.memory", use "///" to skip this
pipelines_controller_resources_requests_cpu="$( echo "$DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES" | cut -d "/" -f 1 )"
pipelines_controller_resources_requests_memory="$( echo "$DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES" | cut -d "/" -f 2 )"
pipelines_controller_resources_limits_cpu="$( echo "$DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES" | cut -d "/" -f 3 )"
pipelines_controller_resources_limits_memory="$( echo "$DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES" | cut -d "/" -f 4 )"

info "Deploy pipelines $DEPLOYMENT_TYPE/$DEPLOYMENT_VERSION"
if [ "$DEPLOYMENT_TYPE" == "downstream" ]; then

    DEPLOYMENT_CSV_VERSION="$DEPLOYMENT_VERSION.0"
    [ "$DEPLOYMENT_VERSION" == "1.11" ] && DEPLOYMENT_CSV_VERSION="1.11.1"

    cat <<EOF | kubectl apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/openshift-pipelines-operator-rh.openshift-operators: ""
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: pipelines-${DEPLOYMENT_VERSION}
  installPlanApproval: Manual
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: openshift-pipelines-operator-rh.v${DEPLOYMENT_CSV_VERSION}
EOF

    info "Wait for installplan to appear"
    wait_for_entity_by_selector 300 openshift-operators InstallPlan operators.coreos.com/openshift-pipelines-operator-rh.openshift-operators=
    ip_name=$(kubectl -n openshift-operators get installplan -l operators.coreos.com/openshift-pipelines-operator-rh.openshift-operators= -o name)
    kubectl -n openshift-operators patch -p '{"spec":{"approved":true}}' --type merge "$ip_name"

    if [ "$DEPLOYMENT_VERSION" == "1.11" ]; then
        warning "Configure resources for tekton-pipelines-controller is supported since 1.12"
    else
        info "Configure resources for tekton-pipelines-controller: $DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES"
        wait_for_entity_by_selector 300 "" TektonConfig openshift-pipelines.tekton.dev/sa-created=true
        if [ -n "$pipelines_controller_resources_requests_cpu" ]; then
            kubectl patch TektonConfig/config --type merge --patch '{"spec":{"pipeline":{"options":{"deployments":{"tekton-pipelines-controller":{"spec":{"template":{"spec":{"containers":[{"name":"tekton-pipelines-controller","resources":{"requests":{"cpu":"'"$pipelines_controller_resources_requests_cpu"'"}}}]}}}}}}}}}'
        fi
        if [ -n "$pipelines_controller_resources_requests_memory" ]; then
            kubectl patch TektonConfig/config --type merge --patch '{"spec":{"pipeline":{"options":{"deployments":{"tekton-pipelines-controller":{"spec":{"template":{"spec":{"containers":[{"name":"tekton-pipelines-controller","resources":{"requests":{"memory":"'"$pipelines_controller_resources_requests_memory"'"}}}]}}}}}}}}}'
        fi
        if [ -n "$pipelines_controller_resources_limits_cpu" ]; then
            kubectl patch TektonConfig/config --type merge --patch '{"spec":{"pipeline":{"options":{"deployments":{"tekton-pipelines-controller":{"spec":{"template":{"spec":{"containers":[{"name":"tekton-pipelines-controller","resources":{"limits":{"cpu":"'"$pipelines_controller_resources_limits_cpu"'"}}}]}}}}}}}}}'
        fi
        if [ -n "$pipelines_controller_resources_limits_memory" ]; then
            kubectl patch TektonConfig/config --type merge --patch '{"spec":{"pipeline":{"options":{"deployments":{"tekton-pipelines-controller":{"spec":{"template":{"spec":{"containers":[{"name":"tekton-pipelines-controller","resources":{"limits":{"memory":"'"$pipelines_controller_resources_limits_memory"'"}}}]}}}}}}}}}'
        fi
    fi

    info "Wait for deployment to finish"
    wait_for_entity_by_selector 300 openshift-pipelines pod app=tekton-pipelines-controller
    kubectl -n openshift-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-pipelines-controller
    wait_for_entity_by_selector 300 openshift-pipelines pod app=tekton-pipelines-webhook
    kubectl -n openshift-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-pipelines-webhook

    info "Deployment finished"
    kubectl -n openshift-pipelines get pods

elif [ "$DEPLOYMENT_TYPE" == "upstream" ]; then

    info "Prepare project"
    kubectl create namespace tekton-pipelines

    info "Setup policy"
    oc adm policy add-scc-to-user anyuid -z tekton-pipelines-controller
    oc adm policy add-scc-to-user anyuid -z tekton-pipelines-webhook

    info "Deploy yaml"
    if [ "$DEPLOYMENT_VERSION" == "stable" ]; then
        curl https://storage.googleapis.com/tekton-releases/pipeline/latest/release.notags.yaml \
            | yq 'del(.spec.template.spec.containers[].securityContext.runAsUser, .spec.template.spec.containers[].securityContext.runAsGroup)' \
            | kubectl apply --validate=warn -f - || true
    elif [ "$DEPLOYMENT_VERSION" == "nightly" ]; then
        curl https://storage.googleapis.com/tekton-releases-nightly/pipeline/latest/release.notags.yaml \
            | yq 'del(.spec.template.spec.containers[].securityContext.runAsUser, .spec.template.spec.containers[].securityContext.runAsGroup)' \
            | kubectl apply --validate=warn -f - || true
    else
        fatal "Unknown deployment version '$DEPLOYMENT_VERSION'"
    fi

    info "Enabling user workload monitoring"
    rm -f config.yaml
    oc -n openshift-monitoring extract configmap/cluster-monitoring-config --to=. --keys=config.yaml
    sed -i '/^enableUserWorkload:/d' config.yaml
    echo -e "\nenableUserWorkload: true" >> config.yaml
    cat config.yaml
    oc -n openshift-monitoring set data configmap/cluster-monitoring-config --from-file=config.yaml
    wait_for_entity_by_selector 300 openshift-user-workload-monitoring StatefulSet operator.prometheus.io/name=user-workload
    kubectl -n openshift-user-workload-monitoring rollout status --watch --timeout=600s StatefulSet/prometheus-user-workload
    kubectl -n openshift-user-workload-monitoring wait --for=condition=ready pod -l app.kubernetes.io/component=prometheus
    kubectl -n openshift-user-workload-monitoring get pod

    info "Setup monitoring"
    cat <<EOF | kubectl -n tekton-pipelines apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  labels:
    app: controller
  annotations:
    networkoperator.openshift.io/ignore-errors: ""
  name: openshift-pipelines-monitor
  namespace: tekton-pipelines
spec:
  endpoints:
    - interval: 10s
      port: http-metrics
      honorLabels: true
  jobLabel: app
  namespaceSelector:
    matchNames:
      - openshift-pipelines
  selector:
    matchLabels:
      app: tekton-pipelines-controller
EOF

    info "Configure resources for tekton-pipelines-controller: $DEPLOYMENT_PIPELINES_CONTROLLER_RESOURCES"
    wait_for_entity_by_selector 300 tekton-pipelines pod app=tekton-pipelines-controller
    if [ -n "$pipelines_controller_resources_requests_cpu" ]; then
        kubectl -n tekton-pipelines set resources deployment/tekton-pipelines-controller \
            -c tekton-pipelines-controller \
            --requests "cpu=$pipelines_controller_resources_requests_cpu"
    fi
    if [ -n "$pipelines_controller_resources_requests_memory" ]; then
        kubectl -n tekton-pipelines set resources deployment/tekton-pipelines-controller \
            -c tekton-pipelines-controller \
            --requests "memory=$pipelines_controller_resources_requests_memory"
    fi
    if [ -n "$pipelines_controller_resources_limits_cpu" ]; then
        kubectl -n tekton-pipelines set resources deployment/tekton-pipelines-controller \
            -c tekton-pipelines-controller \
            --limits "cpu=$pipelines_controller_resources_limits_cpu"
    fi
    if [ -n "$pipelines_controller_resources_limits_memory" ]; then
        kubectl -n tekton-pipelines set resources deployment/tekton-pipelines-controller \
            -c tekton-pipelines-controller \
            --limits "memory=$pipelines_controller_resources_limits_memory"
    fi

    info "Wait for deployment to finish"
    wait_for_entity_by_selector 300 tekton-pipelines pod app=tekton-pipelines-webhook
    kubectl -n tekton-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-pipelines-webhook
    kubectl -n tekton-pipelines wait --for=condition=ready --timeout=300s pod -l app=tekton-pipelines-controller

    info "Deployment finished"
    kubectl -n tekton-pipelines get pods

else

    fatal "Unknown deployment type '$DEPLOYMENT_TYPE'"

fi
