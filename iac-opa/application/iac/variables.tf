variable "bucket_public_access_block" {
  description = "Public access block settings for the customer documents bucket."
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

variable "bucket_versioning_enabled" {
  description = "Whether versioning is enabled for the customer documents bucket."
  type        = bool
  default     = true
}

variable "bucket_encryption" {
  description = "Default server-side encryption settings for the customer documents bucket."
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

variable "bucket_deny_insecure_transport" {
  description = "Whether the customer documents bucket denies non-SSL requests."
  type        = bool
  default     = true
}
