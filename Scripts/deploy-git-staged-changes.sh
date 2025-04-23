#!/bin/bash

# Script to deploy staged changes from Cursor to a connected Salesforce org
# Last modified: 2025-04-23

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables
DEPLOY_TIMEOUT=10
RUN_TESTS="NoTestRun"
TARGET_ORG=""
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$SCRIPT_DIR"
TEMP_DIR="$PROJECT_ROOT/cursor_deploy_$(date +%Y%m%d%H%M%S)"

echo -e "${BLUE}=== Salesforce Deployment Script ===${NC}"
echo -e "${BLUE}Date:${NC} $(date)"
echo -e "${BLUE}Project Root:${NC} $PROJECT_ROOT"

# Function to get the default org
function get_default_org {
    local default_org=$(sf config get target-org --json 2>/dev/null | grep -o '"value": "[^"]*"' | cut -d'"' -f4)
    
    if [ -z "$default_org" ]; then
        local org_list=$(sf org list --json 2>/dev/null)
        if [ $? -eq 0 ]; then
            default_org=$(echo "$org_list" | grep -o '"defaultMarker": "O"' -B5 -A5 | grep -o '"username": "[^"]*"' | head -1 | cut -d'"' -f4)
            
            if [ -z "$default_org" ]; then
                default_org=$(echo "$org_list" | grep -o '"defaultMarker": "O"' -B5 -A5 | grep -o '"alias": "[^"]*"' | head -1 | cut -d'"' -f4)
            fi
        fi
    fi
    
    echo "$default_org"
}

# Get the target org
TARGET_ORG=$(get_default_org)

if [ -z "$TARGET_ORG" ]; then
    echo -e "${YELLOW}No default org found. Listing available orgs:${NC}"
    sf org list
    echo ""
    echo -e "${YELLOW}Enter the alias or username of the org you want to deploy to:${NC}"
    read TARGET_ORG
    
    if [ -z "$TARGET_ORG" ]; then
        echo -e "${RED}No org selected. Exiting.${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}Using org:${NC} $TARGET_ORG"

# Verify connection to the org
echo -e "\n${GREEN}Checking connection to org...${NC}"
if ! sf org display --target-org "$TARGET_ORG" &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to the specified org: $TARGET_ORG${NC}"
    echo "Please authenticate first using: sf org login web --alias $TARGET_ORG"
    exit 1
fi
echo -e "${GREEN}Successfully connected to org: $TARGET_ORG${NC}"

# Create temporary directory for deployment
mkdir -p "$TEMP_DIR"

# Check if git is available
if ! command -v git &> /dev/null; then
    echo -e "${RED}Error: Git is not installed or not in PATH${NC}"
    echo "This script assumes Cursor uses git for staging changes."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Get ONLY staged changes from git
echo -e "\n${GREEN}Gathering staged changes...${NC}"
STAGED_FILES=$(git diff --name-only --cached)

if [ -z "$STAGED_FILES" ]; then
    echo -e "${YELLOW}No staged files found. Would you like to:"
    echo -e "1) Stage all modified files and deploy them"
    echo -e "2) Deploy a specific file or directory"
    echo -e "3) Cancel deployment${NC}"
    read -p "Enter your choice (1, 2, or 3): " stage_choice
    
    if [ "$stage_choice" = "1" ]; then
        echo -e "${GREEN}Staging all modified files...${NC}"
        git add -A
        STAGED_FILES=$(git diff --name-only --cached)
        
        if [ -z "$STAGED_FILES" ]; then
            echo -e "${RED}No modified files found to stage. Nothing to deploy.${NC}"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
    elif [ "$stage_choice" = "2" ]; then
        echo -e "${YELLOW}Enter the path to the file or directory you want to deploy:${NC}"
        read specific_path
        
        if [ -z "$specific_path" ] || [ ! -e "$specific_path" ]; then
            echo -e "${RED}Invalid path. Exiting.${NC}"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        
        # For specific path deployment, we'll handle it differently
        if [ -d "$specific_path" ]; then
            echo -e "${GREEN}Deploying directory: $specific_path${NC}"
            
            # Use direct deployment for directories
            echo -e "\n${GREEN}Deploying directory to $TARGET_ORG...${NC}"
            DEPLOY_COMMAND="sf project deploy start -d \"$specific_path\" --target-org \"$TARGET_ORG\" --wait $DEPLOY_TIMEOUT"
            
            echo "Executing: $DEPLOY_COMMAND"
            eval "$DEPLOY_COMMAND"
            DEPLOY_RESULT=$?
            
            if [ $DEPLOY_RESULT -eq 0 ]; then
                echo -e "\n${GREEN}Deployment completed successfully!${NC}"
            else
                echo -e "\n${RED}Deployment failed with errors.${NC}"
            fi
            
            # Clean up and exit
            rm -rf "$TEMP_DIR"
            exit $DEPLOY_RESULT
        else
            echo -e "${GREEN}Deploying file: $specific_path${NC}"
            
            # For single file, add it to our staged files
            STAGED_FILES="$specific_path"
        fi
    else
        echo -e "${YELLOW}Deployment cancelled. Please stage files using 'git add' before deploying.${NC}"
        rm -rf "$TEMP_DIR"
        exit 0
    fi
fi

echo -e "\n${GREEN}Files to be deployed:${NC}"
echo "$STAGED_FILES"

# Create a proper SFDX project structure
mkdir -p "$TEMP_DIR/force-app/main/default"

# Create sfdx-project.json
echo '{
  "packageDirectories": [
    {
      "path": "force-app",
      "default": true
    }
  ],
  "namespace": "",
  "sfdcLoginUrl": "https://login.salesforce.com",
  "sourceApiVersion": "58.0"
}' > "$TEMP_DIR/sfdx-project.json"

# Copy staged files to the deployment directory with proper structure
COPIED_FILES=0

for file in $STAGED_FILES; do
    if [ -f "$file" ]; then
        # Determine the metadata type and destination directory
        if [[ "$file" == *".cls" ]]; then
            # Apex class
            mkdir -p "$TEMP_DIR/force-app/main/default/classes"
            cp "$file" "$TEMP_DIR/force-app/main/default/classes/"
            # Check for meta file
            if [ -f "${file}-meta.xml" ]; then
                cp "${file}-meta.xml" "$TEMP_DIR/force-app/main/default/classes/"
            fi
            echo "Added Apex class: $file"
            COPIED_FILES=$((COPIED_FILES+1))
            
        elif [[ "$file" == *".trigger" ]]; then
            # Apex trigger
            mkdir -p "$TEMP_DIR/force-app/main/default/triggers"
            cp "$file" "$TEMP_DIR/force-app/main/default/triggers/"
            # Check for meta file
            if [ -f "${file}-meta.xml" ]; then
                cp "${file}-meta.xml" "$TEMP_DIR/force-app/main/default/triggers/"
            fi
            echo "Added Apex trigger: $file"
            COPIED_FILES=$((COPIED_FILES+1))
            
        elif [[ "$file" == *"/lwc/"* ]]; then
            # LWC component
            component_dir=$(dirname "$file")
            component_name=$(basename "$component_dir")
            mkdir -p "$TEMP_DIR/force-app/main/default/lwc/$component_name"
            cp "$file" "$TEMP_DIR/force-app/main/default/lwc/$component_name/"
            echo "Added LWC file: $file"
            COPIED_FILES=$((COPIED_FILES+1))
            
        elif [[ "$file" == *"/aura/"* ]]; then
            # Aura component
            component_dir=$(dirname "$file")
            component_name=$(basename "$component_dir")
            mkdir -p "$TEMP_DIR/force-app/main/default/aura/$component_name"
            cp "$file" "$TEMP_DIR/force-app/main/default/aura/$component_name/"
            echo "Added Aura file: $file"
            COPIED_FILES=$((COPIED_FILES+1))
            
        elif [[ "$file" == *".page" ]]; then
            # Visualforce page
            mkdir -p "$TEMP_DIR/force-app/main/default/pages"
            cp "$file" "$TEMP_DIR/force-app/main/default/pages/"
            # Check for meta file
            if [ -f "${file}-meta.xml" ]; then
                cp "${file}-meta.xml" "$TEMP_DIR/force-app/main/default/pages/"
            fi
            echo "Added Visualforce page: $file"
            COPIED_FILES=$((COPIED_FILES+1))
            
        elif [[ "$file" == *".component" ]]; then
            # Visualforce component
            mkdir -p "$TEMP_DIR/force-app/main/default/components"
            cp "$file" "$TEMP_DIR/force-app/main/default/components/"
            # Check for meta file
            if [ -f "${file}-meta.xml" ]; then
                cp "${file}-meta.xml" "$TEMP_DIR/force-app/main/default/components/"
            fi
            echo "Added Visualforce component: $file"
            COPIED_FILES=$((COPIED_FILES+1))
            
        elif [[ "$file" == *".object" || "$file" == *".object-meta.xml" ]]; then
            # Custom object
            mkdir -p "$TEMP_DIR/force-app/main/default/objects"
            cp "$file" "$TEMP_DIR/force-app/main/default/objects/"
            echo "Added Custom object: $file"
            COPIED_FILES=$((COPIED_FILES+1))
            
        elif [[ "$file" == *".layout" || "$file" == *".layout-meta.xml" ]]; then
            # Page layout
            mkdir -p "$TEMP_DIR/force-app/main/default/layouts"
            cp "$file" "$TEMP_DIR/force-app/main/default/layouts/"
            echo "Added Page layout: $file"
            COPIED_FILES=$((COPIED_FILES+1))
            
        elif [[ "$file" == *".permissionset" || "$file" == *".permissionset-meta.xml" ]]; then
            # Permission set
            mkdir -p "$TEMP_DIR/force-app/main/default/permissionsets"
            cp "$file" "$TEMP_DIR/force-app/main/default/permissionsets/"
            echo "Added Permission set: $file"
            COPIED_FILES=$((COPIED_FILES+1))
            
        elif [[ "$file" == *".profile" || "$file" == *".profile-meta.xml" ]]; then
            # Profile
            mkdir -p "$TEMP_DIR/force-app/main/default/profiles"
            cp "$file" "$TEMP_DIR/force-app/main/default/profiles/"
            echo "Added Profile: $file"
            COPIED_FILES=$((COPIED_FILES+1))
            
        elif [[ "$file" == *".flow" || "$file" == *".flow-meta.xml" ]]; then
            # Flow
            mkdir -p "$TEMP_DIR/force-app/main/default/flows"
            cp "$file" "$TEMP_DIR/force-app/main/default/flows/"
            echo "Added Flow: $file"
            COPIED_FILES=$((COPIED_FILES+1))
            
        elif [[ "$file" == *".resource" || "$file" == *".resource-meta.xml" ]]; then
            # Static resource
            mkdir -p "$TEMP_DIR/force-app/main/default/staticresources"
            cp "$file" "$TEMP_DIR/force-app/main/default/staticresources/"
            echo "Added Static resource: $file"
            COPIED_FILES=$((COPIED_FILES+1))
            
        elif [[ "$file" == *".labels" || "$file" == *".labels-meta.xml" ]]; then
            # Custom labels
            mkdir -p "$TEMP_DIR/force-app/main/default/labels"
            cp "$file" "$TEMP_DIR/force-app/main/default/labels/"
            echo "Added Custom labels: $file"
            COPIED_FILES=$((COPIED_FILES+1))
            
        else
            # For other files, try to preserve the path structure
            # First, check if it's in a force-app structure already
            if [[ "$file" == *"force-app/main/default/"* ]]; then
                # Extract the path after force-app/main/default
                rel_path=${file#*force-app/main/default/}
                mkdir -p "$TEMP_DIR/force-app/main/default/$(dirname "$rel_path")"
                cp "$file" "$TEMP_DIR/force-app/main/default/$rel_path"
                echo "Added file with existing structure: $file"
                COPIED_FILES=$((COPIED_FILES+1))
            else
                # For unknown files, just copy them to a misc directory
                mkdir -p "$TEMP_DIR/force-app/main/default/misc"
                cp "$file" "$TEMP_DIR/force-app/main/default/misc/$(basename "$file")"
                echo "Added unknown file type: $file"
                COPIED_FILES=$((COPIED_FILES+1))
            fi
        fi
    fi
done

# Check if we copied any files
if [ $COPIED_FILES -eq 0 ]; then
    echo -e "${RED}No deployable files were copied. Nothing to deploy.${NC}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# List the files that will be deployed
echo -e "\n${GREEN}Files prepared for deployment:${NC}"
find "$TEMP_DIR/force-app" -type f | sort

# Generate package.xml
echo -e "\n${GREEN}Generating package.xml...${NC}"
sf project generate manifest --source-dir "$TEMP_DIR/force-app" --output-dir "$TEMP_DIR/force-app/main/default" --api-version 58.0

# Check if package.xml was created
if [ ! -f "$TEMP_DIR/force-app/main/default/package.xml" ]; then
    echo -e "${YELLOW}Failed to generate package.xml automatically. Creating a basic one...${NC}"
    echo '<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <version>58.0</version>
</Package>' > "$TEMP_DIR/force-app/main/default/package.xml"
fi

# Ask for confirmation before deploying
echo -e "\n${YELLOW}Do you want to proceed with the deployment? (y/n)${NC}"
read confirm_deploy

if [[ "$confirm_deploy" != "y" && "$confirm_deploy" != "Y" ]]; then
    echo -e "${YELLOW}Deployment cancelled.${NC}"
    rm -rf "$TEMP_DIR"
    exit 0
fi

# Run a deployment preview first
echo -e "\n${GREEN}Running deployment preview...${NC}"
PREVIEW_COMMAND="sf project deploy preview -d \"$TEMP_DIR/force-app\" --target-org \"$TARGET_ORG\""
echo "Executing: $PREVIEW_COMMAND"
eval "$PREVIEW_COMMAND"
PREVIEW_RESULT=$?

if [ $PREVIEW_RESULT -ne 0 ]; then
    echo -e "${YELLOW}Deployment preview shows issues. Do you still want to proceed? (y/n)${NC}"
    read continue_deploy
    
    if [[ "$continue_deploy" != "y" && "$continue_deploy" != "Y" ]]; then
        echo -e "${YELLOW}Deployment cancelled.${NC}"
        rm -rf "$TEMP_DIR"
        exit 0
    fi
fi

# Try direct deployment from source directory
echo -e "\n${GREEN}Deploying changes to $TARGET_ORG...${NC}"
DEPLOY_COMMAND="sf project deploy start -d \"$TEMP_DIR/force-app\" --target-org \"$TARGET_ORG\" --wait $DEPLOY_TIMEOUT"

echo "Executing: $DEPLOY_COMMAND"
eval "$DEPLOY_COMMAND"
DEPLOY_RESULT=$?

# If direct deployment fails, try converting to mdapi format and deploying
if [ $DEPLOY_RESULT -ne 0 ]; then
    echo -e "${YELLOW}Direct deployment failed. Trying MDAPI format deployment...${NC}"
    
    # Convert to MDAPI format
    MDAPI_DIR="$TEMP_DIR/mdapi"
    mkdir -p "$MDAPI_DIR"
    
    CONVERT_COMMAND="sf project convert source -d \"$TEMP_DIR/force-app\" -r \"$MDAPI_DIR\""
    echo "Executing: $CONVERT_COMMAND"
    eval "$CONVERT_COMMAND"
    
    # Deploy using MDAPI format
    MDAPI_DEPLOY_COMMAND="sf project deploy start -d \"$MDAPI_DIR\" --target-org \"$TARGET_ORG\" --wait $DEPLOY_TIMEOUT"
    echo "Executing: $MDAPI_DEPLOY_COMMAND"
    eval "$MDAPI_DEPLOY_COMMAND"
    DEPLOY_RESULT=$?
fi

# Clean up
echo -e "\n${GREEN}Cleaning up temporary files...${NC}"
rm -rf "$TEMP_DIR"

# Check deployment result
if [ $DEPLOY_RESULT -eq 0 ]; then
    echo -e "\n${GREEN}Deployment completed successfully!${NC}"
    exit 0
else
    echo -e "\n${RED}Deployment failed with errors.${NC}"
    exit 1
fi