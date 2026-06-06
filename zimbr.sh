#!/bin/bash

######################################################################
# Script Name      : zimbr
# Description      : Optimized backup and restore tool for Zimbra
# Author           : Muhammed Yalcinkaya (Original)
# Contributors     : Various optimizations and enhancements
# Email            : merhaba@muhyal.com
# 
# FEATURES:
#   - Secure backup and restore of Zimbra mail server data
#   - Support for domains, accounts, distribution lists, and mailboxes
#   - Comprehensive error handling and validation
#   - Detailed logging with multiple verbosity levels
#   - Progress tracking and performance metrics
#   - Robust handling of special characters and edge cases
######################################################################

set -euo pipefail  # Strict mode: exit on error, undefined vars, pipe failures

######################################################################
# CONSTANTS & CONFIGURATION
######################################################################

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"
readonly REQUIRED_USER="zimbra"
readonly DEFAULT_LOG_LEVEL="INFO"

# Color codes for output
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'  # No Color

# Backup directory subdirectories
readonly BACKUP_SUBDIRS=(
    "distribution_lists_members"
    "user_passwords"
    "user_data"
    "aliases"
)

# Performance tuning parameters
readonly BATCH_SIZE="${BATCH_SIZE:-50}"  # Process N items before progress update
readonly MIN_FREE_SPACE_MB="${MIN_FREE_SPACE_MB:-500}"  # Minimum free space required (MB)
readonly OPERATION_TIMEOUT="${OPERATION_TIMEOUT:-300}"  # Timeout for long operations (seconds)

# Mutable configuration
LOG_LEVEL="${LOG_LEVEL:-$DEFAULT_LOG_LEVEL}"

######################################################################
# LOGGING FUNCTIONS
######################################################################

log_info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$@" >&2
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$@" >&2
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$@" >&2
}

log_debug() {
    [[ "$LOG_LEVEL" == "DEBUG" ]] && printf "${BLUE}[DEBUG]${NC} %s\n" "$@" >&2 || true
}

log_progress() {
    if [[ "$LOG_LEVEL" != "ERROR" ]]; then
        printf "${CYAN}[PROGRESS]${NC} %s\n" "$@" >&2
    fi
}

######################################################################
# ERROR HANDLING & CLEANUP
######################################################################

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script failed with exit code $exit_code"
    fi
    # Clean up any temporary files
    [[ -n "${TEMP_FILE:-}" ]] && [[ -f "$TEMP_FILE" ]] && rm -f "$TEMP_FILE"
    return $exit_code
}

trap cleanup EXIT

######################################################################
# VALIDATION FUNCTIONS
######################################################################

validate_user() {
    if [[ "$(id -u -n)" != "$REQUIRED_USER" ]]; then
        log_error "Script must be run as '$REQUIRED_USER' user"
        exit 1
    fi
    log_debug "User validation passed: $(whoami)"
}

validate_directory() {
    local dir="$1"
    local check_type="${2:-exists}"  # exists, readable, writable

    # Expand path to catch relative paths and symlinks
    dir=$(cd "$dir" 2>/dev/null && pwd) || {
        log_error "Directory path is invalid or inaccessible: '$1'"
        return 1
    }

    if [[ ! -d "$dir" ]]; then
        log_error "Directory does not exist: '$dir'"
        return 1
    fi

    case "$check_type" in
        readable)
            if [[ ! -r "$dir" ]]; then
                log_error "Directory is not readable: '$dir'"
                return 1
            fi
            ;;
        writable)
            if [[ ! -w "$dir" ]]; then
                log_error "Directory is not writable: '$dir'"
                return 1
            fi
            # Check available disk space
            check_disk_space "$dir"
            ;;
    esac
    
    return 0
}

check_disk_space() {
    local dir="$1"
    local available_space=$(df "$dir" | awk 'NR==2 {print $4}')
    
    if [[ $available_space -lt $((MIN_FREE_SPACE_MB * 1024)) ]]; then
        log_warn "Low disk space: $(numfmt --to=iec-i --suffix=B $((available_space * 1024)) 2>/dev/null || echo "${available_space}KB") available"
    fi
    log_debug "Available disk space: $(numfmt --to=iec-i --suffix=B $((available_space * 1024)) 2>/dev/null || echo "${available_space}KB")"
}

validate_backup_dirs() {
    local base_dir="$1"
    local missing_dirs=()

    for subdir in "${BACKUP_SUBDIRS[@]}"; do
        if [[ ! -d "$base_dir/$subdir" ]]; then
            missing_dirs+=("$subdir")
        fi
    done

    if [[ ${#missing_dirs[@]} -gt 0 ]]; then
        log_error "Missing required directories: ${missing_dirs[*]}"
        return 1
    fi
    return 0
}

# Enhanced email validation with more robust regex
validate_email() {
    local email="$1"
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$ ]]; then
        log_warn "Invalid email format: '$email'"
        return 1
    fi
    return 0
}

# Enhanced domain validation
validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log_warn "Invalid domain format: '$domain'"
        return 1
    fi
    return 0
}

# Validate that string is safe for use in filenames
validate_filename() {
    local filename="$1"
    # Reject files with null bytes, slashes, or other problematic characters
    if [[ "$filename" =~ [/\\$'\0'] ]]; then
        return 1
    fi
    return 0
}

######################################################################
# PARAMETER PARSING
######################################################################

show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME -b <BACKUP_PATH> | -r <RESTORE_PATH> [OPTIONS]

OPTIONS:
    -b <path>      Backup path (must exist, must be writable by zimbra)
    -r <path>      Restore path (must exist, must be readable by zimbra)
    -h              Show this help message
    -v              Enable verbose output (DEBUG mode)

ENVIRONMENT VARIABLES:
    LOG_LEVEL            Set logging level (DEBUG, INFO, WARN, ERROR)
    BATCH_SIZE           Items per progress update (default: 50)
    MIN_FREE_SPACE_MB    Minimum free space required in MB (default: 500)
    OPERATION_TIMEOUT    Timeout for operations in seconds (default: 300)

EXAMPLES:
    # Backup Zimbra data
    $SCRIPT_NAME -b /backup/zimbra

    # Restore Zimbra data with verbose output
    $SCRIPT_NAME -r /backup/zimbra -v

    # Set custom batch size
    BATCH_SIZE=100 $SCRIPT_NAME -b /backup/zimbra

EOF
    exit "${1:-1}"
}

parse_arguments() {
    local action=""
    local backup_dir=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option -b requires an argument"
                    show_usage 1
                fi
                action="backup"
                backup_dir="${2%/}"  # Remove trailing slash
                shift 2
                ;;
            -r)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option -r requires an argument"
                    show_usage 1
                fi
                action="restore"
                backup_dir="${2%/}"
                shift 2
                ;;
            -v)
                LOG_LEVEL="DEBUG"
                shift
                ;;
            -h)
                show_usage 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage 1
                ;;
        esac
    done

    # Validate parsed arguments
    if [[ -z "$action" ]]; then
        log_error "Action not specified (-b for backup or -r for restore)"
        show_usage 1
    fi

    if [[ -z "$backup_dir" ]]; then
        log_error "Backup path not specified"
        show_usage 1
    fi

    echo "$action" "$backup_dir"
}

######################################################################
# DIRECTORY INITIALIZATION
######################################################################

init_backup_directories() {
    local base_dir="$1"
    
    log_info "Creating backup directory structure..."
    
    for subdir in "${BACKUP_SUBDIRS[@]}"; do
        local dir_path="$base_dir/$subdir"
        if [[ ! -d "$dir_path" ]]; then
            mkdir -p "$dir_path" || {
                log_error "Failed to create directory: $dir_path"
                return 1
            }
            log_debug "Created: $dir_path"
        fi
    done
    
    log_info "Backup directories initialized"
}

######################################################################
# BACKUP FUNCTIONS
######################################################################

backup_domains() {
    local backup_dir="$1"
    
    log_info "Exporting domains..."
    zmprov gad > "$backup_dir/domains.txt" 2>/dev/null || {
        log_error "Failed to export domains"
        return 1
    }
    local domain_count=$(wc -l < "$backup_dir/domains.txt" 2>/dev/null || echo 0)
    log_debug "Domains exported: $domain_count domains"
}

backup_admins() {
    local backup_dir="$1"
    
    log_info "Exporting admins..."
    zmprov gaaa > "$backup_dir/admins.txt" 2>/dev/null || {
        log_error "Failed to export admins"
        return 1
    }
    local admin_count=$(wc -l < "$backup_dir/admins.txt" 2>/dev/null || echo 0)
    log_debug "Admins exported: $admin_count admins"
}

backup_email_addresses() {
    local backup_dir="$1"
    
    log_info "Exporting email addresses..."
    zmprov -l gaa > "$backup_dir/emails.txt" 2>/dev/null || {
        log_error "Failed to export email addresses"
        return 1
    }
    local email_count=$(wc -l < "$backup_dir/emails.txt" 2>/dev/null || echo 0)
    log_debug "Emails exported: $email_count email(s)"
}

backup_distribution_lists() {
    local backup_dir="$1"
    
    log_info "Exporting distribution lists..."
    zmprov gadl > "$backup_dir/distribution_lists.txt" 2>/dev/null || {
        log_error "Failed to export distribution lists"
        return 1
    }
    
    log_info "Exporting distribution list members..."
    local dl_count=0
    local processed=0
    
    while IFS= read -r dl || [[ -n "$dl" ]]; do
        [[ -z "$dl" ]] && continue
        
        if ! validate_filename "$dl"; then
            log_warn "Skipping distribution list with invalid filename: $dl"
            continue
        fi
        
        zmprov gdlm "$dl" > "$backup_dir/distribution_lists_members/$dl.txt" 2>/dev/null || {
            log_warn "Failed to export members for distribution list: $dl"
            continue
        }
        ((dl_count++))
        ((processed++))
        
        if (( processed % BATCH_SIZE == 0 )); then
            log_progress "Processed $processed distribution lists..."
        fi
        log_debug "  -> $dl exported"
    done < "$backup_dir/distribution_lists.txt"
    
    log_info "Distribution lists exported: $dl_count list(s)"
}

backup_user_passwords() {
    local backup_dir="$1"
    local email_file="$backup_dir/emails.txt"
    
    log_info "Exporting user passwords..."
    local export_count=0
    local processed=0
    
    while IFS= read -r email || [[ -n "$email" ]]; do
        [[ -z "$email" ]] && continue
        
        if ! validate_email "$email"; then
            log_warn "Skipping invalid email: $email"
            continue
        fi
        
        if ! validate_filename "$email"; then
            log_warn "Skipping email with invalid filename characters: $email"
            continue
        fi
        
        # Use single command to reduce overhead
        local password=$(zmprov -l ga "$email" userPassword 2>/dev/null | grep -oP '(?<=userPassword: )\S+' | head -1)
        
        if [[ -n "$password" ]]; then
            echo "$password" > "$backup_dir/user_passwords/$email.shadow" || {
                log_warn "Failed to write password file for: $email"
                continue
            }
        else
            log_warn "No password found for: $email"
            continue
        fi
        
        ((export_count++))
        ((processed++))
        
        if (( processed % BATCH_SIZE == 0 )); then
            log_progress "Processed $processed user passwords..."
        fi
        log_debug "  -> $email exported"
    done < "$email_file"
    
    log_info "User passwords exported: $export_count email(s)"
}

backup_user_attributes() {
    local backup_dir="$1"
    local email_file="$backup_dir/emails.txt"
    
    log_info "Exporting user attributes (names, display names)..."
    local export_count=0
    local processed=0
    
    while IFS= read -r email || [[ -n "$email" ]]; do
        [[ -z "$email" ]] && continue
        
        if ! validate_email "$email"; then
            log_warn "Skipping invalid email: $email"
            continue
        fi
        
        if ! validate_filename "$email"; then
            log_warn "Skipping email with invalid filename characters: $email"
            continue
        fi
        
        zmprov ga "$email" 2>/dev/null | \
            grep -i 'name:' > "$backup_dir/user_data/$email.txt" || {
            log_warn "Failed to export attributes for: $email"
            continue
        }
        ((export_count++))
        ((processed++))
        
        if (( processed % BATCH_SIZE == 0 )); then
            log_progress "Processed $processed user attributes..."
        fi
        log_debug "  -> $email exported"
    done < "$email_file"
    
    log_info "User attributes exported: $export_count email(s)"
}

backup_aliases() {
    local backup_dir="$1"
    local email_file="$backup_dir/emails.txt"
    
    log_info "Exporting email aliases..."
    local export_count=0
    local processed=0
    
    while IFS= read -r email || [[ -n "$email" ]]; do
        [[ -z "$email" ]] && continue
        
        if ! validate_email "$email"; then
            log_warn "Skipping invalid email: $email"
            continue
        fi
        
        if ! validate_filename "$email"; then
            log_warn "Skipping email with invalid filename characters: $email"
            continue
        fi
        
        zmprov ga "$email" 2>/dev/null | \
            grep zimbraMailAlias | awk '{print $2}' > "$backup_dir/aliases/$email.txt" || {
            log_warn "Failed to export aliases for: $email"
            continue
        }
        ((export_count++))
        ((processed++))
        
        if (( processed % BATCH_SIZE == 0 )); then
            log_progress "Processed $processed alias records..."
        fi
        log_debug "  -> $email exported"
    done < "$email_file"
    
    # Remove empty alias files to save space
    find "$backup_dir/aliases/" -type f -empty -delete
    
    log_info "Email aliases exported: $export_count email(s)"
}

backup_mailboxes() {
    local backup_dir="$1"
    local email_file="$backup_dir/emails.txt"
    
    log_info "Exporting mailboxes (this may take a while)..."
    local export_count=0
    local failed_count=0
    local processed=0
    
    while IFS= read -r email || [[ -n "$email" ]]; do
        [[ -z "$email" ]] && continue
        
        if ! validate_email "$email"; then
            log_warn "Skipping invalid email: $email"
            ((failed_count++))
            continue
        fi
        
        if ! validate_filename "$email"; then
            log_warn "Skipping email with invalid filename characters: $email"
            ((failed_count++))
            continue
        fi
        
        if zmmailbox -z -m "$email" getRestURL '/?fmt=tgz' > "$backup_dir/$email.tgz" 2>/dev/null; then
            ((export_count++))
            local file_size=$(du -h "$backup_dir/$email.tgz" 2>/dev/null | cut -f1)
            log_debug "  -> $email exported ($file_size)"
        else
            log_warn "Failed to export mailbox: $email"
            ((failed_count++))
        fi
        
        ((processed++))
        if (( processed % BATCH_SIZE == 0 )); then
            log_progress "Processed $processed mailboxes ($export_count successful, $failed_count failed)..."
        fi
    done < "$email_file"
    
    log_info "Mailboxes exported: $export_count successful, $failed_count failed"
}

perform_backup() {
    local backup_dir="$1"
    
    log_info "======================================"
    log_info "ZIMBRA BACKUP PROCESS STARTED"
    log_info "Target: $backup_dir"
    log_info "======================================"
    
    local start_time=$(date +%s)
    
    # Initialize backup directory structure
    init_backup_directories "$backup_dir" || exit 1
    
    # Execute all backup tasks
    backup_domains "$backup_dir" || exit 1
    backup_admins "$backup_dir" || exit 1
    backup_email_addresses "$backup_dir" || exit 1
    backup_distribution_lists "$backup_dir" || exit 1
    backup_user_passwords "$backup_dir" || exit 1
    backup_user_attributes "$backup_dir" || exit 1
    backup_aliases "$backup_dir" || exit 1
    backup_mailboxes "$backup_dir" || exit 1
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
    
    log_info "======================================"
    log_info "ZIMBRA BACKUP COMPLETED SUCCESSFULLY"
    log_info "Duration: ${duration}s"
    log_info "Backup size: $backup_size"
    log_info "======================================"
}

######################################################################
# RESTORE FUNCTIONS
######################################################################

restore_domains() {
    local backup_dir="$1"
    
    log_info "Restoring domains..."
    local restore_count=0
    
    while IFS= read -r domain || [[ -n "$domain" ]]; do
        [[ -z "$domain" ]] && continue
        
        if ! validate_domain "$domain"; then
            log_warn "Skipping invalid domain: $domain"
            continue
        fi
        
        if zmprov cd "$domain" zimbraAuthMech zimbra 2>/dev/null; then
            ((restore_count++))
            log_debug "  -> $domain added"
        else
            log_warn "Failed to restore domain: $domain"
        fi
    done < "$backup_dir/domains.txt"
    
    log_info "Domains restored: $restore_count domain(s)"
}

restore_email_accounts() {
    local backup_dir="$1"
    
    log_info "Restoring email accounts and passwords..."
    local restore_count=0
    local failed_count=0
    local processed=0
    
    while IFS= read -r email || [[ -n "$email" ]]; do
        [[ -z "$email" ]] && continue
        
        if ! validate_email "$email"; then
            log_warn "Skipping invalid email: $email"
            ((failed_count++))
            continue
        fi
        
        local data_file="$backup_dir/user_data/$email.txt"
        local password_file="$backup_dir/user_passwords/$email.shadow"
        
        if [[ ! -f "$data_file" ]] || [[ ! -f "$password_file" ]]; then
            log_warn "Missing backup data for: $email"
            ((failed_count++))
            continue
        fi
        
        # Extract user attributes more efficiently
        local given_name=$(grep -oP 'givenName: \K.*' "$data_file" | head -1 | xargs)
        local display_name=$(grep -oP 'displayName: \K.*' "$data_file" | head -1 | xargs)
        local shadow_pass=$(cat "$password_file")
        local tmp_pass="changeme"
        
        # Create account with temporary password
        if zmprov ca "$email" "$tmp_pass" \
            cn "${given_name:-$email}" \
            displayName "${display_name:-$email}" \
            givenName "${given_name:-$email}" 2>/dev/null; then
            
            # Set actual password
            zmprov ma "$email" userPassword "$shadow_pass" 2>/dev/null || {
                log_warn "Failed to set password for: $email"
            }
            
            ((restore_count++))
            log_debug "  -> $email restored"
        else
            log_warn "Failed to restore account: $email"
            ((failed_count++))
        fi
        
        ((processed++))
        if (( processed % BATCH_SIZE == 0 )); then
            log_progress "Processed $processed accounts ($restore_count successful)..."
        fi
    done < "$backup_dir/emails.txt"
    
    log_info "Email accounts restored: $restore_count successful, $failed_count failed"
}

restore_mailboxes() {
    local backup_dir="$1"
    
    log_info "Restoring mailboxes..."
    local restore_count=0
    local failed_count=0
    local processed=0
    
    while IFS= read -r email || [[ -n "$email" ]]; do
        [[ -z "$email" ]] && continue
        
        if ! validate_email "$email"; then
            log_warn "Skipping invalid email: $email"
            continue
        fi
        
        local mailbox_file="$backup_dir/$email.tgz"
        
        if [[ ! -f "$mailbox_file" ]]; then
            log_warn "Mailbox file not found for: $email"
            ((failed_count++))
            continue
        fi
        
        if zmmailbox -z -m "$email" postRestURL "/?fmt=tgz&resolve=skip" "$mailbox_file" 2>/dev/null; then
            ((restore_count++))
            log_debug "  -> $email restored"
        else
            log_warn "Failed to restore mailbox: $email"
            ((failed_count++))
        fi
        
        ((processed++))
        if (( processed % BATCH_SIZE == 0 )); then
            log_progress "Processed $processed mailboxes ($restore_count successful)..."
        fi
    done < "$backup_dir/emails.txt"
    
    log_info "Mailboxes restored: $restore_count successful, $failed_count failed"
}

restore_distribution_lists() {
    local backup_dir="$1"
    
    log_info "Restoring distribution lists..."
    local restore_count=0
    
    while IFS= read -r dl || [[ -n "$dl" ]]; do
        [[ -z "$dl" ]] && continue
        
        if zmprov cdl "$dl" 2>/dev/null; then
            ((restore_count++))
            log_debug "  -> $dl created"
        else
            log_warn "Failed to create distribution list: $dl"
        fi
    done < "$backup_dir/distribution_lists.txt"
    
    log_info "Distribution lists created: $restore_count list(s)"
}

restore_distribution_list_members() {
    local backup_dir="$1"
    
    log_info "Restoring distribution list members..."
    local member_count=0
    local failed_count=0
    
    while IFS= read -r dl || [[ -n "$dl" ]]; do
        [[ -z "$dl" ]] && continue
        
        local members_file="$backup_dir/distribution_lists_members/$dl.txt"
        
        if [[ ! -f "$members_file" ]]; then
            log_warn "Members file not found for: $dl"
            continue
        fi
        
        while IFS= read -r member || [[ -n "$member" ]]; do
            [[ -z "$member" ]] && continue
            [[ "$member" =~ ^# ]] && continue  # Skip comments
            
            if ! validate_email "$member"; then
                log_warn "Invalid member email: $member"
                ((failed_count++))
                continue
            fi
            
            if zmprov adlm "$dl" "$member" 2>/dev/null; then
                ((member_count++))
                log_debug "  -> $member added to $dl"
            else
                log_warn "Failed to add member $member to list $dl"
                ((failed_count++))
            fi
        done < "$members_file"
    done < "$backup_dir/distribution_lists.txt"
    
    log_info "Distribution list members restored: $member_count successful, $failed_count failed"
}

restore_aliases() {
    local backup_dir="$1"
    
    log_info "Restoring email aliases..."
    local alias_count=0
    local failed_count=0
    
    while IFS= read -r email || [[ -n "$email" ]]; do
        [[ -z "$email" ]] && continue
        
        if ! validate_email "$email"; then
            log_warn "Skipping invalid email: $email"
            continue
        fi
        
        local aliases_file="$backup_dir/aliases/$email.txt"
        
        if [[ ! -f "$aliases_file" ]]; then
            log_debug "No aliases found for: $email"
            continue
        fi
        
        while IFS= read -r alias || [[ -n "$alias" ]]; do
            [[ -z "$alias" ]] && continue
            
            if ! validate_email "$alias"; then
                log_warn "Invalid alias format: $alias"
                ((failed_count++))
                continue
            fi
            
            if zmprov aaa "$email" "$alias" 2>/dev/null; then
                ((alias_count++))
                log_debug "  -> $alias added for $email"
            else
                log_warn "Failed to add alias $alias for $email"
                ((failed_count++))
            fi
        done < "$aliases_file"
    done < "$backup_dir/emails.txt"
    
    log_info "Email aliases restored: $alias_count successful, $failed_count failed"
}

perform_restore() {
    local backup_dir="$1"
    
    log_info "======================================"
    log_info "ZIMBRA RESTORE PROCESS STARTED"
    log_info "Source: $backup_dir"
    log_info "======================================"
    
    local start_time=$(date +%s)
    
    # Validate restore directory structure
    validate_backup_dirs "$backup_dir" || exit 1
    
    # Execute all restore tasks
    restore_domains "$backup_dir" || exit 1
    restore_email_accounts "$backup_dir" || exit 1
    restore_mailboxes "$backup_dir" || exit 1
    restore_distribution_lists "$backup_dir" || exit 1
    restore_distribution_list_members "$backup_dir" || exit 1
    restore_aliases "$backup_dir" || exit 1
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_info "======================================"
    log_info "ZIMBRA RESTORE COMPLETED SUCCESSFULLY"
    log_info "Duration: ${duration}s"
    log_info "======================================"
}

######################################################################
# MAIN EXECUTION
######################################################################

main() {
    # Validate execution environment
    validate_user
    
    # Parse arguments
    local result
    result=$(parse_arguments "$@") || exit 1
    
    local action=$(echo "$result" | head -1)
    local backup_dir=$(echo "$result" | tail -1)
    
    log_debug "Action: $action, Path: $backup_dir"
    
    # Validate backup directory
    case "$action" in
        backup)
            validate_directory "$backup_dir" "writable" || exit 1
            perform_backup "$backup_dir"
            ;;
        restore)
            validate_directory "$backup_dir" "readable" || exit 1
            perform_restore "$backup_dir"
            ;;
        *)
            log_error "Unknown action: $action"
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"
