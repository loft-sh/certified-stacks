# Slinky (Slurm) Hard Multitenancy — Test Runner
#
# Usage:
#   make all                      # Run all tests
#   make batch-gpu                # Batch GPU job (sbatch + nvidia-smi)
#   make interactive              # Interactive job (srun)
#   make array                    # Array job (parameter sweep)
#   make multi-node               # Multi-node distributed job
#   make inference                # Batch inference job
#
# Environment:
#   KUBECONFIG_PATH  — path to tenant vCluster kubeconfig (auto-detected from terraform)
#   SLURM_NAMESPACE  — Slurm namespace (default: slurm)
#   PARTITION        — Slurm partition name (default: all)
#   ACCESS_METHOD    — port-forward or ssh (default: port-forward)
#   SSH_KEY          — SSH key for login node (if access-method=ssh)

SCRIPT     := ./test-hard-multitenancy.sh
STACK_DIR  := $(shell cd .. && pwd)

# Auto-detect first tenant kubeconfig from terraform output
KUBECONFIG_PATH ?= $(shell cd $(STACK_DIR) && ls -1 *-kubeconfig.yaml 2>/dev/null | head -1)

ifeq ($(KUBECONFIG_PATH),)
$(error No kubeconfig found. Set KUBECONFIG_PATH or run terraform apply first)
endif

COMMON_ARGS := --kubeconfig $(KUBECONFIG_PATH)

ifdef SLURM_NAMESPACE
COMMON_ARGS += --namespace $(SLURM_NAMESPACE)
endif

ifdef PARTITION
COMMON_ARGS += --partition $(PARTITION)
endif

ifdef ACCESS_METHOD
COMMON_ARGS += --access-method $(ACCESS_METHOD)
endif

ifdef SSH_KEY
COMMON_ARGS += --ssh-key $(SSH_KEY)
endif

.PHONY: all batch-gpu interactive array multi-node inference clean

all:
	$(SCRIPT) $(COMMON_ARGS) --test all

batch-gpu:
	$(SCRIPT) $(COMMON_ARGS) --test batch-gpu

interactive:
	$(SCRIPT) $(COMMON_ARGS) --test interactive

array:
	$(SCRIPT) $(COMMON_ARGS) --test array

multi-node:
	$(SCRIPT) $(COMMON_ARGS) --test multi-node

inference:
	$(SCRIPT) $(COMMON_ARGS) --test inference

clean:
	$(SCRIPT) $(COMMON_ARGS) --test all --cleanup
