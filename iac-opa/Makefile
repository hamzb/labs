IAC_DIR := application/iac
OPA_POLICY_DIR := opa/tofu-plan-policies
PLAN_FILE := customer-documents.tfplan
PLAN_JSON := customer-documents.tfplan.json
OPA_DECISION_FILE := opa-decision.json
OPA_DECISION_QUERY := json.marshal(data.terraform.compliance.s3.decision)

.PHONY: help tofu-fmt tofu-validate tofu-plan tofu-plan-json opa-eval opa-check compliance-eval apply

help:
	@echo "Available targets:"
	@echo "  tofu-fmt          Format OpenTofu configuration"
	@echo "  tofu-validate     Validate OpenTofu configuration"
	@echo "  tofu-plan         Create OpenTofu binary plan"
	@echo "  tofu-plan-json    Export OpenTofu plan to JSON"
	@echo "  opa-eval          Evaluate OPA policies and show the decision"
	@echo "  opa-check         Fail when the OPA decision denies the plan"
	@echo "  compliance-eval   Run fmt, validate, plan, plan export, and show the OPA decision"
	@echo "  apply             Run compliance-eval and opa-check, then apply the evaluated plan"

tofu-fmt:
	tofu -chdir=$(IAC_DIR) fmt -recursive

tofu-validate:
	tofu -chdir=$(IAC_DIR) validate

tofu-plan:
	tofu -chdir=$(IAC_DIR) plan -refresh=false -out=$(PLAN_FILE)

tofu-plan-json: tofu-plan
	tofu -chdir=$(IAC_DIR) show -json $(PLAN_FILE) > $(IAC_DIR)/$(PLAN_JSON)

opa-eval:
	opa eval --data $(OPA_POLICY_DIR) --input $(IAC_DIR)/$(PLAN_JSON) --format raw '$(OPA_DECISION_QUERY)' > $(IAC_DIR)/$(OPA_DECISION_FILE)
	jq . $(IAC_DIR)/$(OPA_DECISION_FILE)

opa-check:
	jq -e '.allow == true' $(IAC_DIR)/$(OPA_DECISION_FILE) > /dev/null

compliance-eval: tofu-fmt tofu-validate tofu-plan-json opa-eval

apply: compliance-eval opa-check
	tofu -chdir=$(IAC_DIR) apply $(PLAN_FILE)
