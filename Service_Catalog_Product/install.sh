#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Script to install the CloudFormation templates relating to the Service Catalog product
# for sharing an AWS Managed Microsoft AD directory to requesting accounts.

set -eu

function get_stack_output() {
  local stack="$1"
  local output="$2"

  value=$(aws --output text cloudformation describe-stacks --stack-name $stack --query "Stacks[].Outputs[?OutputKey=='"$output"'].OutputValue[]")

  if [ -z "$value" ]; then
    >&2 echo "Could not get the Output $output from stack $stack"
    return 1
  fi
  echo $value
}

function get_existing_stack_value_or_default(){
  local stack="$1"
  local parameter="$2"
  local default="$3"
  value=$( aws --output text cloudformation describe-stacks --stack-name $stack --query "Stacks[].Parameters[?ParameterKey==\`$parameter\`]".ParameterValue 2>/dev/null )
  if [ -z "$value" ]; then
    echo $default
  else
    echo $value
  fi
}

sc_stack_name="Managed-AD-Sharing-Service-Catalog"
hub_stack_name="Managed-AD-Sharing-Hub"
bucket_stack_name="Managed-AD-Sharing-SC-Bucket"
sc_product_template_filename="Managed-AD-Sharing-Product.yaml"

# Managed AD directory ID (blank means it'd import the managed ad template export)
read -p "If you used the provided AWS Managed Microsoft AD template, press enter here to keep this blank. Otherwise, enter the directory ID: " managed_ad_id

# Get company/org name
provider_name=$(get_existing_stack_value_or_default $sc_stack_name "ProviderName" "TestOrg")
read -p "Enter a short organization/company name to use as the Service Catalog provider name, no spaces [$provider_name]: " user_input
test ! -z "$user_input" && provider_name="$user_input"

# Get service catalog product version
sc_product_version=$(get_existing_stack_value_or_default $sc_stack_name "ProductVersion" "v1")
read -p "Enter the product version with no spaces (increment this if you updated the Managed-AD-Sharing-Product.yaml file) [$sc_product_version]: " user_input
test ! -z "$user_input" && sc_product_version="$user_input"

# Principal type
sc_principal_type=$(get_existing_stack_value_or_default $sc_stack_name "PrincipalType" "IAM_Identity_Center_Permission_Set")
read -p "Type of principal that will use the product, IAM_Identity_Center_Permission_Set or IAM_role_name [$sc_principal_type]: " user_input
test ! -z "$user_input" && sc_principal_type="$user_input"

# If the principal type is IAM Identity Center, we need the IAM Identity Center home region:
if [[ "$sc_principal_type" == "IAM_Identity_Center_Permission_Set" ]]; then
  sc_iam_identity_center_region=$(get_existing_stack_value_or_default $sc_stack_name "IAMIdentityCenterRegion" "$AWS_DEFAULT_REGION")
  read -p "IAM Identity Center home region [$sc_iam_identity_center_region]: " user_input
  test ! -z "$user_input" && sc_iam_identity_center_region="$user_input"
fi

# Principal name 01
sc_principal_name_01=$(get_existing_stack_value_or_default $sc_stack_name "PrincipalName01" "AWSAdministratorAccess")
read -p "IAM role name or permission set that can access the Service Catalog product [$sc_principal_name_01]: " user_input
test ! -z "$user_input" && sc_principal_name_01="$user_input"

# Principal name 02
sc_principal_name_02=$(get_existing_stack_value_or_default $sc_stack_name "PrincipalName02" "")
read -p "(Optional, leave blank to skip) Additional IAM role name or permission set that can access the Service Catalog product [$sc_principal_name_02]: " user_input
test ! -z "$user_input" && sc_principal_name_02="$user_input"

echo "Make sure you are logged into the AWS account and region hosting the AWS Managed Microsoft AD directory, and press enter to start the installation..."
read x


# Create the Managed AD sharing hub template (SNS topic):
organization_id=$(aws --output text organizations describe-organization --query Organization.Id)
sam deploy \
  --template-file 01_Managed_AD_sharing_hub/Managed-AD-Sharing-Hub.yaml \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    ParameterKey=OrgID,ParameterValue=$organization_id \
    ParameterKey=ManagedADDirectoryId,ParameterValue=$managed_ad_id \
  --capabilities CAPABILITY_NAMED_IAM \
  --stack-name $hub_stack_name

sns_topic_arn=$(get_stack_output $hub_stack_name SNSTopicArn)

# Create bucket that will contain the product template:

sam deploy \
  --template-file 02_Service_Catalog_Product_template_bucket/Managed-AD-Sharing-SC-Bucket.yaml \
  --no-fail-on-empty-changeset \
  --stack-name $bucket_stack_name
bucket=$(get_stack_output $bucket_stack_name BucketName)
s3_url=$(get_stack_output $bucket_stack_name BucketURL)


# Replace placeholders in the template, and upload to bucket:
account_id=$(aws --output text sts get-caller-identity --query Account)
resolver_rule_name="AWS-Managed-Microsoft-AD-domain"
resolver_id=$(aws --output text route53resolver list-resolver-rules --query "ResolverRules[?Name==\`$resolver_rule_name\`]".Id)
sed \
  -e "s/012345678901/$account_id/g" \
  -e "s/rslvr-rr-REPLACEME/$resolver_id/g" \
  02_Service_Catalog_Product_template_bucket/bucket_contents/${sc_product_template_filename} \
  | aws s3 cp - s3://${bucket}/${sc_product_template_filename}


# Create the Service Catalog product:
sam deploy \
  --template-file 03_Service_Catalog_Portfolio/Managed-AD-Sharing-ServiceCatalog.yaml \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    ParameterKey=ProviderName,ParameterValue="$provider_name" \
    ParameterKey=ProductVersion,ParameterValue=$sc_product_version \
    ParameterKey=TemplateURL,ParameterValue=${s3_url}/${sc_product_template_filename} \
    ParameterKey=PrincipalType,ParameterValue=$sc_principal_type \
    ParameterKey=PrincipalName01,ParameterValue=$sc_principal_name_01 \
    ParameterKey=PrincipalName02,ParameterValue=$sc_principal_name_02 \
    ParameterKey=IAMIdentityCenterRegion,ParameterValue=$sc_iam_identity_center_region \
  --capabilities CAPABILITY_NAMED_IAM \
  --stack-name $sc_stack_name

echo "Stack creation finished successfully."

# Sharing options, via the CLI until this is closed: https://github.com/aws-cloudformation/cloudformation-coverage-roadmap/issues/594
read -p "Enter 'org' if you want to share the portfolio to the entire Organization. Enter 'account' if you want to share with a specific account. Otherwise, enter 'n' and use the AWS Management Console to share to a specific OU. [org/account/n]: " sharing_method
portfolio_id=$(get_stack_output $sc_stack_name PortfolioID)
if [[ "$sharing_method" == "org" ]]; then
  # Share the portfolio with the org:
  aws servicecatalog create-portfolio-share \
    --portfolio-id $portfolio_id \
    --share-principals \
    --organization-node Type=ORGANIZATION,Value=$organization_id
elif [[ "$sharing_method" == "account" ]]; then
  # Share the portfolio with given account:
  read -p "Enter the account ID to share with: " account_id
  aws servicecatalog create-portfolio-share \
    --portfolio-id $portfolio_id \
    --share-principals \
    --organization-node Type=ACCOUNT,Value=$account_id
fi

echo "Done!"

