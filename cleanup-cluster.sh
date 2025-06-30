#!/bin/bash

# Kubernetes Deployment Lifecycle Management Script
# - Deployments older than 3 days → scale to 0 replicas
# - Deployments older than 7 days → delete (optional)
# Author: Deployment Lifecycle Manager
# Version: 1.0

set -euo pipefail

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Configuration
DRY_RUN=${DRY_RUN:-true}
TARGET_NAMESPACE=${TARGET_NAMESPACE:-""}
EXCLUDED_NAMESPACES="kube-system,kube-public,kube-node-lease,default"
SCALE_DOWN_AFTER_DAYS=${SCALE_DOWN_AFTER_DAYS:-3}
DELETE_AFTER_DAYS=${DELETE_AFTER_DAYS:-7}
DELETE_ENABLED=${DELETE_ENABLED:-false}
LOG_FILE="k8s-deployment-lifecycle-$(date +%Y%m%d_%H%M%S).log"
ANNOTATION_SCALED="deployment-scaler/scaled-down"
ANNOTATION_SCALED_DATE="deployment-scaler/scaled-down-date"
ANNOTATION_EXCLUDE="deployment-scaler/exclude"

# Helper functions
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${PURPLE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

# Check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed or not available in PATH"
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        error "No connection to Kubernetes cluster"
        exit 1
    fi
    
    log "Kubernetes cluster connection: OK"
}

# Get namespaces to check
get_target_namespaces() {
    if [[ -n "$TARGET_NAMESPACE" ]]; then
        echo "$TARGET_NAMESPACE"
    else
        kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | \
        grep -vE "^($(echo $EXCLUDED_NAMESPACES | tr ',' '|'))$"
    fi
}

# Calculate resource age in days
calculate_age_in_days() {
    local creation_time=$1
    local current_time=$(date +%s)
    local creation_timestamp=$(date -d "$creation_time" +%s 2>/dev/null || echo "0")
    local age_seconds=$((current_time - creation_timestamp))
    local age_days=$((age_seconds / 86400))
    echo $age_days
}

# Check if deployment is excluded from processing
is_deployment_excluded() {
    local namespace=$1
    local deployment_name=$2
    
    local exclude_annotation=$(kubectl get deployment "$deployment_name" -n "$namespace" \
        -o jsonpath="{.metadata.annotations['$ANNOTATION_EXCLUDE']}" 2>/dev/null || echo "")
    
    if [[ "$exclude_annotation" == "true" ]]; then
        return 0
    fi
    return 1
}

# Check if deployment is already scaled down
is_deployment_scaled_down() {
    local namespace=$1
    local deployment_name=$2
    
    local scaled_annotation=$(kubectl get deployment "$deployment_name" -n "$namespace" \
        -o jsonpath="{.metadata.annotations['$ANNOTATION_SCALED']}" 2>/dev/null || echo "")
    
    if [[ "$scaled_annotation" == "true" ]]; then
        return 0
    fi
    return 1
}

# Get scaled down date
get_scaled_down_date() {
    local namespace=$1
    local deployment_name=$2
    
    kubectl get deployment "$deployment_name" -n "$namespace" \
        -o jsonpath="{.metadata.annotations['$ANNOTATION_SCALED_DATE']}" 2>/dev/null || echo ""
}

# Scale deployment to 0 replicas
scale_deployment_to_zero() {
    local namespace=$1
    local deployment_name=$2
    local current_replica_count=$3
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would scale to 0 replicas: $namespace/$deployment_name (current: $current_replica_count)"
        return
    fi
    
    log "Scaling to 0 replicas: $namespace/$deployment_name (current: $current_replica_count)"
    
    # Save current replica count in annotation
    kubectl annotate deployment "$deployment_name" -n "$namespace" \
        "deployment-scaler/original-replicas=$current_replica_count" --overwrite &>/dev/null
    
    # Scale to 0
    if kubectl scale deployment "$deployment_name" -n "$namespace" --replicas=0 &>/dev/null; then
        # Add scaling annotations
        kubectl annotate deployment "$deployment_name" -n "$namespace" \
            "$ANNOTATION_SCALED=true" --overwrite &>/dev/null
        kubectl annotate deployment "$deployment_name" -n "$namespace" \
            "$ANNOTATION_SCALED_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite &>/dev/null
        
        success "Scaled to 0 replicas: $namespace/$deployment_name"
    else
        error "Failed to scale deployment: $namespace/$deployment_name"
    fi
}

# Delete deployment
delete_deployment() {
    local namespace=$1
    local deployment_name=$2
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would delete deployment: $namespace/$deployment_name"
        return
    fi
    
    log "Deleting deployment: $namespace/$deployment_name"
    
    if kubectl delete deployment "$deployment_name" -n "$namespace" &>/dev/null; then
        success "Deleted deployment: $namespace/$deployment_name"
    else
        error "Failed to delete deployment: $namespace/$deployment_name"
    fi
}

# Restore deployment scaling
restore_deployment_scaling() {
    local namespace=$1
    local deployment_name=$2
    
    local original_replica_count=$(kubectl get deployment "$deployment_name" -n "$namespace" \
        -o jsonpath="{.metadata.annotations['deployment-scaler/original-replicas']}" 2>/dev/null || echo "1")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would restore scaling: $namespace/$deployment_name to $original_replica_count replicas"
        return
    fi
    
    log "Restoring scaling: $namespace/$deployment_name to $original_replica_count replicas"
    
    if kubectl scale deployment "$deployment_name" -n "$namespace" --replicas="$original_replica_count" &>/dev/null; then
        # Remove scaling annotations
        kubectl annotate deployment "$deployment_name" -n "$namespace" \
            "$ANNOTATION_SCALED-" "$ANNOTATION_SCALED_DATE-" "deployment-scaler/original-replicas-" &>/dev/null || true
        
        success "Restored scaling: $namespace/$deployment_name to $original_replica_count replicas"
    else
        error "Failed to restore scaling: $namespace/$deployment_name"
    fi
}

# Process deployments in namespace
process_namespace_deployments() {
    local namespace=$1
    
    log "Processing deployments in namespace: $namespace"
    
    # Get all deployments in namespace
    local deployment_info=$(kubectl get deployments -n "$namespace" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.creationTimestamp}{"|"}{.spec.replicas}{"|"}{.status.replicas}{"\n"}{end}' 2>/dev/null || echo "")
    
    if [[ -z "$deployment_info" ]]; then
        info "No deployments found in namespace $namespace"
        return
    fi
    
    local processed_count=0
    local scaled_count=0
    local deleted_count=0
    local restored_count=0
    
    while IFS='|' read -r deployment_name creation_time spec_replicas status_replicas; do
        if [[ -z "$deployment_name" ]]; then
            continue
        fi
        
        processed_count=$((processed_count + 1))
        
        # Check if deployment is excluded
        if is_deployment_excluded "$namespace" "$deployment_name"; then
            info "Skipping excluded deployment: $namespace/$deployment_name"
            continue
        fi
        
        local age_in_days=$(calculate_age_in_days "$creation_time")
        info "Deployment: $namespace/$deployment_name, age: ${age_in_days} days, replicas: ${spec_replicas:-0}/${status_replicas:-0}"
        
        # Check if deployment should be deleted
        if [[ "$DELETE_ENABLED" == "true" && $age_in_days -ge $DELETE_AFTER_DAYS ]]; then
            if is_deployment_scaled_down "$namespace" "$deployment_name"; then
                local scaled_date=$(get_scaled_down_date "$namespace" "$deployment_name")
                local scaled_age_days=0
                if [[ -n "$scaled_date" ]]; then
                    scaled_age_days=$(calculate_age_in_days "$scaled_date")
                fi
                
                if [[ $scaled_age_days -ge $((DELETE_AFTER_DAYS - SCALE_DOWN_AFTER_DAYS)) ]]; then
                    warn "Deployment marked for deletion (age: ${age_in_days} days, scaled ${scaled_age_days} days ago): $namespace/$deployment_name"
                    delete_deployment "$namespace" "$deployment_name"
                    deleted_count=$((deleted_count + 1))
                    continue
                fi
            fi
        fi
        
        # Check if deployment should be scaled down
        if [[ $age_in_days -ge $SCALE_DOWN_AFTER_DAYS ]]; then
            if ! is_deployment_scaled_down "$namespace" "$deployment_name"; then
                if [[ "${spec_replicas:-0}" -gt 0 ]]; then
                    warn "Deployment marked for scaling (age: ${age_in_days} days): $namespace/$deployment_name"
                    scale_deployment_to_zero "$namespace" "$deployment_name" "${spec_replicas:-0}"
                    scaled_count=$((scaled_count + 1))
                else
                    info "Deployment already has 0 replicas: $namespace/$deployment_name"
                fi
            else
                info "Deployment already scaled down: $namespace/$deployment_name"
            fi
        else
            # Check if scaling should be restored (deployment younger than threshold)
            if is_deployment_scaled_down "$namespace" "$deployment_name"; then
                info "Restoring scaling for young deployment: $namespace/$deployment_name (age: ${age_in_days} days)"
                restore_deployment_scaling "$namespace" "$deployment_name"
                restored_count=$((restored_count + 1))
            fi
        fi
        
    done <<< "$deployment_info"
    
    log "Namespace $namespace - Processed: $processed_count, Scaled: $scaled_count, Deleted: $deleted_count, Restored: $restored_count"
}

# Generate summary report
generate_summary_report() {
    log "=== DEPLOYMENT LIFECYCLE MANAGEMENT REPORT ==="
    log "Date: $(date)"
    log "Mode: $([ "$DRY_RUN" == "true" ] && echo "DRY RUN" || echo "EXECUTION")"
    log "Scale down after: $SCALE_DOWN_AFTER_DAYS days"
    log "Delete after: $DELETE_AFTER_DAYS days (enabled: $DELETE_ENABLED)"
    log ""
    
    # Summary from logs
    local total_scaled=$(grep -c "Scaled to 0 replicas" "$LOG_FILE" 2>/dev/null || echo "0")
    local total_deleted=$(grep -c "Deleted deployment" "$LOG_FILE" 2>/dev/null || echo "0")
    local total_restored=$(grep -c "Restored scaling" "$LOG_FILE" 2>/dev/null || echo "0")
    
    log "Total scaled down: $total_scaled"
    log "Total deleted: $total_deleted"
    log "Total restored: $total_restored"
    log ""
    
    if [[ "$DRY_RUN" == "true" ]]; then
        warn "This was a DRY RUN. To actually perform operations, run with DRY_RUN=false"
    fi
}

# Main function
main() {
    log "=== STARTING DEPLOYMENT LIFECYCLE MANAGEMENT ==="
    log "DRY_RUN: $DRY_RUN"
    log "TARGET_NAMESPACE: ${TARGET_NAMESPACE:-"all (with exclusions)"}"
    log "EXCLUDED_NAMESPACES: $EXCLUDED_NAMESPACES"
    log "SCALE_DOWN_AFTER_DAYS: $SCALE_DOWN_AFTER_DAYS"
    log "DELETE_AFTER_DAYS: $DELETE_AFTER_DAYS"
    log "DELETE_ENABLED: $DELETE_ENABLED"
    log ""
    
    check_kubectl
    
    local target_namespaces=($(get_target_namespaces))
    log "Namespaces to check: ${target_namespaces[*]}"
    log ""
    
    # Process each namespace
    for namespace in "${target_namespaces[@]}"; do
        log "--- Processing namespace: $namespace ---"
        process_namespace_deployments "$namespace"
        log ""
    done
    
    generate_summary_report
    
    log "=== DEPLOYMENT LIFECYCLE MANAGEMENT COMPLETED ==="
    log "Log saved to: $LOG_FILE"
}

# Display help
show_help() {
    cat << EOF
Kubernetes Deployment Lifecycle Management Script

Usage:
    $0 [options]

Environment variables:
    DRY_RUN                - true/false (default: true)
    TARGET_NAMESPACE       - specific namespace (default: all)
    EXCLUDED_NAMESPACES    - excluded namespaces
    SCALE_DOWN_AFTER_DAYS  - days after which to scale to 0 (default: 3)
    DELETE_AFTER_DAYS      - days after which to delete (default: 7)
    DELETE_ENABLED         - true/false enable deletion (default: false)

Deployment annotations (for exclusion):
    deployment-scaler/exclude: "true"  - excludes deployment from processing

Examples:
    # Dry run with default settings (3 days → scale to 0)
    $0

    # Actual execution with different thresholds
    DRY_RUN=false SCALE_DOWN_AFTER_DAYS=5 DELETE_AFTER_DAYS=10 $0

    # Enable deletion after 7 days
    DRY_RUN=false DELETE_ENABLED=true $0

    # For specific namespace
    TARGET_NAMESPACE=my-app DRY_RUN=false $0

Exclude deployment from processing:
    kubectl annotate deployment my-app deployment-scaler/exclude=true

Functionality:
    - Scales deployments older than X days to 0 replicas
    - Optionally deletes deployments after Y days
    - Restores scaling for young deployments
    - Preserves original replica count in annotations
    - Supports deployment exclusion
    - Detailed logging and reporting

EOF
}

# Handle arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac
