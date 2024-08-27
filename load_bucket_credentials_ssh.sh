# Load credentials
# - Sometimes the ssh command fails and we need to retry
max_retries=10
retry_interval=15

# Retry loop
for attempt in $(seq 1 $max_retries); do
    echo "Attempt $attempt"
    
    # Load credentials
    eval $(ssh ${resource_ssh_usercontainer_options} usercontainer ${pw_job_dir}/workflow-utils/bucket_token_generator.py --bucket_id ${dcs_bucket_id} --token_format text)
    
    # Check if BUCKET_NAME is empty
    if [ -n "${BUCKET_NAME}" ]; then
        echo "Credentials loaded successfully"
        break
    else
        echo "Error: BUCKET_NAME variable is empty"
        
        # If it's not the last attempt, wait before retrying
        if [ $attempt -lt $max_retries ]; then
            echo "Retrying in $retry_interval seconds..."
            sleep $retry_interval
        else
            echo "Maximum retries reached. Exiting..."
            exit 1
        fi
    fi
done
