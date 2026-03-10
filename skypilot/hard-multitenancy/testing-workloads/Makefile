# SkyPilot Hard Multitenancy — Test Runner
#
# Usage:
#   make all                      # Run all tests
#   make cluster                  # sky launch (dev cluster)
#   make exec                     # sky exec (remote command)
#   make managed-job              # sky jobs launch (managed training)
#   make serve                    # sky serve up (model serving)
#
# Environment:
#   KUBECONFIG_PATH  — path to tenant vCluster kubeconfig (auto-detected from terraform)
#   API_ENDPOINT     — SkyPilot API server URL (auto-detected if omitted)
#   API_CREDENTIALS  — Auth credentials for the API (user:pass)
#   GPU_ENABLED      — true/false (default: true)

SCRIPT     := ./test-hard-multitenancy.sh
STACK_DIR  := $(shell cd .. && pwd)

# Auto-detect first tenant kubeconfig from terraform output
KUBECONFIG_PATH ?= $(shell cd $(STACK_DIR) && ls -1 *-kubeconfig.yaml 2>/dev/null | head -1)

ifeq ($(KUBECONFIG_PATH),)
$(error No kubeconfig found. Set KUBECONFIG_PATH or run terraform apply first)
endif

COMMON_ARGS := --kubeconfig $(KUBECONFIG_PATH)

ifdef API_ENDPOINT
COMMON_ARGS += --api-endpoint $(API_ENDPOINT)
endif

ifdef API_CREDENTIALS
COMMON_ARGS += --api-credentials $(API_CREDENTIALS)
endif

ifeq ($(GPU_ENABLED),false)
COMMON_ARGS += --no-gpu
endif

.PHONY: all cluster exec managed-job serve clean

all:
	$(SCRIPT) $(COMMON_ARGS) --test all

cluster:
	$(SCRIPT) $(COMMON_ARGS) --test cluster

exec:
	$(SCRIPT) $(COMMON_ARGS) --test exec

managed-job:
	$(SCRIPT) $(COMMON_ARGS) --test managed-job

serve:
	$(SCRIPT) $(COMMON_ARGS) --test serve

clean:
	$(SCRIPT) $(COMMON_ARGS) --test all --cleanup
