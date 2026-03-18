# src/repo_scanner/lambda_function.py
import json
import os
import subprocess
import shutil

def list_files_in_repo(repo_url):
    """Clones a git repo and returns a list of its files."""
    repo_dir = "/tmp/repo"
    if os.path.exists(repo_dir):
        shutil.rmtree(repo_dir)
    try:
        print(f"Cloning repository: {repo_url}")
        subprocess.run(
            ["git", "clone", repo_url, repo_dir],
            check=True,
            capture_output=True,
            text=True
        )
        print("Repository cloned successfully.")
        file_list = []
        for root, dirs, files in os.walk(repo_dir):
            if '.git' in dirs:
                dirs.remove('.git')
            for name in files:
                relative_path = os.path.relpath(os.path.join(root, name), repo_dir)
                file_list.append(relative_path)
        return {"files": file_list}
    except subprocess.CalledProcessError as e:
        print(f"An error occurred. Git command failed with stderr: {e.stderr}")
        return {"files": []}
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        return {"files": []}

#start handler
def handler(event, context):
    """The main Lambda handler function."""
    print(f"--- LAMBDA V6 (DEFINITIVE FIX) IS RUNNING ---")
    print(f"Full event received: {json.dumps(event)}")

    repo_url = None
    try:
        # This is the correct path to find the parameter from the Bedrock Agent event
        properties = event['requestBody']['content']['application/json']['properties']
        repo_url = next((prop['value'] for prop in properties if prop['name'] == 'repo_url'), None)
    except (KeyError, StopIteration):
        print("Error: Could not find repo_url in the expected path.")

    if not repo_url:
        print("Error: repo_url is missing.")
        result = {"files": []}
    else:
        result = list_files_in_repo(repo_url)

    response_body = json.dumps(result)

    # This is the exact response structure Bedrock expects
    api_response = {
        'messageVersion': '1.0',
        'response': {
            'actionGroup': event['actionGroup'],
            'apiPath': event['apiPath'],
            'httpMethod': event['httpMethod'],
            'httpStatusCode': 200,
            'responseBody': {
                'application/json': {
                    'body': response_body
                }
            }
        }
    }

    return api_response
