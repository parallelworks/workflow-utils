## salloc main workflow

This workflow uses the salloc subworkflow to allocate node(s), run independent jobs on the allocated node(s), and then release the allocation when any job fails, the workflow is cancelled, or all jobs complete.

---

### Jobs

You can run any independent jobs using the allocated nodes.
This example workflow:

1. Runs "hello world" twice on the allocated nodes.
2. Runs an MPI hello world job across the allocated nodes.

Note: The MPI hello world job assumes that OpenMPI is already installed on the cluster (using [this workflow](https://github.com/parallelworks/workflow-utils/blob/main/workflow/build_install_openmpi.yaml)). The job will source OpenMPI according to that workflow.

### Inputs

The workflow accepts the following inputs:

- `resource`: The compute resource to run the workflow on.
- `partition`: The Slurm partition to use.
- `nodes`: Number of nodes to allocate.
- `walltime`: Walltime for the Slurm allocation.

---

### Purpose

This workflow serves as a basic template for:

- Allocating nodes using Slurm.
- Demonstrating the use of a subworkflow.
- Running independent jobs on previously allocated nodes.
- Ensuring clean release of allocated nodes, even if jobs fail or the workflow is cancelled.
