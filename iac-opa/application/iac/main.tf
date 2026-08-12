module "customer_documents" {
  source = "../../modules/secure-bucket"

  bucket_name = "customer-document-processing-lab"
  tags = {
    owner               = "document-platform"
    environment         = "local"
    data_classification = "confidential"
    managed_by          = "opentofu"
  }
}
