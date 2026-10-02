.DEFAULT_GOAL := help

WORKFLOW := ./scripts/plugin-workflow.sh

.PHONY: help test local reload store update-store status

help:
	@printf '%s\n' \
		'Usage: make <target>' \
		'' \
		'Targets:' \
		'  test          Run static and component checks without changing DMS.' \
		'  local         Validate, activate the project source, and hot reload.' \
		'  reload        Revalidate and hot reload the local source.' \
		'  store         Activate the cached registry checkout without a download.' \
		'  update-store  Download and activate the published registry version.' \
		'  status        Show the active source, version, and project revision.'

test:
	@$(WORKFLOW) test

local:
	@$(WORKFLOW) local

reload:
	@$(WORKFLOW) reload

store:
	@$(WORKFLOW) store

update-store:
	@$(WORKFLOW) update-store

status:
	@$(WORKFLOW) status
