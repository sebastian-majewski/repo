#!/bin/bash

# OpenShift script for cleaning up Services and Routes without associated pods
# Takes into account special cases for deployments scaled to 0

set -e

# Configuration
PROJECT="${1:-$(oc project -q 2>/dev/null || echo "default")}"
DRY_RUN="${DRY_RUN:-true}"
DEPLOYMENT_SCALE_GRACE_PERIOD=48  # hours
DEPLOYMENT_DELETE_PERIOD=336      # hours (2 weeks)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Function to check if deployment is in grace period
is_deployment_in_grace_period() {
    local deployment_name=$1
    local project=$2
    
    # Get deployment creation timestamp
    local creation_timestamp=$(oc get deployment "$deployment_name" -n "$project" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "")
    
    if [ -z "$creation_timestamp" ]; then
        return 1  # Deployment doesn't exist
    fi
    
    # Convert timestamp to seconds
    local creation_seconds=$(date -d "$creation_timestamp" +%s 2>/dev/null || echo "0")
    local current_seconds=$(date +%s)
    local age_hours=$(( (current_seconds - creation_seconds) / 3600 ))
    
    # Check if deployment is in grace period (48h - 2 weeks)
    if [ $age_hours -ge $DEPLOYMENT_SCALE_GRACE_PERIOD ] && [ $age_hours -lt $DEPLOYMENT_DELETE_PERIOD ]; then
        local replicas=$(oc get deployment "$deployment_name" -n "$project" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        if [ "$replicas" = "0" ]; then
            log "Deployment $deployment_name is in grace period (age: ${age_hours}h, replicas: $replicas)"
            return 0  # Is in grace period
        fi
    fi
    
    return 1  # Not in grace period
}

# Function to check if service has associated pods
has_associated_pods() {
    local service_name=$1
    local project=$2
    local resource_type=$3
    
    if [ "$resource_type" = "service" ]; then
        # Get selector from service
        local selector=$(oc get service "$service_name" -n "$project" -o jsonpath='{.spec.selector}' 2>/dev/null)
        
        if [ "$selector" = "{}" ] || [ -z "$selector" ]; then
            log "Service $service_name has no selector"
            return 1  # No selector = no pods
        fi
        
        # Convert selector to oc format
        local selector_string=$(echo "$selector" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
        
        if [ -z "$selector_string" ] || [ "$selector_string" = "null" ]; then
            log "Service $service_name has empty selector"
            return 1
        fi
        
        # Check if pods exist with this selector
        local pods=$(oc get pods -n "$project" -l "$selector_string" --field-selector=status.phase!=Failed,status.phase!=Succeeded -o name 2>/dev/null || echo "")
        
        if [ -z "$pods" ]; then
            # Check if it might be a deployment in grace period
            local app_label=$(echo "$selector" | jq -r '.app // .name // ."app.kubernetes.io/name" // ."deploymentconfig" // empty' 2>/dev/null)
            if [ -n "$app_label" ] && is_deployment_in_grace_period "$app_label" "$project"; then
                log "Service $service_name is associated with deployment/deploymentconfig in grace period"
                return 0  # Has associated resources (deployment in grace)
            fi
            return 1  # No pods
        fi
    elif [ "$resource_type" = "route" ]; then
        # For OpenShift Routes - check service
        local target_service=$(oc get route "$service_name" -n "$project" -o jsonpath='{.spec.to.name}' 2>/dev/null)
        
        if [ -z "$target_service" ]; then
            log "Route $service_name has no target service"
            return 1
        fi
        
        # Recursively check if target service has pods
        has_associated_pods "$target_service" "$project" "service"
        return $?
    fi
    
    return 0  # Has associated pods
}

# Function to delete resource
delete_resource() {
    local resource_type=$1
    local resource_name=$2
    local project=$3
    
    if [ "$DRY_RUN" = "true" ]; then
        warn "[DRY RUN] Would delete $resource_type: $resource_name in project: $project"
    else
        log "Deleting $resource_type: $resource_name in project: $project"
        if oc delete "$resource_type" "$resource_name" -n "$project"; then
            success "Deleted $resource_type: $resource_name"
        else
            error "Failed to delete $resource_type: $resource_name"
        fi
    fi
}

# Main cleanup function
cleanup_resources() {
    local project=$1
    local resource_type=$2
    local resource_plural=$3
    
    log "Checking $resource_plural in project: $project"
    
    # Get all resources of the given type
    local resources=$(oc get "$resource_plural" -n "$project" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$resources" ]; then
        log "No $resource_plural found in project $project"
        return
    fi
    
    local to_delete=()
    
    for resource in $resources; do
        log "Checking $resource_type: $resource"
        
        if ! has_associated_pods "$resource" "$project" "$resource_type"; then
            log "$resource_type $resource has no associated pods"
            to_delete+=("$resource")
        else
            log "$resource_type $resource has associated pods or is in grace period"
        fi
    done
    
    # Delete resources without pods
    if [ ${#to_delete[@]} -gt 0 ]; then
        log "Found ${#to_delete[@]} $resource_plural to delete"
        for resource in "${to_delete[@]}"; do
            delete_resource "$resource_type" "$resource" "$project"
        done
    else
        success "All $resource_plural have associated pods or are in grace period"
    fi
}

# Main function
main() {
    log "Starting OpenShift resource cleanup"
    log "Project: $PROJECT"
    log "DRY RUN: $DRY_RUN"
    log "Grace period for deployments: $DEPLOYMENT_SCALE_GRACE_PERIOD-$DEPLOYMENT_DELETE_PERIOD hours"
    
    # Check if project exists
    if ! oc get project "$PROJECT" &>/dev/null; then
        error "Project $PROJECT does not exist"
        exit 1
    fi
    
    # Check if oc is available
    if ! command -v oc &> /dev/null; then
        error "oc CLI is not installed or unavailable"
        exit 1
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        error "jq is not installed - required for JSON parsing"
        exit 1
    fi
    
    # Switch to the project if not already in it
    local current_project=$(oc project -q 2>/dev/null || echo "")
    if [ "$current_project" != "$PROJECT" ]; then
        log "Switching to project: $PROJECT"
        oc project "$PROJECT" &>/dev/null
    fi
    
    echo
    log "=== CLEANING UP SERVICES ==="
    cleanup_resources "$PROJECT" "service" "services"
    
    echo
    log "=== CLEANING UP ROUTES ==="
    cleanup_resources "$PROJECT" "route" "routes"
    
    echo
    success "Cleanup completed"
    
    if [ "$DRY_RUN" = "true" ]; then
        warn "This was a DRY RUN. To perform actual deletion, run:"
        warn "DRY_RUN=false $0 $PROJECT"
    fi
}

# Check arguments
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Usage: $0 [PROJECT]"
    echo ""
    echo "Environment variables:"
    echo "  DRY_RUN=true|false  - Whether to perform dry run (default: true)"
    echo ""
    echo "Examples:"
    echo "  $0                           # Dry run in current project"
    echo "  $0 my-project                # Dry run in 'my-project' project"
    echo "  DRY_RUN=false $0 production  # Actual deletion in 'production' project"
    echo ""
    echo "Note: If no project is specified, uses current project or 'default'"
    exit 0
fi

# Run main function
main
