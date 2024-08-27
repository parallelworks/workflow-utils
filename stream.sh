#!/bin/bash
# Runs on the remote host

delay=30
pushfile=logs.out
host=usercontainer

if [ -z "${port}" ]; then
    port_flag=""
else
    port_flag=" -p ${port} "
fi

sshcmd="ssh ${resource_ssh_usercontainer_options} ${port_flag} $host"


${sshcmd} 'cat >>"'${pw_job_dir}/logs.out'"' >> logstream.out 2>&1

while true; do
    if [ -f "$pushfile" ]; then
        echo "Running" >> logstream.out 2>&1
        tail -c +1 -f "$pushfile" | ${sshcmd} 'cat >>"'${pw_job_dir}/logs.out'"' >> logstream.out 2>&1
        echo CLOSING PID: $? >> logstream.out 2>&1
        exit 0
    else
        echo "Preparing" >> logstream.out 2>&1
        echo "preparing inputs" | ${sshcmd} 'cat >>"'${pw_job_dir}/logs.out'"' >> logstream.out 2>&1
        sleep $delay
    fi
done