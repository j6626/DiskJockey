#!/bin/bash

#SBATCH -J AKSco #Single job name for the entire JobArray

#SBATCH -o slurm/AKSco_%A_%a.out #standard output

#SBATCH -e slurm/AKSco_%A_%a.err #standard error

#SBATCH -p general #partition

#SBATCH -t 48:00:00 #running time

#SBATCH --mail-type=BEGIN

#SBATCH --mail-type=END

#SBATCH --mail-user=iancze@gmail.com

#SBATCH --mem 40000 #memory request per node

#SBATCH -N 1 #ensure all jobs are on the same node

#SBATCH -n 51

julia burma_shave.jl -r $SLURM_ARRAY_TASK_ID scripts/AKSco.yaml