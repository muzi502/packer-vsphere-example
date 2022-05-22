# Ensure Make is run with bash shell as some syntax below is bash-specific
SHELL:=/usr/bin/env bash
.DEFAULT_GOAL:=help

# Full directory of where the Makefile resides
ROOT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

##
## --------------------------------------
## Build OVA template
## --------------------------------------

RELEASE_VERSION       ?= $(shell git describe --tags --always --dirty)
RELEASE_TIME          ?= $(shell date -u +'%Y-%m-%dT%H:%M:%SZ')
PACKER_IMAGE          ?= hashicorp/packer:1.8
PACKER_CONFIG_DIR     = $(ROOT_DIR)
PACKER_FORCE          ?= false
PACKER_OVA_PREFIX     ?= k3s
PACKER_BASE_OS        ?= centos7
PACKER_OUTPUT_DIR     ?= $(ROOT_DIR)/output
PACKER_TEMPLATE_NAME  ?= base-os-$(PACKER_BASE_OS)
OVF_TEMPLATE          ?= $(ROOT_DIR)/scripts/ovf_template.xml
PACKER_OVA_NAME       ?= $(PACKER_OVA_PREFIX)-$(PACKER_BASE_OS)-$(RELEASE_VERSION)

ifeq ($(PACKER_FORCE), true)
  PACKER_FORCE_ARG = --force=true
endif

PACKER_VARS = $(PACKER_FORCE_ARG) \
	--var ova_name=$(PACKER_OVA_NAME) \
	--var release_version=$(RELEASE_VERSION) \
	--var ovf_template=$(OVF_TEMPLATE) \
	--var template=$(PACKER_TEMPLATE_NAME) \
	--var username=$${VCENTER_USERNAME} \
	--var password=$${VCENTER_PASSWORD} \
	--var vcenter_server=$${VCENTER_SERVER} \
	--var build_name=$(PACKER_OVA_PREFIX)-$(PACKER_BASE_OS) \
	--var output_dir=$(PACKER_OUTPUT_DIR)/$(PACKER_OVA_NAME)

PACKER_VAR_FILES = -var-file=$(PACKER_CONFIG_DIR)/vcenter.json \
	-var-file=$(PACKER_CONFIG_DIR)/$(PACKER_BASE_OS).json \
	-var-file=$(PACKER_CONFIG_DIR)/common.json

.PHONY: build-template
build-template: ## build the base os template by iso
	packer build $(PACKER_VARS) -only vsphere-iso-base $(PACKER_VAR_FILES) $(PACKER_CONFIG_DIR)/builder.json

.PHONY: build-ovf
build-ovf: ## build the ovf template by clone the base os template
	packer build $(PACKER_VARS) -only vsphere-clone $(PACKER_VAR_FILES) $(PACKER_CONFIG_DIR)/builder.json

.PHONY: help
help:  ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)