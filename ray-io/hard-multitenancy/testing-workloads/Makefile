# Ray.io Hard Multitenancy — Test Runner
#
# Usage:
#   make all                      # Run all tests
#   make raycluster               # RayCluster lifecycle test
#   make rayjob-training          # RayJob training test
#   make rayjob-data              # RayJob data processing test
#   make rayservice               # RayService serving test
#
# Environment:
#   KUBECONFIG_PATH  — path to tenant vCluster kubeconfig (auto-detected from terraform)
#   RAY_NAMESPACE    — namespace for Ray workloads (default: ray)
#   GPU_PER_WORKER   — GPUs per worker (default: 1, 0 = CPU only)

SCRIPT     := ./test-hard-multitenancy.sh
STACK_DIR  := $(shell cd .. && pwd)

# Auto-detect first tenant kubeconfig from terraform output
KUBECONFIG_PATH ?= $(shell cd $(STACK_DIR) && ls -1 *-kubeconfig.yaml 2>/dev/null | head -1)

ifeq ($(KUBECONFIG_PATH),)
$(error No kubeconfig found. Set KUBECONFIG_PATH or run terraform apply first)
endif

COMMON_ARGS := --kubeconfig $(KUBECONFIG_PATH)

ifdef RAY_NAMESPACE
COMMON_ARGS += --namespace $(RAY_NAMESPACE)
endif

ifdef GPU_PER_WORKER
COMMON_ARGS += --gpu-per-worker $(GPU_PER_WORKER)
endif

.PHONY: all raycluster rayjob-training rayjob-data rayservice clean

all:
	$(SCRIPT) $(COMMON_ARGS) --test all

raycluster:
	$(SCRIPT) $(COMMON_ARGS) --test raycluster

rayjob-training:
	$(SCRIPT) $(COMMON_ARGS) --test rayjob-training

rayjob-data:
	$(SCRIPT) $(COMMON_ARGS) --test rayjob-data

rayservice:
	$(SCRIPT) $(COMMON_ARGS) --test rayservice

clean:
	$(SCRIPT) $(COMMON_ARGS) --test all --cleanup
