# OPA as an IaC Compliance Gate for OpenTofu and Terraform

Infrastructure compliance is often detected too late.

In many environments, insecure or non-compliant infrastructure is first discovered after it already exists in the cloud. Runtime scanners, CSPM platforms, AWS Config, Security Hub, and similar tools are valuable, but they usually operate after deployment. By that point, the resource already exists and the remediation work becomes reactive.

For infrastructure as code, that should not be the only enforcement point.

OpenTofu and Terraform both produce a plan before infrastructure is applied. That plan is a useful control point because it describes what the IaC workflow intends to create, change, or delete. If the plan can be evaluated before `apply`, then preventable compliance violations can be caught before they become deployed infrastructure.

That is where Open Policy Agent fits in.

OPA can evaluate the OpenTofu or Terraform plan JSON and return a policy decision before the apply step runs. In this lab, that decision has two purposes:

- report compliance violations clearly to the engineer
- block `tofu apply` when the planned infrastructure does not satisfy the required controls

This article uses OpenTofu, but the pattern is valid for Terraform as well. The command names differ slightly, but the model is the same: generate a saved plan, export it to JSON, evaluate the JSON with OPA, and use the decision before apply.

## Lab Scenario

The example application is a customer document processing service. Customers upload documents through the application, and those files are eventually stored in an S3 bucket for downstream processing.

That bucket is not a generic storage resource. It stores sensitive customer information, so it needs to meet a baseline set of security requirements before it is deployed:

- public access must be blocked
- versioning must be enabled
- default encryption must use a customer managed KMS key
- non-SSL requests must be denied

The lab focuses on S3 to keep the example small, but the same pattern applies to other controls: security group rules, IAM permissions, load balancer TLS settings, database encryption, backup policies, network exposure, and Kubernetes security settings.

## Repository Structure

The repository is intentionally small. The important source paths are:

```text
.
├── Makefile
├── application/
│   └── iac/
│       ├── main.tf
│       ├── providers.tf
│       ├── variables.tf
│       └── tfvars/
│           ├── compliant.tfvars
│           └── non-compliant.tfvars
├── modules/
│   └── secure-bucket/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── opa/
    └── tofu-plan-policies/
        ├── s3_common.rego
        ├── s3_public_access.rego
        ├── s3_versioning.rego
        ├── s3_encryption.rego
        └── s3_ssl_transport.rego
```

The relevant paths are:

- [`application/iac/`](application/iac/) contains the root OpenTofu module for the application.
- [`application/iac/tfvars/`](application/iac/tfvars/) contains the compliant and non-compliant input variable files used in the demo.
- [`modules/secure-bucket/`](modules/secure-bucket/) contains the reusable S3 bucket module.
- [`opa/tofu-plan-policies/`](opa/tofu-plan-policies/) contains the Rego policies evaluated against the OpenTofu plan JSON.
- [`Makefile`](Makefile) orchestrates formatting, validation, planning, policy evaluation, and gated apply.

Generated files such as `.terraform/`, `*.tfplan`, `*.tfplan.json`, `*.tfstate`, and `opa-decision.json` are intentionally ignored by Git.

## Tools Used

The lab uses four tools:

- OpenTofu defines the infrastructure and generates the execution plan.
- LocalStack provides a local AWS-compatible endpoint.
- OPA evaluates the exported plan JSON and returns a compliance decision.
- Make provides repeatable commands for the local workflow.

The AWS provider is configured to target LocalStack:

```hcl
provider "aws" {
  region     = "eu-central-1"
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    s3 = "http://localhost.localstack.cloud:4566"
  }
}
```

## Baseline OpenTofu Flow

Before adding OPA, OpenTofu already gives us important checks. It can format the configuration, validate syntax and provider schema, resolve variables, expand modules, and generate an execution plan.

Those checks are necessary, but they are not compliance enforcement.

The root module in [`application/iac/main.tf`](application/iac/main.tf) consumes the reusable bucket module:

```hcl
module "customer_documents" {
  source = "../../modules/secure-bucket"

  bucket_name = "customer-document-processing-lab"
  tags = {
    owner               = "document-platform"
    environment         = "local"
    data_classification = "confidential"
    managed_by          = "opentofu"
  }

  public_access_block     = var.bucket_public_access_block
  versioning_enabled      = var.bucket_versioning_enabled
  encryption              = var.bucket_encryption
  deny_insecure_transport = var.bucket_deny_insecure_transport
}
```

The child module in [`modules/secure-bucket/`](modules/secure-bucket/) creates the S3 bucket and related security controls:

- `aws_s3_bucket`
- `aws_s3_bucket_public_access_block`
- `aws_s3_bucket_versioning`
- `aws_s3_bucket_server_side_encryption_configuration`
- `aws_s3_bucket_policy` to deny non-SSL requests

The controls are variable-driven. That lets the lab generate both compliant and non-compliant plans without editing module code for every test.

The non-compliant variable file, [`application/iac/tfvars/non-compliant.tfvars`](application/iac/tfvars/non-compliant.tfvars), intentionally weakens the bucket:

```hcl
bucket_public_access_block = {
  block_public_acls       = false
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

bucket_versioning_enabled = false

bucket_encryption = {
  enabled            = true
  sse_algorithm      = "AES256"
  kms_key_id         = null
  bucket_key_enabled = false
}

bucket_deny_insecure_transport = false
```

The compliant variable file, [`application/iac/tfvars/compliant.tfvars`](application/iac/tfvars/compliant.tfvars), enables the required controls:

```hcl
bucket_public_access_block = {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

bucket_versioning_enabled = true

bucket_encryption = {
  enabled            = true
  sse_algorithm      = "aws:kms"
  kms_key_id         = "arn:aws:kms:eu-central-1:000000000000:key/customer-documents-lab"
  bucket_key_enabled = true
}

bucket_deny_insecure_transport = true
```

OpenTofu can still generate a plan from the non-compliant input:

```bash
make tofu-plan TFVARS="tfvars/non-compliant.tfvars"
```

That is expected. OpenTofu is checking whether the configuration is valid and whether it can calculate the proposed changes. It is not deciding whether the bucket satisfies the organization’s security requirements.

A syntactically valid plan can still be a bad plan. That is the gap the OPA compliance gate closes.

## Where OPA Fits in the Flow

OPA fits best after OpenTofu has generated a plan and before that plan is applied.

At that point, OpenTofu has already parsed the configuration, resolved variables, expanded modules, applied defaults, and calculated the proposed infrastructure changes. That makes the plan the most useful artifact for compliance evaluation. It represents what OpenTofu intends to create or change, not just what was written in individual `.tf` files.

The flow looks like this:

```text
OpenTofu configuration
        |
        v
tofu fmt / tofu validate
        |
        v
tofu plan -out=customer-documents.tfplan
        |
        v
tofu show -json customer-documents.tfplan
        |
        v
OPA evaluates the plan JSON
        |
        v
apply only if the OPA decision allows it
```

OpenTofu does not write the full plan JSON directly from `tofu plan`. The usual flow is to save the plan as a binary file first, then export that saved plan to JSON:

```bash
tofu plan -out=customer-documents.tfplan
tofu show -json customer-documents.tfplan > customer-documents.tfplan.json
```

The resulting JSON contains several sections, including the proposed final state, resource changes, prior state, and parsed configuration. The policies in this lab evaluate `planned_values`, because they care about the final infrastructure shape that would exist after apply.

This matters because the same saved plan can be evaluated and then applied:

```bash
opa eval --data opa/tofu-plan-policies --input customer-documents.tfplan.json ...
tofu apply customer-documents.tfplan
```

That gives the policy gate a clear contract: OPA evaluates the plan OpenTofu is about to apply.

## OPA Policies for S3 Compliance

The Rego policies live in [`opa/tofu-plan-policies/`](opa/tofu-plan-policies/).

The policies are split by control:

```text
opa/tofu-plan-policies/
├── s3_common.rego
├── s3_public_access.rego
├── s3_versioning.rego
├── s3_encryption.rego
└── s3_ssl_transport.rego
```

All policy files use the same package:

```rego
package terraform.compliance.s3
```

That package is exposed through OPA as:

```rego
data.terraform.compliance.s3
```

The files are separated for readability. OPA does not treat each file as an isolated policy. Since they share the same package, the rules are loaded together and can call each other.

The common policy file, [`s3_common.rego`](opa/tofu-plan-policies/s3_common.rego), defines the shared data model:

```rego
default allow := false

allow if {
	count(violations) == 0
}

decision := {
	"allow": allow,
	"violations": violations,
}

s3_buckets contains bucket if {
	bucket := managed_resources[_]
	bucket.type == "aws_s3_bucket"
}
```

The `decision` object is the interface between OPA and the workflow:

- `violations` is the human-facing output.
- `allow` is the automation-facing gate decision.

The policy walks `input.planned_values.root_module` to find managed resources:

```rego
managed_resources contains resource if {
	[_, resource] := walk(input.planned_values.root_module)
	is_object(resource)
	object.get(resource, "mode", "") == "managed"
	object.get(resource, "address", "") != ""
	object.get(resource, "type", "") != ""
	is_object(object.get(resource, "values", null))
}
```

That means every planned `aws_s3_bucket` is in scope. The checks do not depend on tags such as `data_classification = "confidential"`. In this lab, every S3 bucket must satisfy the baseline controls.

The lab checks four requirements:

```text
AWS-S3-001  Public access must be fully blocked
AWS-S3-002  Versioning must be enabled
AWS-S3-003  Default encryption must use SSE-KMS with a customer managed key
AWS-S3-004  Non-SSL requests must be denied by bucket policy
```

Each policy emits structured findings into the same `violations` set. The public access policy, for example, follows this shape:

```rego
violations contains violation if {
	bucket := s3_buckets[_]
	not has_complete_public_access_block(bucket)

	violation := {
		"policy_id": "AWS-S3-001",
		"severity": "high",
		"resource": bucket.address,
		"message": "S3 buckets must block all forms of public access.",
		"remediation": "...",
	}
}
```

The pattern is consistent:

1. find every S3 bucket in the plan
2. check whether the required companion control exists
3. emit a structured violation when the control is missing or misconfigured

When OPA runs, it loads every `.rego` file in the policy directory and evaluates the requested query:

```rego
data.terraform.compliance.s3.decision
```

OPA is query-driven, not script-driven. It is not executing files top to bottom like a shell script. It evaluates the rules needed to build the requested decision.

## Makefile Workflow

The [`Makefile`](Makefile) keeps the OpenTofu and OPA workflow explicit:

```make
tofu-fmt:
	tofu fmt -recursive $(TOFU_FMT_DIRS)

tofu-validate:
	tofu -chdir=$(IAC_DIR) validate

tofu-plan:
	tofu -chdir=$(IAC_DIR) plan -refresh=false $(TOFU_VAR_FILE_ARGS) -out=$(PLAN_FILE)

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
```

The important targets are:

- `compliance-eval` runs format, validate, plan, plan JSON export, and OPA evaluation. It is useful for development feedback because it shows violations without applying anything.
- `apply` runs the same evaluation path, then `opa-check`, then `tofu apply`. If OPA returns `allow: false`, Make stops before apply.

The decision is written once by `opa-eval`:

```bash
opa eval \
  --data opa/tofu-plan-policies \
  --input application/iac/customer-documents.tfplan.json \
  --format raw \
  'json.marshal(data.terraform.compliance.s3.decision)' \
  > application/iac/opa-decision.json
```

Then `opa-check` reads that saved decision:

```bash
jq -e '.allow == true' application/iac/opa-decision.json > /dev/null
```

OPA does not need to run twice. One execution produces a decision document with both the engineer-facing violations and the automation-facing allow/deny result.

## Running the Lab

Start LocalStack, then initialize the OpenTofu working directory:

```bash
tofu -chdir=application/iac init
```

To generate a non-compliant plan and show policy findings:

```bash
make compliance-eval TFVARS="tfvars/non-compliant.tfvars"
```

OPA returns a decision like this:

```json
{
  "allow": false,
  "violations": [
    {
      "message": "S3 buckets must block all forms of public access.",
      "policy_id": "AWS-S3-001",
      "resource": "module.customer_documents.aws_s3_bucket.this",
      "severity": "high"
    },
    {
      "message": "S3 buckets must deny non-SSL requests.",
      "policy_id": "AWS-S3-004",
      "resource": "module.customer_documents.aws_s3_bucket.this",
      "severity": "high"
    },
    {
      "message": "S3 buckets must have versioning enabled.",
      "policy_id": "AWS-S3-002",
      "resource": "module.customer_documents.aws_s3_bucket.this",
      "severity": "high"
    },
    {
      "message": "S3 buckets must use SSE-KMS with a customer managed KMS key.",
      "policy_id": "AWS-S3-003",
      "resource": "module.customer_documents.aws_s3_bucket.this",
      "severity": "critical"
    }
  ]
}
```

This output is useful during development. It tells the engineer what failed without applying anything.

To prove that the same decision can enforce the apply path:

```bash
make apply TFVARS="tfvars/non-compliant.tfvars"
```

OpenTofu can still create a valid plan:

```text
Plan: 3 to add, 0 to change, 0 to destroy.
Saved the plan to: customer-documents.tfplan
```

But OPA returns `allow: false`, and `opa-check` fails:

```text
jq -e '.allow == true' application/iac/opa-decision.json > /dev/null
make: *** [Makefile:45: opa-check] Error 1
```

Because `allow` is `false`, Make stops before `tofu apply`.

Now run the compliant path:

```bash
make apply TFVARS="tfvars/compliant.tfvars"
```

The plan includes the required controls:

```text
aws_s3_bucket_public_access_block.this
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

aws_s3_bucket_server_side_encryption_configuration.this[0]
  sse_algorithm     = "aws:kms"
  kms_master_key_id = "arn:aws:kms:eu-central-1:000000000000:key/customer-documents-lab"

aws_s3_bucket_versioning.this[0]
  status = "Enabled"

aws_s3_bucket_policy.deny_insecure_transport[0]
  Deny when aws:SecureTransport = "false"
```

OPA returns an allow decision:

```json
{
  "allow": true,
  "violations": []
}
```

Then the apply continues:

```text
tofu -chdir=application/iac apply customer-documents.tfplan

Apply complete! Resources: 5 added, 0 changed, 0 destroyed.

Outputs:

customer_documents_bucket_arn = "arn:aws:s3:::customer-document-processing-lab"
```

That is the core behavior of the gate. OPA evaluates the JSON exported from the saved plan, and OpenTofu applies that same saved plan only when the decision allows it.

## Design Choices for an IaC Compliance Gate

The lab shows the mechanics. In a real engineering organization, the value of this pattern depends on a few design choices.

### Where should policies live?

For a small team or a lab, keeping OPA policies in the same repository as the IaC code is reasonable. It keeps the workflow simple and makes the policy logic easy to inspect while developing the infrastructure.

In a larger organization, I would usually separate policy code from application IaC code:

- application and platform teams own root modules, reusable modules, and deployment workflows
- security, governance, or platform governance teams own the policy repository
- CI pipelines consume the policies as a versioned artifact or pinned repository reference

This avoids copying policy logic across many IaC repositories and makes policy changes reviewable and reusable.

### Who should maintain the policies?

Policy ownership should reflect the difference between compliance intent and infrastructure implementation.

- Security or governance teams define the control intent.
- Platform teams translate that intent into reusable infrastructure patterns and CI/CD integration.
- Application teams consume the modules, review the policy feedback, and fix non-compliant configuration before it reaches the cloud environment.

The important point is that policy maintenance should not become detached from engineering reality. A policy that cannot be understood, tested, or remediated by engineers will eventually be bypassed or ignored.

### Where should the gate run?

The same OPA policy can be useful at multiple stages:

- local execution gives engineers fast feedback before opening a pull request
- CI execution blocks non-compliant pull requests before merge
- CD or pre-apply execution ensures the exact saved plan being applied was evaluated
- shared pipeline templates reduce the chance that teams skip the compliance step

The strongest control is the pre-apply gate: evaluate the saved plan, store the OPA decision, and apply only if the decision allows it.

For root modules, my preferred baseline is plan-based evaluation:

1. generate a saved OpenTofu or Terraform plan
2. export that plan to JSON
3. evaluate the JSON with OPA
4. return one decision document containing `violations` and `allow`
5. show `violations` to engineers
6. use `allow` to block or permit apply

This keeps the policy decision close to what the IaC tool is actually going to do.

HashiCorp’s [`tfpolicy`](https://developer.hashicorp.com/terraform/policy) is worth knowing about here. It targets a similar problem, but it is Terraform-specific and HCL-based. I chose OPA for this lab because it is a general policy engine. The same engine can be used for IaC checks, Kubernetes admission control, CI/CD decisions, and other platform guardrails.

## Conclusion

The lab demonstrates a simple but important pattern: evaluate infrastructure intent before infrastructure is created.

The flow is straightforward:

1. OpenTofu creates a saved plan.
2. The saved plan is exported to JSON.
3. OPA evaluates the plan JSON.
4. OPA returns a decision document.
5. Engineers see the policy violations.
6. `tofu apply` runs only when the decision allows it.

In the non-compliant scenario, OpenTofu was still able to generate a valid plan. The issue was not syntax or provider configuration. The issue was that the planned S3 bucket did not meet the required security controls. OPA detected that and returned `allow: false`, which stopped the apply before infrastructure was created.

In the compliant scenario, the same workflow evaluated the saved plan, returned `allow: true`, and allowed OpenTofu to apply that exact plan.

Runtime scanners are still necessary. They detect drift, manual changes, service-level misconfiguration, and issues that only appear after deployment. But they should not be the first line of defense for violations that are already visible in the IaC plan.

OPA gives teams a way to move those checks earlier. Engineers get feedback before deployment, CI can block unsafe changes before merge, and the apply path can enforce compliance against the exact plan that will be deployed.
