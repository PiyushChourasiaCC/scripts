import os
import sys
import subprocess
import json
import webbrowser
import errno

PROJECT_MAP = {
    "1": ("GPTfy", "https://github.com/plumcloudlabs/hello-world-piyushcc"),
    "2": ("CC", "https://github.com/PiyushChourasiaCC/GPYFY-Dev"),
    "3": ("DM", "https://github.com/PiyushChourasiaCC/hackathon-dataseeder")
}
STATE_FILE = ".cursor_flow_state"
MAX_RETRIES = 3

def run_command(cmd, cwd=None, exit_on_fail=False):
    try:
        print(f"\n> {' '.join(cmd)}")
        result = subprocess.run(cmd, check=True, cwd=cwd, text=True, capture_output=True)
        print(result.stdout)
        return True, result.stdout
    except subprocess.CalledProcessError as e:
        print(f"Command failed: {' '.join(cmd)}")
        print(f"Error: {str(e)}")
        if e.stdout:
            print(f"Output: {e.stdout}")
        if e.stderr:
            print(f"Error details: {e.stderr}")
        if exit_on_fail:
            sys.exit(1)
        return False, str(e)

def input_with_retry(prompt, valid_fn, max_retries=MAX_RETRIES):
    for _ in range(max_retries):
        val = input(prompt)
        if valid_fn(val):
            return val
        print("Invalid input, try again.")
    print("Too many invalid attempts.")
    sys.exit(1)

def save_state(step, data=None):
    try:
        with open(STATE_FILE, 'w') as f:
            json.dump({"step": step, "data": data or {}}, f)
    except IOError as e:
        print(f"Warning: Could not save state: {str(e)}")

def load_state():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, 'r') as f:
                return json.load(f)
        except IOError as e:
            print(f"Warning: Could not load state: {str(e)}")
    return None

def main():
    # Store the starting directory
    starting_dir = os.getcwd()
    
    # 1. Initial Setup
    print("Checking Salesforce CLI and GitHub CLI...")
    success, _ = run_command(["sf", "--version"], exit_on_fail=False)
    if not success:
        print("Salesforce CLI (sf) not found. Please install it.")
        sys.exit(1)
    success, _ = run_command(["gh", "--version"], exit_on_fail=False)
    if not success:
        print("GitHub CLI (gh) not found. Please install it.")
        sys.exit(1)
    
    # 2. Project Selection
    print("\nSelect project type:")
    for k, v in PROJECT_MAP.items():
        print(f"{k}. {v[0]}")
    choice = input_with_retry("Enter choice (1-3): ", lambda x: x in PROJECT_MAP)
    project_name, repo_url = PROJECT_MAP[choice]
    save_state("project_selection", {"project": project_name, "repo_url": repo_url})

    # 3. GitHub Clone (clone into a new directory)
    repo_dir = repo_url.split('/')[-1]
    
    # Create temporary working directory with proper permissions if needed
    temp_work_dir = os.path.join(starting_dir, "sf_automation_workspace")
    try:
        if not os.path.exists(temp_work_dir):
            os.makedirs(temp_work_dir, exist_ok=True)
        os.chdir(temp_work_dir)
    except (OSError, PermissionError) as e:
        print(f"Error: Could not create or change to temp directory: {str(e)}")
        print(f"Continuing in current directory: {starting_dir}")
        temp_work_dir = starting_dir
    
    if os.path.exists(repo_dir):
        print(f"\nDirectory '{repo_dir}' already exists. Using existing directory.")
    else:
        print(f"\nCloning repository {repo_url} into ./{repo_dir} ...")
        clone_success = False
        for attempt in range(MAX_RETRIES):
            success, _ = run_command(["gh", "repo", "clone", repo_url, repo_dir], exit_on_fail=False)
            if success:
                clone_success = True
                break
            print("Clone failed, retrying...")
        if not clone_success:
            print("Failed to clone repository after multiple attempts.")
            sys.exit(1)

    # Try to change to repo directory
    try:
        repo_path = os.path.join(temp_work_dir, repo_dir)
        if os.path.isdir(repo_path):
            os.chdir(repo_path)
            print(f"Changed to directory: {os.getcwd()}")
        else:
            print(f"Repository directory not found at {repo_path}")
            sys.exit(1)
    except (OSError, PermissionError) as e:
        print(f"Error changing to repository directory: {str(e)}")
        sys.exit(1)

    # 4. Branch Selection
    print("\nFetching available branches...")
    try:
        # Use git command directly with absolute path to work directory
        branches_cmd = ["git", "ls-remote", "--heads", "origin"]
        success, output = run_command(branches_cmd, cwd=os.getcwd())
        
        if not success:
            print("Failed to fetch branches. Using main branch.")
            branches = ["main"]
        else:
            # Process the output to extract branch names
            branches = []
            for line in output.strip().split('\n'):
                if line.strip():
                    parts = line.split('/')
                    if len(parts) >= 3:
                        branches.append(parts[-1])
        
        for idx, branch in enumerate(branches, 1):
            print(f"{idx}. {branch}")
        
        branch_choice = input_with_retry("Select branch number: ",
                                      lambda x: x.isdigit() and 1 <= int(x) <= len(branches))
        selected_branch = branches[int(branch_choice) - 1]
        
        # Checkout the branch
        success, _ = run_command(["git", "checkout", selected_branch], cwd=os.getcwd())
        if success:
            # Add confirmation message for GitHub branch connection
            print(f"\n✅ You are now connected to GitHub branch: {selected_branch} in repository: {repo_url}")
            print(f"Repository location: {os.getcwd()}")
            save_state("branch_selection", {"branch": selected_branch})
        else:
            print(f"Error checking out branch: {selected_branch}")
            print("Continuing with current branch.")
    except Exception as e:
        print(f"Error selecting branch: {str(e)}")
        print("Continuing with current branch.")

    # 5. Login to DevHub first (before metadata pull)
    print("\nPlease login to your Salesforce DevHub Org.")
    success, _ = run_command(["sf", "org", "login", "web", "--alias", "DevHub"], cwd=os.getcwd())
    if not success:
        print("Failed to authenticate with DevHub. Exiting.")
        sys.exit(1)
    
    # 6. Pull Salesforce Metadata
    print("\nPulling Salesforce metadata from branch...")
    success, _ = run_command([
        "sf", "project", "retrieve", "start",
        "--target-org", "DevHub",
        "--branch", selected_branch
    ], cwd=os.getcwd(), exit_on_fail=False)
    if not success:
        print("Warning: Metadata retrieval may have encountered issues, but continuing...")

    # 7. Scratch Org Creation (updated for 30 days, SSO enabled, and custom name)
    scratch_org_alias = f"scratch{project_name}"
    print(f"\nCreating scratch org with alias {scratch_org_alias} (30 days, SSO enabled)...")
    success, result = run_command([
        "sf", "org", "create", "scratch",
        "--definition-file", "config/project-scratch-def.json",
        "--duration-days", "30",
        "--alias", scratch_org_alias,
        "--set-default"
    ], cwd=os.getcwd(), exit_on_fail=False)
    
    # Extract org login URL from response to authorize user
    if success:
        # Try to extract the org URL or username for authorization
        org_info = None
        try:
            success, org_info = run_command(["sf", "org", "display", "--target-org", scratch_org_alias, "--json"], cwd=os.getcwd())
            if success:
                org_data = json.loads(org_info)
                login_url = org_data.get("result", {}).get("instanceUrl", "")
                if login_url:
                    print(f"\n✅ Automatically opening scratch org in browser for authorization...")
                    webbrowser.open(login_url)
                    print(f"Opened {login_url} in your browser")
        except Exception as e:
            print(f"Warning: Couldn't auto-open scratch org: {str(e)}")
            print("You can manually access your scratch org with: sf org open --target-org " + scratch_org_alias)

    # 8. Deploy Metadata
    print("\nDeploying metadata to scratch org...")
    success, _ = run_command([
        "sf", "project", "deploy", "start",
        "--target-org", scratch_org_alias
    ], cwd=os.getcwd(), exit_on_fail=False)
    if success:
        print("✅ Deployment complete.")
    else:
        print("⚠️ Deployment may have encountered issues. Review the output above.")

    # 9. Post-Deploy Options
    print("\nWhat would you like to do next?")
    print("1. Develop Manually")
    print("2. Process Document")
    post_choice = input_with_retry("Enter choice (1-2): ", lambda x: x in ["1", "2"])
    if post_choice == "1":
        print("Exiting. You can now develop manually in your scratch org.")
        sys.exit(0)

    # 10. Documentation Workflow
    print("\n--- Documentation Workflow ---")
    try:
        with open("Project_Idea.txt", "w") as f:
            f.write(f"Purpose: {input('Purpose of this new capability: ')}\n")
            f.write(f"Audience: {input('Audience: ')}\n")
            f.write(f"Architecture preferences: {input('Architecture preferences: ')}\n")
            f.write(f"User Experience preferences: {input('User Experience preferences: ')}\n")
            f.write(f"Testing Data: {input('Testing Data: ')}\n")
        print("Project_Idea.txt created.")

        # Simulate AI/agent prompts for PRD and Plan generation
        with open("PRD.txt", "w") as f:
            f.write("/* Cursor Agent: Generate a PRD based on Project_Idea.txt */\n")
        print("PRD.txt created (placeholder).")

        with open("Plan.txt", "w") as f:
            f.write("/* Cursor Agent: Generate a step-by-step plan based on PRD.txt */\n")
        print("Plan.txt created (placeholder).")
    except (IOError, PermissionError) as e:
        print(f"Error creating documentation files: {str(e)}")
        print("Skipping documentation creation due to permissions.")

    # Validation loop
    try:
        while True:
            yn = input("Review the plan, make sure it is in conformance with your requirements. Is it valid? (y/n): ").lower()
            if yn in ["y", "yes"]:
                break
            print("Regenerating Plan.txt to match PRD.txt...")
            with open("Plan.txt", "w") as f:
                f.write("/* Cursor Agent: Validate and fix Plan.txt to match PRD.txt */\n")
    except (IOError, PermissionError) as e:
        print(f"Error updating Plan.txt: {str(e)}")

    print("\nStarting implementation based on PRD.txt and Project_Idea.txt (manual step).")
    print("All steps completed!")
    
    # Return to the original directory
    try:
        os.chdir(starting_dir)
    except (OSError, PermissionError) as e:
        print(f"Warning: Could not return to starting directory: {str(e)}")

if __name__ == "__main__":
    main()