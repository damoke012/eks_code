# USX-QA (527101283767) — source region where the state bucket + DynamoDB lock live.
# CRR replica goes to us-west-2 for regional isolation.
#
# Both providers use SSO assume-role via AWS_PROFILE=usx-qa (or the profile you have
# configured for account 527101283767).

provider "aws" {
  alias  = "source"
  region = "us-east-2"

  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Purpose     = "tf-state-backend"
      Environment = "qa"
      Cluster     = "op-usxpress-qa"
      Ticket      = "INFRA-1562"
    }
  }
}

provider "aws" {
  alias  = "destination"
  region = "us-west-2"

  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Purpose     = "tf-state-backend-crr-replica"
      Environment = "qa"
      Cluster     = "op-usxpress-qa"
      Ticket      = "INFRA-1562"
    }
  }
}
