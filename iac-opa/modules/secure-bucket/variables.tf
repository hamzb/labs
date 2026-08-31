variable "bucket_name" {
  description = "Name of the S3 bucket."
  type        = string
}

variable "tags" {
  description = "Tags to apply to the S3 bucket."
  type        = map(string)
  default     = {}
}

variable "public_access_block" {
  description = "Public access block settings for the S3 bucket."
  type = object({
    block_public_acls       = bool
    block_public_policy     = bool
    ignore_public_acls      = bool
    restrict_public_buckets = bool
  })
  default = {
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }
}

variable "versioning_enabled" {
  description = "Whether S3 bucket versioning should be enabled."
  type        = bool
  default     = true
}

variable "encryption" {
  description = "Default server-side encryption settings for the S3 bucket."
  type = object({
    enabled            = bool
    sse_algorithm      = string
    kms_key_id         = optional(string)
    bucket_key_enabled = optional(bool, true)
  })
  default = {
    enabled            = true
    sse_algorithm      = "aws:kms"
    kms_key_id         = "arn:aws:kms:eu-central-1:000000000000:key/customer-documents-lab"
    bucket_key_enabled = true
  }
}

variable "deny_insecure_transport" {
  description = "Whether to attach a bucket policy that denies non-SSL requests."
  type        = bool
  default     = true
}
