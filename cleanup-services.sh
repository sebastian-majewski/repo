# Function to extract app label from selector without jq
get_app_label() {
    local selector=$1
    
    # Try different common app label patterns
    # Look for "app":"value" or "name":"value" or "app.kubernetes.io/name":"value"
    local app_value=""
    
    # Try app first
    app_value=$(echo "$selector" | sed -n 's/.*"app" *: *"\([^"]*\)".*/\1/p')
    if [ -n "$app_value" ]; then
        echo "$app_value"
        return
    fi
    
    # Try name
    app_value=$(echo "$selector" | sed -n 's/.*"name" *: *"\([^"]*\)".*/\1/p')
    if [ -n "$app_value" ]; then
        echo "$app_value"
        return
    fi
    
    # Try app.kubernetes.io/name
    app_value=$(echo "$selector" | sed -n 's/.*"app\.kubernetes\.io\/name" *: *"\([^"]*\)".*/\1/p')
    if [ -n "$app_value" ]; then
        echo "$app_value"
        return
    fi
    
    # Return empty if not found
    echo ""
}#!/bin/bash

# OpenShift cleanup script for CronJob - operates on current project only
# Automatically cleans up Services and Routes without associated pods
# Takes into account special cases for deployments scaled to 0

set -e

# Configuration
DRY_RUN="${DRY_RUN:-false}"  # Default to actual deletion for cronjob
DEPLOYMENT_SCALE_GRACE_PERIOD=48  # hours
DEPLOYMENT_DELETE_PERIOD=336      # hours (2 weeks)
LOG_LEVEL="${LOG_LEVEL:-INFO}"    # DEBUG, INFO, WARN, ERROR

# Colors for output (disabled in cronjob mode)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Logging functions with levels
debug() {
    [ "$LOG_LEVEL" = "DEBUG" ] && echo -e "${BLUE}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

log() {
    [ "$LOG_LEVEL" != "ERROR" ] && echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

warn() {
    [ "$LOG_LEVEL" != "ERROR" ] && echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

success() {
    [ "$LOG_LEVEL" != "ERROR" ] && echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Function to get current project
get_current_project() {
    oc project -q 2>/dev/null || echo ""
}

# Function to check if deployment is in grace period
is_deployment_in_grace_period() {
    local deployment_name=$1
    local project=$2
    
    debug "Checking grace period for deployment: $deployment_name"
    
    # Get deployment creation timestamp
    local creation_timestamp=$(oc get deployment "$deployment_name" -n "$project" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "")
    
    if [ -z "$creation_timestamp" ]; then
        debug "Deployment not found: $deployment_name"
        return 1  # Deployment doesn't exist
    fi
    
    # Convert timestamp to seconds
    local creation_seconds=$(date -d "$creation_timestamp" +%s 2>/dev/null || echo "0")
    local current_seconds=$(date +%s)
    local age_hours=$(( (current_seconds - creation_seconds) / 3600 ))
    
    debug "Deployment $deployment_name age: ${age_hours}h, grace period: ${DEPLOYMENT_SCALE_GRACE_PERIOD}-${DEPLOYMENT_DELETE_PERIOD}h"
    
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
    
    debug "Checking pods for $resource_type: $service_name"
    
    if [ "$resource_type" = "service" ]; then
        # Get selector from service
        local selector=$(oc get service "$service_name" -n "$project" -o jsonpath='{.spec.selector}' 2>/dev/null)
        
        if [ "$selector" = "{}" ] || [ -z "$selector" ]; then
            debug "Service $service_name has no selector"
            return 1  # No selector = no pods
        fi
        
        # Convert selector to oc format without jq
        # Parse JSON manually: {"key1":"value1","key2":"value2"} -> key1=value1,key2=value2
        local selector_string=$(echo "$selector" | sed 's/[{"}]//g' | sed 's/:/=/g' | sed 's/,/,/g')
        
        if [ -z "$selector_string" ] || [ "$selector_string" = "null" ]; then
            debug "Service $service_name has empty selector"
            return 1
        fi
        
        debug "Service $service_name selector: $selector_string"
        
        # Check if pods exist with this selector
        local pods=$(oc get pods -n "$project" -l "$selector_string" --field-selector=status.phase!=Failed,status.phase!=Succeeded -o name 2>/dev/null || echo "")
        
        if [ -z "$pods" ]; then
            debug "No active pods found for selector: $selector_string"
            # Check if it might be a deployment in grace period
            local app_label=$(get_app_label "$selector")
            if [ -n "$app_label" ] && is_deployment_in_grace_period "$app_label" "$project"; then
                log "Service $service_name is associated with deployment in grace period"
                return 0  # Has associated resources (deployment in grace)
            fi
            return 1  # No pods
        else
            debug "Found active pods: $pods"
        fi
    elif [ "$resource_type" = "route" ]; then
        # For OpenShift Routes - check service
        local target_service=$(oc get route "$service_name" -n "$project" -o jsonpath='{.spec.to.name}' 2>/dev/null)
        
        if [ -z "$target_service" ]; then
            debug "Route $service_name has no target service"
            return 1
        fi
        
        debug "Route $service_name targets service: $target_service"
        
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
        if oc delete "$resource_type" "$resource_name" -n "$project" --ignore-not-found=true; then
            success "Deleted $resource_type: $resource_name"
        else
            error "Failed to delete $resource_type: $resource_name"
            return 1
        fi
    fi
    return 0
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
        return 0
    fi
    
    local to_delete=()
    local checked_count=0
    
    for resource in $resources; do
        checked_count=$((checked_count + 1))
        debug "Checking $resource_type: $resource ($checked_count)"
        
        if ! has_associated_pods "$resource" "$project" "$resource_type"; then
            log "$resource_type $resource has no associated pods - marking for deletion"
            to_delete+=("$resource")
        else
            debug "$resource_type $resource has associated pods or is in grace period"
        fi
    done
    
    # Delete resources without pods
    local deleted_count=0
    local failed_count=0
    
    if [ ${#to_delete[@]} -gt 0 ]; then
        log "Found ${#to_delete[@]} $resource_plural to delete out of $checked_count checked"
        for resource in "${to_delete[@]}"; do
            if delete_resource "$resource_type" "$resource" "$project"; then
                deleted_count=$((deleted_count + 1))
            else
                failed_count=$((failed_count + 1))
            fi
        done
        
        if [ $failed_count -eq 0 ]; then
            success "Successfully deleted $deleted_count $resource_plural"
        else
            warn "Deleted $deleted_count $resource_plural, failed to delete $failed_count"
        fi
    else
        success "All $checked_count $resource_plural have associated pods or are in grace period"
    fi
    
    return $failed_count
}

# Health check function
health_check() {
    local errors=0
    
    # Check if oc is available
    if ! command -v oc &> /dev/null; then
        error "oc CLI is not installed or unavailable"
        errors=$((errors + 1))
    fi
    
    # Check if we can connect to OpenShift
    if ! oc auth can-i get pods &>/dev/null; then
        error "Cannot authenticate with OpenShift or insufficient permissions"
        errors=$((errors + 1))
    fi
    
    return $errors
}

# Main function
main() {
    local start_time=$(date +%s)
    local current_project=$(get_current_project)
    
    if [ -z "$current_project" ]; then
        error "Cannot determine current project"
        exit 1
    fi
    
    log "=== OpenShift Cleanup Job Started ==="
    log "Project: $current_project"
    log "DRY RUN: $DRY_RUN"
    log "Grace period: $DEPLOYMENT_SCALE_GRACE_PERIOD-$DEPLOYMENT_DELETE_PERIOD hours"
    
    # Perform health check
    if ! health_check; then
        error "Health check failed - aborting cleanup"
        exit 1
    fi
    
    local total_errors=0
    
    # Cleanup services
    log "=== CLEANING UP SERVICES ==="
    if ! cleanup_resources "$current_project" "service" "services"; then
        total_errors=$((total_errors + $?))
    fi
    
    echo
    # Cleanup routes
    log "=== CLEANING UP ROUTES ==="
    if ! cleanup_resources "$current_project" "route" "routes"; then
        total_errors=$((total_errors + $?))
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo
    if [ $total_errors -eq 0 ]; then
        success "=== Cleanup completed successfully in ${duration}s ==="
    else
        warn "=== Cleanup completed with $total_errors errors in ${duration}s ==="
    fi
    
    # Exit with non-zero if there were errors
    exit $total_errors
}

# Handle script arguments
case "${1:-}" in
    -h|--help)
        echo "OpenShift Cleanup Script for CronJob"
        echo ""
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "This script operates on the current project only and is designed"
        echo "to run as a CronJob within an OpenShift project."
        echo ""
        echo "Dependencies: oc CLI (jq not required)"
        echo ""
        echo "Environment variables:"
        echo "  DRY_RUN=true|false     - Perform dry run (default: false)"
        echo "  LOG_LEVEL=DEBUG|INFO|WARN|ERROR - Log level (default: INFO)"
        echo ""
        echo "Options:"
        echo "  -h, --help            - Show this help"
        echo "  --health-check        - Perform health check only"
        echo "  --dry-run             - Force dry run mode"
        echo ""
        echo "Examples:"
        echo "  $0                    # Run cleanup in current project"
        echo "  $0 --dry-run          # Dry run in current project"
        echo "  LOG_LEVEL=DEBUG $0    # Run with debug logging"
        exit 0
        ;;
    --health-check)
        log "Performing health check..."
        if health_check; then
            success "Health check passed"
            exit 0
        else
            error "Health check failed"
            exit 1
        fi
        ;;
    --dry-run)
        export DRY_RUN=true
        ;;
    "")
        # No arguments - continue to main
        ;;
    *)
        error "Unknown argument: ${1:-}"
        echo "Use --help for usage information"
        exit 1
        ;;
esac

# Run main function
main
