TF ?= terraform
TF_AUTO_APPROVE ?= -auto-approve

.PHONY: init validate plan apply destroy

init:
	$(TF) init

validate:
	$(TF) validate

plan:
	$(TF) plan

apply:
	$(TF) init && $(TF) apply $(TF_AUTO_APPROVE)

destroy:
	$(TF) destroy $(TF_AUTO_APPROVE)
