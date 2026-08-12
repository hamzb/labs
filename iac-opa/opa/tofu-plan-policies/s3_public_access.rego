package terraform.compliance.s3

import rego.v1

# AWS-S3-001
# Confidential S3 buckets must have an S3 public-access-block resource in the
# same module, with every public-access protection enabled.
violations contains violation if {
	bucket := confidential_s3_buckets[_]
	not has_complete_public_access_block(bucket)

	violation := {
		"policy_id": "AWS-S3-001",
		"severity": "high",
		"resource": bucket.address,
		"message": "Confidential S3 buckets must block all forms of public access.",
		"remediation": "Create an aws_s3_bucket_public_access_block in the same module and set block_public_acls, block_public_policy, ignore_public_acls, and restrict_public_buckets to true.",
	}
}

has_complete_public_access_block(bucket) if {
	access_block := managed_resources[_]
	access_block.type == "aws_s3_bucket_public_access_block"
	module_address(access_block.address) == module_address(bucket.address)

	values := access_block.values
	values.block_public_acls == true
	values.block_public_policy == true
	values.ignore_public_acls == true
	values.restrict_public_buckets == true
}
