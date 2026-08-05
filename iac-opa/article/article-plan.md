# Article Plan: Preventing Cloud Compliance Violations with an OPA-Based IaC Compliance Gate

## Central argument

Without early compliance checks, insecure and non-compliant IaC configurations can propagate into cloud environments and remain undetected until live-resource scanners find them. An OPA-based IaC compliance gate evaluates proposed infrastructure before deployment, significantly reducing these occurrences while complementing runtime compliance scanning.

## 1. The gap between IaC changes and runtime compliance

### Purpose

Establish that organizations often discover insecure configurations only after deployment, when CSPM tools, AWS Config, Security Hub, or other live-resource scanners detect them.

By that point:

- The non-compliant resource already exists.
- Sensitive data or services may already be exposed.
- Remediation can disrupt running workloads.
- The same pattern may have propagated through reusable modules and multiple environments.
- Security teams repeatedly report issues that could have been rejected before deployment.

Introduce the article's thesis:

> Runtime scanners remain necessary, but they should not be the first place an organization discovers predictable IaC compliance violations.

### Reader value

The reader understands IaC policy checks as preventive controls that complement, rather than replace, runtime detection.

## 2. The enterprise application and its compliance risks

Introduce a Customer Document Processing Service that uses:

- An S3 bucket for confidential customer documents.
- A KMS key for encryption.
- An SQS queue for processing jobs.
- An IAM role for the processing worker.
- A security group controlling worker connectivity.
- Organizational resource tags.

Show how small IaC changes could introduce:

- Unencrypted confidential storage.
- Public administrative access.
- Missing ownership or data-classification metadata.

### Purpose

Connect abstract compliance failures to a realistic application and its security requirements.

### Reader value

The reader sees the security and operational consequences behind each policy rather than encountering disconnected policy examples.

## 3. Designing the IaC compliance gate

Present the central architecture:

```text
IaC change
    |
    v
Terraform/OpenTofu plan
    |
    v
OPA compliance decision
  /       \
reject    approved plan
              |
              v
           cloud API
```

Explain that the gate evaluates the intended infrastructure before it reaches LocalStack or AWS.

### Purpose

Define where prevention occurs in the deployment lifecycle and distinguish policy evaluation from policy enforcement.

### Reader value

The reader understands the roles of Terraform/OpenTofu, OPA, the enforcement script, CI, and LocalStack.

## 4. Translating cloud compliance requirements into Rego

Implement policies for:

- S3 encryption and public-access protection.
- Security-group exposure.
- Required ownership and data-classification tags.

Return structured violations containing:

- A policy identifier.
- The affected resource address.
- Severity.
- An explanation.
- Remediation guidance.

### Purpose

Show how operational compliance requirements become executable and maintainable policy decisions.

### Reader value

The reader gains reusable Rego patterns instead of isolated boolean checks.

## 5. Evaluating the planned infrastructure

Generate a saved Terraform/OpenTofu plan, convert it to JSON, and evaluate it with OPA.

Compare two scenarios:

- A non-compliant plan that is rejected before deployment.
- A compliant plan that is approved and applied to LocalStack.

Briefly explain the relevant plan structure, including resource traversal, child modules, and unknown values.

### Purpose

Prove that the gate can prevent a syntactically valid but non-compliant deployment.

### Reader value

The reader gets a concrete and reproducible end-to-end implementation.

## 6. Catching violations earlier in reusable modules

Introduce raw HCL scans as an additional layer for reusable module repositories.

Use source-level policies to detect:

- Unsafe defaults.
- Hard-coded public network ranges.
- Missing security resources.
- Module interfaces that do not support required tags or encryption.

Clarify that raw HCL scanning cannot resolve every variable, expression, or consumer input. The composed root plan therefore remains the authoritative pre-deployment check.

### Purpose

Show how obvious non-compliant patterns can be stopped before shared modules distribute them to multiple applications.

### Reader value

The reader understands where raw HCL scanning adds value and why it does not replace plan-based enforcement.

## 7. Making the compliance gate mandatory in CI

Implement the following pipeline:

```text
validate -> plan -> plan JSON -> OPA -> reject or apply
```

Show how CI:

- Fails when OPA reports compliance violations.
- Reports clear violations to the application team.
- Applies only the saved plan that passed evaluation.
- Consumes separately owned and versioned compliance policies.

### Purpose

Turn policy evaluation from an optional local command into a consistent deployment control.

### Reader value

The reader understands how to operationalize the compliance gate across application, platform, and security teams.

## 8. Preventive and detective controls working together

Conclude that IaC compliance gates significantly reduce predictable misconfigurations reaching cloud environments, while runtime scanners remain necessary to detect:

- Configuration drift.
- Manually created resources.
- Values unavailable during planning.
- Runtime conditions that IaC cannot represent.

Summarize the relationship:

```text
IaC policy gate -> cloud deployment -> runtime compliance scanning
   preventive                              detective
```

### Purpose

Position the IaC compliance gate accurately within a broader cloud-security approach.

### Reader value

The reader leaves with a practical layered model rather than the false impression that plan-time policies replace runtime controls.
