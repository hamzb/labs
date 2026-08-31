# OPA as an IaC Compliance Gate for OpenTofu and Terraform

Infrastructure compliance is often detected too late.

In many environments, insecure or non-compliant infrastructure is first discovered after it already exists in the cloud. Runtime scanners, CSPM platforms, AWS Config, Security Hub, and similar tools are valuable, but they usually operate after deployment. By that point, the resource has already been created, the finding has already been generated, and the remediation work becomes reactive.

For infrastructure as code, that is not the only place where compliance can be enforced.

OpenTofu and Terraform already produce a plan before infrastructure is applied. That plan is a useful control point because it describes what the IaC workflow intends to create, change, or delete. If the plan can be evaluated before `apply`, then basic compliance violations can be caught before they become deployed infrastructure.

That is where Open Policy Agent fits in.

OPA can evaluate the OpenTofu plan JSON and return a policy decision before the apply step runs. In this lab, that decision has two purposes:

- report compliance violations clearly to the engineer
- block `tofu apply` when the planned infrastructure does not satisfy the required controls

The example is intentionally small: a customer document processing application that needs an S3 bucket for sensitive customer documents. Because that bucket stores sensitive data, it must satisfy a few baseline controls:

- public access must be fully blocked
- versioning must be enabled
- encryption must use SSE-KMS with a customer managed key
- non-SSL requests must be denied

The goal is not to replace runtime cloud scanners. Those still matter. The goal is to reduce how often preventable issues reach the cloud environment in the first place.

The lab demonstrates a practical flow:

1. OpenTofu generates a saved plan.
2. The plan is exported to JSON.
3. OPA evaluates the plan JSON.
4. OPA returns a decision with `violations` and `allow`.
5. The workflow reports violations during development.
6. The apply path blocks non-compliant plans before deployment.

This turns IaC compliance from a post-deployment finding into an early engineering gate.

## Lab Scenario and Tools

The lab uses a small OpenTofu project to model an application component deployed in AWS and OPA to evaluate compliance before the infrastructure is applied. LocalStack provides a local AWS API emulator so the example can run without a real AWS account. Make ties the workflow together with repeatable commands.

I use OpenTofu in the lab, but the same pattern applies to Terraform. Both tools can generate a saved plan, export it to JSON, and pass that JSON document to OPA before apply. The command names may differ slightly, but the policy model and design principles are the same.

The important point is where the compliance decision happens. OPA does not inspect live resources. It evaluates the OpenTofu/Terraform plan before apply. That gives us an early gate: if the planned infrastructure violates policy, the apply step can be blocked before anything reaches LocalStack or AWS.

### The Lab Environment

In this lab, we use four tools:

- OpenTofu defines the infrastructure and generates the execution plan.
- LocalStack provides a local AWS-compatible endpoint.
- OPA evaluates the exported plan JSON and returns a compliance decision.
- Make orchestrates formatting, validation, planning, policy evaluation, and gated apply.

The workflow is intentionally simple:

```bash
make compliance-eval TFVARS="tfvars/non-compliant.tfvars"
make apply TFVARS="tfvars/compliant.tfvars"
```

`compliance-eval` generates the plan, exports it to JSON, and shows the OPA decision. `apply` runs the same evaluation path, checks the decision, and applies only if the plan is allowed.

### Repository Structure

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

### The Application Scenario

The example application is a customer document processing service. Customers upload documents through the application, and those files are eventually stored in an S3 bucket for downstream processing.

That bucket is not just a generic storage resource. It holds sensitive customer information, so it needs to meet a baseline set of security requirements before it is deployed:

- public access must be blocked
- versioning should be enabled
- default encryption should use a customer managed KMS key
- non-SSL requests should be denied

This makes the S3 bucket a good resource for demonstrating policy enforcement. The compliance requirements are easy to understand, but they are still realistic enough to reflect the kind of controls platform and security teams care about in enterprise environments.

This lab uses an S3 bucket resource to keep the example small and focused, but the same pattern applies to other infrastructure controls such as security group rules, IAM permissions, database encryption, backup settings, network exposure, and other cloud configuration requirements.

With the scenario defined, the next step is to look at the baseline OpenTofu workflow. Before adding OPA, OpenTofu can format, validate, plan, and apply this configuration, but it will not decide whether the planned bucket configuration satisfies the organization’s security requirements. That is the gap the policy gate targets.

## Baseline OpenTofu Flow Without OPA

Before adding OPA, it is worth looking at what OpenTofu already gives us. OpenTofu can format the configuration, validate the syntax and provider schema, resolve variables, expand modules, and generate an execution plan. Those are important checks, but they are not the same thing as compliance enforcement.

### The OpenTofu Project Structure

In this lab, the OpenTofu code is split into a root module and a reusable child module:

```text
application/iac/
  Root module for the customer document application

modules/secure-bucket/
  Reusable S3 bucket module

opa/tofu-plan-policies/
  OPA policies evaluated later against the exported plan JSON

Makefile
  Local workflow for formatting, validation, planning, OPA evaluation, and gated apply
```

The root module represents the application infrastructure. It consumes a reusable bucket module and passes the security-related settings as variables:

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

The module itself creates the S3 bucket and the related security resources. The controls are variable-driven so the same module can generate either a compliant or non-compliant plan during the lab.

The bucket resource is simple:

```hcl
resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name
  tags   = var.tags
}
```

The public access block is always created, but its settings come from variables:

```hcl
resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = var.public_access_block.block_public_acls
  block_public_policy     = var.public_access_block.block_public_policy
  ignore_public_acls      = var.public_access_block.ignore_public_acls
  restrict_public_buckets = var.public_access_block.restrict_public_buckets
}
```

Versioning, encryption, and the deny-insecure-transport bucket policy are controlled in the same way:

```hcl
resource "aws_s3_bucket_versioning" "this" {
  count = var.versioning_enabled ? 1 : 0

  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}
```

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  count = var.encryption.enabled ? 1 : 0

  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.encryption.sse_algorithm
      kms_master_key_id = var.encryption.kms_key_id
    }

    bucket_key_enabled = var.encryption.bucket_key_enabled
  }
}
```

```hcl
resource "aws_s3_bucket_policy" "deny_insecure_transport" {
  count = var.deny_insecure_transport ? 1 : 0

  bucket = aws_s3_bucket.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          "arn:aws:s3:::${var.bucket_name}",
          "arn:aws:s3:::${var.bucket_name}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })
}
```

The policy resource intentionally derives the bucket ARN from `var.bucket_name`. That value is known during planning, which means the generated bucket policy can be inspected in the plan JSON before the bucket exists.

### Generating Different Plans with Variable Files

For the lab, variable files make it easy to produce different plans without editing the module code. The same root module and child module can be used to generate an insecure configuration first, then a secure configuration after the controls are enabled.

The lab uses two variable files:

```text
application/iac/tfvars/non-compliant.tfvars
application/iac/tfvars/compliant.tfvars
```

During testing, the non-compliant variable file is used to generate a plan that violates the OPA policies. That gives us a clear failure case. Then the compliant variable file is used to generate a secure plan and verify that the same policies return a clean decision.

The non-compliant file intentionally weakens the bucket configuration:

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

The compliant file enables the required controls:

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

### The OpenTofu Flow Before OPA

At this stage, there is still no policy enforcement. OpenTofu can format, validate, and plan both configurations:

```bash
make tofu-fmt
make tofu-validate
make tofu-plan TFVARS="tfvars/non-compliant.tfvars"
```

The plan command will produce an execution plan for the non-compliant configuration. That is expected. OpenTofu is checking whether the configuration is valid and whether it can calculate the proposed changes. It is not checking whether the bucket satisfies the organization’s security requirements.

That distinction is the core reason for introducing OPA. A syntactically valid plan can still be a bad plan. In this example, OpenTofu can generate a plan where public ACLs are not fully blocked, versioning is disabled, encryption uses `AES256` instead of a customer managed KMS key, and no bucket policy denies non-SSL requests.

Without a policy gate, that kind of configuration can move further down the delivery path and only be detected later by a live-resource scanner. The next section explains the approach for using OPA against the OpenTofu plan and where that policy evaluation step fits in the flow.

## Where OPA Fits in the OpenTofu Flow

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

That gives the policy gate a clear contract: OPA is not evaluating an approximation of the infrastructure. It is evaluating the plan OpenTofu is about to apply.

### Root Modules and Child Modules

For root modules, the final OpenTofu plan should be the main compliance artifact. Root modules represent real deployment intent: environment-specific variables, module composition, provider configuration, and the final set of planned resources.

There is also a useful earlier checkpoint for reusable child modules. A team that publishes a shared module can create a small test root module, generate dummy plans from that module, and evaluate those plans with OPA during module development.

The difference is where the evaluated plan comes from:

- application pipelines evaluate plans generated by real root modules
- module development pipelines evaluate plans generated by small module test units

This is a good practice because it catches bad module defaults before the module is consumed by many teams. It does not replace root-module enforcement, but it reduces the chance that non-compliant module behavior propagates into multiple applications and environments.

For this lab, the main focus remains the root-module flow: generate the OpenTofu plan, export it to JSON, evaluate it with OPA, and block apply when the decision is not allowed.

## OPA Policies for S3 Compliance

This section explains how the lab turns S3 security requirements into small Rego policies that can be evaluated against an OpenTofu plan.

The Rego policies for this lab live in the lab repo under [`opa/tofu-plan-policies/`](opa/tofu-plan-policies/).

The policies are intentionally small and split by control:

```text
opa/tofu-plan-policies/
├── s3_common.rego
├── s3_public_access.rego
├── s3_versioning.rego
├── s3_encryption.rego
└── s3_ssl_transport.rego
```

All files use the same package:

```rego
package terraform.compliance.s3
```

That package is the logical namespace OPA exposes under:

```rego
data.terraform.compliance.s3
```

The files are separated for readability. OPA does not treat each file as an isolated policy. Since they share the same package, the rules are loaded together and can call each other.

### The Shared Policy Shape

The shared file, [`s3_common.rego`](opa/tofu-plan-policies/s3_common.rego), defines the common data model used by the individual checks.

The main selector is:

```rego
s3_buckets contains bucket if {
	bucket := managed_resources[_]
	bucket.type == "aws_s3_bucket"
}
```

This means every `aws_s3_bucket` in the OpenTofu plan is in scope. The policy does not depend on a tag such as `data_classification = "confidential"`. In this lab, every S3 bucket must satisfy the baseline controls.

The `managed_resources` helper walks the plan:

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

The important part is `input.planned_values.root_module`. The policies evaluate the proposed final state from the OpenTofu plan JSON. That lets the checks reason about what the infrastructure will look like after apply, including resources generated inside child modules.

The package also exposes a single decision object:

```rego
decision := {
	"allow": allow,
	"violations": violations,
}
```

This keeps the interface simple. Automation checks `allow`. Humans read `violations`.

### The Compliance Checks

Each compliance check adds findings to the same `violations` set:

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

The pattern is the same across the policy files:

1. find every S3 bucket in the plan
2. check whether the required control exists
3. emit a structured violation when the control is missing or misconfigured

The lab currently checks four S3 requirements:

```text
AWS-S3-001  Public access must be fully blocked
AWS-S3-002  Versioning must be enabled
AWS-S3-003  Default encryption must use SSE-KMS with a customer managed key
AWS-S3-004  Non-SSL requests must be denied by bucket policy
```

The public access policy checks for an `aws_s3_bucket_public_access_block` resource in the same module as the bucket, with all four protection flags set to `true`.

The versioning policy accepts either inline bucket versioning data or a dedicated `aws_s3_bucket_versioning` resource with `status = "Enabled"`.

The encryption policy requires KMS-based default encryption, specifically `aws:kms` or `aws:kms:dsse`, and a non-empty key ID that is not the AWS-managed `alias/aws/s3` key.

The SSL transport policy checks for an `aws_s3_bucket_policy` that denies requests where:

```json
{
  "Bool": {
    "aws:SecureTransport": "false"
  }
}
```

### How OPA Evaluates Them

When OPA runs, it loads every `.rego` file in the policy directory, groups the rules by package, and evaluates the requested query against the plan JSON input.

In this lab, the Makefile asks for one decision:

```rego
data.terraform.compliance.s3.decision
```

OPA evaluates whatever rules are needed to build that decision. It is not executing files top to bottom like a shell script. The final result is a small JSON document:

```json
{
  "allow": false,
  "violations": [
    {
      "policy_id": "AWS-S3-001",
      "severity": "high",
      "resource": "module.customer_documents.aws_s3_bucket.this",
      "message": "S3 buckets must block all forms of public access."
    }
  ]
}
```

That is the policy contract for the rest of the workflow: if `allow` is `true`, the plan can move forward. If `allow` is `false`, the violations explain what needs to be fixed.

## Demonstration

At this point, the lab has everything needed to answer the practical question: what should OPA do in the OpenTofu workflow?

There are two useful answers:

- OPA can report compliance issues so engineers get fast feedback during development.
- OPA can act as an enforcement gate so non-compliant plans cannot be applied.

The lab uses OPA at both levels:

- `compliance-eval` generates the plan and reports the OPA decision without failing on policy violations.
- `apply` runs the same evaluation, then blocks `tofu apply` if the OPA decision does not allow the plan.

The rest of this section shows how that behavior is implemented in the Makefile and what the execution looks like for non-compliant and compliant plans.

### The Makefile Flow

The Makefile keeps the OpenTofu and OPA workflow explicit. It separates the workflow into small directives, then combines them into the two user-facing paths: report-only evaluation and gated apply.

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

The OpenTofu directives prepare the plan:

- `tofu-fmt` formats the OpenTofu code in the root module and reusable modules.
- `tofu-validate` validates the root module and its module dependencies.
- `tofu-plan` creates a saved binary plan. It accepts variable files through `TFVARS`, so the lab can generate compliant or non-compliant plans from the same module code.
- `tofu-plan-json` exports the saved binary plan to JSON. This JSON file is the input OPA evaluates.

The OPA directives evaluate and enforce the policy decision:

- `opa-eval` runs the OPA evaluation. It loads the Rego policies from `$(OPA_POLICY_DIR)`, passes the exported OpenTofu plan JSON as `input`, evaluates the `$(OPA_DECISION_QUERY)` query, and writes the result to `$(IAC_DIR)/$(OPA_DECISION_FILE)`.
- `opa-check` does not evaluate the policies again. It reads the saved decision file and checks whether `.allow == true`. If that check fails, Make stops before `tofu apply`.

The workflow directives combine those steps:

- `compliance-eval` runs the full evaluation path: format, validate, plan, export plan JSON, run OPA, and print the OPA decision. This target is useful for development feedback because it shows violations without blocking the command.
- `apply` runs `compliance-eval`, then `opa-check`, then `tofu apply` using the saved binary plan.

A full apply therefore follows this order:

1. `tofu-fmt` formats the OpenTofu files.
2. `tofu-validate` validates the root module.
3. `tofu-plan` creates `customer-documents.tfplan`.
4. `tofu-plan-json` exports that plan to `customer-documents.tfplan.json`.
5. `opa-eval` writes the OPA decision to `opa-decision.json` and prints it.
6. `opa-check` checks whether `allow` is `true`.
7. `tofu apply` runs only if `opa-check` succeeds.

This keeps the evaluated artifact and the applied artifact aligned: OPA evaluates JSON exported from the saved plan, and OpenTofu applies that same saved plan.

### Non-Compliant Plan

In this part of the article, we will demo the execution flow for a non-compliant configuration, look at the OPA output, and show how that output is used by the workflow.

We will use the variable file with insecure settings to generate a non-compliant plan:

```bash
make compliance-eval TFVARS="tfvars/non-compliant.tfvars"
```

The generated plan is valid from OpenTofu’s point of view, but it does not satisfy the S3 compliance requirements. This is reflected by OPA as it returns a decision output like this:

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

The decision document has two important fields:

- `violations`: the list of compliance findings returned by the Rego policies. This is the human-facing part of the output and tells the engineer what failed.
- `allow`: the gate decision derived from the violations. This is the automation-facing part of the output and will be used later to decide whether `tofu apply` can continue.

This is useful during development because the engineer gets a concrete list of findings without applying anything. The output also makes the compliance failure specific: this is not a generic "policy failed" result. It tells the engineer which resource failed, which control failed, and what needs to be fixed.

### Gated Apply

The previous command showed the OPA decision without failing the workflow. The next step is to use that same decision as an enforcement gate.

The non-compliant configuration should not be deployable through the apply path.

Snippet 1 — Run the gated apply target

**Command**

```bash
make apply TFVARS="tfvars/non-compliant.tfvars"
```

The `apply` target runs the same evaluation flow first:

- generate the OpenTofu plan
- export the plan to JSON
- evaluate the plan with OPA
- write `application/iac/opa-decision.json`
- check whether `allow` is `true`

**Output**

```text
tofu fmt -recursive application/iac modules
tofu -chdir=application/iac validate
Success! The configuration is valid.
tofu -chdir=application/iac plan -refresh=false -var-file=tfvars/non-compliant.tfvars -out=customer-documents.tfplan
```

The same `apply` target starts by running the normal OpenTofu checks and creating a saved plan.

Snippet 2 — OpenTofu accepts the configuration

**Output**

```text
Plan: 3 to add, 0 to change, 0 to destroy.
Saved the plan to: customer-documents.tfplan
```

The plan is technically valid, and OpenTofu is able to produce the plan file.

This is the gap the OPA gate is meant to close. The plan is valid IaC, but it is not compliant IaC.

Snippet 3 — Export the plan and evaluate it with OPA

**Command**

```bash
tofu -chdir=application/iac show -json customer-documents.tfplan > application/iac/customer-documents.tfplan.json
opa eval --data opa/tofu-plan-policies --input application/iac/customer-documents.tfplan.json --format raw 'json.marshal(data.terraform.compliance.s3.decision)' > application/iac/opa-decision.json
jq . application/iac/opa-decision.json
```

**Output**

```json
{
  "allow": false,
  "violations": [
    {
      "message": "S3 buckets must block all forms of public access.",
      "policy_id": "AWS-S3-001",
      "remediation": "Create an aws_s3_bucket_public_access_block in the same module and set block_public_acls, block_public_policy, ignore_public_acls, and restrict_public_buckets to true.",
      "resource": "module.customer_documents.aws_s3_bucket.this",
      "severity": "high"
    },
    {
      "message": "S3 buckets must deny non-SSL requests.",
      "policy_id": "AWS-S3-004",
      "remediation": "Attach an aws_s3_bucket_policy with a Deny statement where the condition Bool aws:SecureTransport is false.",
      "resource": "module.customer_documents.aws_s3_bucket.this",
      "severity": "high"
    },
    {
      "message": "S3 buckets must have versioning enabled.",
      "policy_id": "AWS-S3-002",
      "remediation": "Enable S3 bucket versioning for the bucket, either directly on aws_s3_bucket or with aws_s3_bucket_versioning.",
      "resource": "module.customer_documents.aws_s3_bucket.this",
      "severity": "high"
    },
    {
      "message": "S3 buckets must use SSE-KMS with a customer managed KMS key.",
      "policy_id": "AWS-S3-003",
      "remediation": "Configure S3 default encryption with sse_algorithm set to aws:kms or aws:kms:dsse and kms_master_key_id set to a customer managed KMS key.",
      "resource": "module.customer_documents.aws_s3_bucket.this",
      "severity": "critical"
    }
  ]
}
```

The decision contains `allow: false` because OPA found four S3 compliance violations:

- public access is not fully blocked
- non-SSL transport is not denied
- versioning is not enabled
- encryption does not use SSE-KMS with a customer managed key

Snippet 4 — Enforce the OPA decision

**Command**

```bash
jq -e '.allow == true' application/iac/opa-decision.json > /dev/null
```

**Output**

```text
make: *** [Makefile:45: opa-check] Error 1
```

Because `allow` is `false`, Make stops at `opa-check`. The important detail is that `tofu apply` is never executed.

### Compliant Plan

The final part of the demo shows the successful path. After seeing how OPA reports and blocks a non-compliant plan, we run the same workflow with a variable file that enables the required S3 controls.

The input file is `tfvars/compliant.tfvars`, which enables:

- full S3 public access blocking
- S3 versioning
- SSE-KMS encryption with a customer managed key
- a bucket policy that denies non-SSL requests

The following snippets show the important parts of the successful execution.

Snippet 1 — Run the gated apply target

**Command**

```bash
make apply TFVARS="tfvars/compliant.tfvars"
```

**Output**

```text
tofu fmt -recursive application/iac modules
tofu -chdir=application/iac validate
Success! The configuration is valid.
tofu -chdir=application/iac plan -refresh=false -var-file=tfvars/compliant.tfvars -out=customer-documents.tfplan
```

The workflow starts the same way: format, validate, and create a saved plan.

Snippet 2 — Verify the relevant controls in the plan output

**Output**

```text
  # module.customer_documents.aws_s3_bucket_policy.deny_insecure_transport[0] will be created
  + resource "aws_s3_bucket_policy" "deny_insecure_transport" {
      + policy = jsonencode(
            {
              + Statement = [
                  + {
                      + Action    = "s3:*"
                      + Condition = {
                          + Bool = {
                              + "aws:SecureTransport" = "false"
                            }
                        }
                      + Effect    = "Deny"
                    },
                ]
            }
        )
    }

  # module.customer_documents.aws_s3_bucket_public_access_block.this will be created
  + resource "aws_s3_bucket_public_access_block" "this" {
      + block_public_acls       = true
      + block_public_policy     = true
      + ignore_public_acls      = true
      + restrict_public_buckets = true
    }

  # module.customer_documents.aws_s3_bucket_server_side_encryption_configuration.this[0] will be created
  + resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
      + rule {
          + bucket_key_enabled = true

          + apply_server_side_encryption_by_default {
              + kms_master_key_id = "arn:aws:kms:eu-central-1:000000000000:key/customer-documents-lab"
              + sse_algorithm     = "aws:kms"
            }
        }
    }

  # module.customer_documents.aws_s3_bucket_versioning.this[0] will be created
  + resource "aws_s3_bucket_versioning" "this" {
      + versioning_configuration {
          + status = "Enabled"
        }
    }
```

This snippet is the relevant evidence that the plan contains the required S3 controls: the SSL deny policy, public access block, SSE-KMS configuration, and versioning.

Snippet 3 — OpenTofu creates the saved plan

**Output**

```text
Plan: 5 to add, 0 to change, 0 to destroy.
Saved the plan to: customer-documents.tfplan
```

OpenTofu creates a saved plan containing five resources: the bucket and the four compliance controls.

Snippet 4 — Export the plan and evaluate it with OPA

**Command**

```bash
tofu -chdir=application/iac show -json customer-documents.tfplan > application/iac/customer-documents.tfplan.json
opa eval --data opa/tofu-plan-policies --input application/iac/customer-documents.tfplan.json --format raw 'json.marshal(data.terraform.compliance.s3.decision)' > application/iac/opa-decision.json
jq . application/iac/opa-decision.json
```

**Output**

```json
{
  "allow": true,
  "violations": []
}
```

In this decision:

- `violations` is empty, so there are no policy findings to report.
- `allow` is `true`, so `opa-check` succeeds and Make can continue.

Snippet 5 — Enforce the OPA decision

**Command**

```bash
jq -e '.allow == true' application/iac/opa-decision.json > /dev/null
```

**Output**

```text
tofu -chdir=application/iac apply customer-documents.tfplan
```

After the OPA check passes, the Makefile runs `tofu apply` against the saved binary plan.

Snippet 6 — LocalStack apply result

**Output**

```text
module.customer_documents.aws_s3_bucket.this: Creating...
module.customer_documents.aws_s3_bucket.this: Creation complete after 0s [id=customer-document-processing-lab]
module.customer_documents.aws_s3_bucket_public_access_block.this: Creating...
module.customer_documents.aws_s3_bucket_policy.deny_insecure_transport[0]: Creating...
module.customer_documents.aws_s3_bucket_versioning.this[0]: Creating...
module.customer_documents.aws_s3_bucket_server_side_encryption_configuration.this[0]: Creating...
module.customer_documents.aws_s3_bucket_policy.deny_insecure_transport[0]: Creation complete after 0s [id=customer-document-processing-lab]
module.customer_documents.aws_s3_bucket_server_side_encryption_configuration.this[0]: Creation complete after 0s [id=customer-document-processing-lab]
module.customer_documents.aws_s3_bucket_public_access_block.this: Creation complete after 0s [id=customer-document-processing-lab]
module.customer_documents.aws_s3_bucket_versioning.this[0]: Creation complete after 1s [id=customer-document-processing-lab]

Apply complete! Resources: 5 added, 0 changed, 0 destroyed.

Outputs:

customer_documents_bucket_arn = "arn:aws:s3:::customer-document-processing-lab"
```

That is the key behavior of the gate. OPA evaluates the JSON exported from the saved plan, and OpenTofu applies that same saved plan only when the decision allows it.

## Design Choices for an IaC Compliance Gate

The lab shows the mechanics: generate an OpenTofu plan, export it to JSON, evaluate it with OPA, and use the decision to either report findings or block apply.

In a real engineering organization, the value of this pattern depends on a few design choices: where the policies live, who maintains them, and where the gate runs.

### Where Policies Should Live

For a small team or a lab, keeping the OPA policies in the same repository as the IaC code is reasonable. It keeps the workflow simple and makes the policy logic easy to inspect while developing the infrastructure.

In a larger organization, I would usually separate the policy code from the application IaC code:

- application and platform teams own the root modules, reusable modules, and deployment workflow
- security, governance, or platform governance teams own the policy repository
- CI pipelines consume the policy rules as a versioned artifact or pinned repository reference

This separation avoids copying policy logic across many IaC repositories. It also makes policy changes reviewable and reusable without requiring every application team to manually update their own compliance rules.

### Who Should Maintain the Policies

Policy ownership should reflect the difference between compliance intent and infrastructure implementation.

- Security or governance teams define the control intent: for example, customer document buckets must block public access, use versioning, use customer-managed KMS encryption, and deny non-SSL requests.
- Platform teams translate that intent into reusable infrastructure patterns and CI/CD integration.
- Application teams consume the modules, review the policy feedback, and fix non-compliant configuration before it reaches the cloud environment.

The important point is that policy maintenance should not become detached from engineering reality. A policy that cannot be understood, tested, or remediated by engineers will eventually be bypassed or ignored.

### Where the Gate Should Run

The same OPA policy can be useful at multiple stages, but each stage has a different purpose.

- Local execution gives engineers fast feedback before opening a pull request.
- CI execution blocks non-compliant pull requests before they are merged.
- CD or pre-apply execution ensures the exact saved plan being applied was evaluated.
- Shared pipeline templates reduce the chance that teams skip the compliance step.

The strongest control is the pre-apply gate: evaluate the saved plan, store the OPA decision, and apply only if the decision allows it. That is the pattern demonstrated in the lab.

### My Preferred Baseline

For root modules, I would standardize on plan-based evaluation:

- generate a saved OpenTofu plan
- export that plan to JSON
- evaluate the JSON with OPA
- return one decision document containing `violations` and `allow`
- show `violations` to engineers
- use `allow` to block or permit apply

This keeps the policy decision close to what OpenTofu is actually going to do. It also avoids treating policy checks as a separate static scan that may not reflect the final evaluated configuration.

HashiCorp’s [`tfpolicy`](https://developer.hashicorp.com/terraform/policy) is worth knowing about here. It targets a similar problem, but it is Terraform-specific and HCL-based. I chose OPA for this lab because it is a general policy engine. The same engine can be used for IaC checks, Kubernetes admission control, CI/CD decisions, and other platform guardrails.

Runtime cloud scanners are still useful, but they should not be the first place where basic IaC compliance issues are discovered. The earlier gate should catch obvious violations before they become deployed infrastructure.

## Conclusion

The lab demonstrates a simple but important pattern: evaluate infrastructure intent before infrastructure is created.

The flow is straightforward:

1. OpenTofu creates a saved plan.
2. The saved plan is exported to JSON.
3. OPA evaluates the plan JSON.
4. OPA returns a decision document.
5. Engineers see the policy violations.
6. `tofu apply` runs only when the decision allows it.

That last point is the key. OPA is not only being used as a reporting tool. It becomes part of the deployment control path.

In the non-compliant scenario, OpenTofu was still able to generate a valid plan. The issue was not syntax or provider configuration. The issue was that the planned S3 bucket did not meet the required security controls. OPA detected that and returned `allow: false`, which stopped the apply before any infrastructure was created.

In the compliant scenario, the same workflow evaluated the saved plan, returned `allow: true`, and allowed OpenTofu to apply that exact plan.

The lab focused on S3 to keep the example small, but the same pattern applies to other infrastructure controls:

- security group ingress/egress rules
- load balancer TLS configuration
- IAM permissions and privilege boundaries
- database encryption and backup settings
- Kubernetes security context requirements

Runtime scanners are still necessary. They detect drift, manual changes, service-level misconfiguration, and issues that only appear after deployment. But they should not be the first line of defense for violations that are already visible in the IaC plan.

OPA gives teams a way to move those checks earlier. The result is a cleaner workflow: engineers get feedback before deployment, CI can block unsafe changes before merge, and the apply path can enforce compliance against the exact plan that will be deployed.
