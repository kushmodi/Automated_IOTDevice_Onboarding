#!/bin/bash
 CMD_ARG=""
 echo "Installing Required Packages"
 echo ""
 sudo apt install -y jq
 echo "Configuring aws credentials"
 echo ""
 echo "Enter the AWS ACCESS KEY: "
 read access_key
 echo ""
 echo "Enter the AWS SECRET KEY: "
 read secret_key
 echo ""
 aws configure set aws_access_key_id $access_key
 aws configure set aws_secret_access_key $secret_key

 echo "Enter the AWS REGION: "
 read region
 echo ""
 aws ec2 describe-regions --all-regions | awk -F\" '/RegionName/{print $4}' | grep $region >/dev/null 2>&1
 if [[ $? -ne 0 ]] ; then
        echo "Region entered is not valid"
        echo ""
        exit 0
 fi

 echo "Enter the TENANT NAME:"
 read tenant_name
 echo ""

print_usage()
{
        echo "`basename $0` --cmd=commands"
        echo ""
        echo "commands:"
        echo "	configure_device		: Configure greengrass device with bucket and secrets"
        echo "	build_s3_bucket		        : Build only for S3 bucket with policy"
        echo "	build_secrets		        : Build only for secrets for tenents"
        echo " deploy_components        : Deploy components to IOT Device"
        echo "	--help			        : Prints this help"
}

####################
# list of functions

parse_args() {
	TEMP=`getopt --long "cmd:,help" -o cubplh  -- "$@"`
	eval set -- "$TEMP"

	# extract options and their arguments into variables.
	while true ; do
		case "$1" in
			--cmd)
				CMD_ARG=$2
				shift 2
				;;
			--help)
				print_usage
				shift 1
				exit 0
				;;
			--)
				shift
				break
				;;
			*) echo "Invalid argument '$1'!"
				exit 1
				;;
		esac
	done
}


create_credentials_json() {

 echo "Enter the username: "
 read username
 echo ""

 echo "Enter the password: "
 read password
 echo ""


 echo "creating json for credentials"
 cat <<EOF | sudo tee credentials.json
{
  "username": "$username",
  "password": "$password"
}
EOF
}

create_policy_json() {
cat <<EOF | sudo tee policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Deny",
            "Principal": "*",
            "Action": "*",
            "Resource": [
                "arn:aws:s3:::bucket_name",
                "arn:aws:s3:::bucket_name/*"
            ],
            "Condition": {
                "StringNotEquals": {
                    "aws:PrincipalAccount": "831490426837"
                }
            }
        },
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::831490426837:root"
            },
            "Action": [
                "s3:GetObject",
                "s3:PutObject"
            ],
            "Resource": [
                "arn:aws:s3:::bucket_name",
                "arn:aws:s3:::bucket_name/*"
            ]
        }
    ]
}
EOF

}

create_s3_bucket() {
 echo "Creating s3 bucket for tenant"
 echo ""
 aws s3 ls | grep $tenant_name-elsa >/dev/null 2>&1
 if [[ $? -ne 0 ]] ; then
 aws s3api create-bucket --bucket $tenant_name-elsa --create-bucket-configuration LocationConstraint=$region --acl private
 else
        echo "This bucket name already exist"
        echo ""
        continue
 fi
 sed -i "s/bucket_name/$(echo $tenant_name-elsa)/g" policy.json
 echo "Creating s3 bucket policy for tenant"
 echo ""
 aws s3api put-bucket-policy --bucket $tenant_name-elsa --policy file://policy.json --region $region
}

create_tenent_secrets() {
 echo "creating KMS for tenent secrets"
 echo ""
 KMS_Key=$(aws kms create-key \
   --key-spec SYMMETRIC_DEFAULT \
   --key-usage ENCRYPT_DECRYPT \
   --region $region | awk -F\" '/KeyId/{print $4}')

 echo "creating KMS alias"
 echo ""
 aws kms create-alias \
    --alias-name alias/$tenant_name-kms \
    --target-key-id $KMS_Key \
    --region $region

 echo "Creating secrets for tenant"
 echo ""
 aws secretsmanager list-secrets | grep $tenant_name-secrets >/dev/null 2>&1
 if [[ $? -ne 0 ]] ; then
 aws secretsmanager create-secret --name $tenant_name-secrets --secret-string file://credentials.json --kms-key-id $KMS_Key
 else
        echo "This secret name already exist"
        echo ""
        continue
 fi
}

greengrass_provisioning() {
 echo "Automatic provisioning of greengrass core software"
 echo ""
 sudo -E java -Droot="/greengrass/v2" -Dlog.store=FILE \
  -jar ./GreengrassInstaller/lib/Greengrass.jar \
  --aws-region $region \
  --thing-name $tenant_name-thing \
  --thing-group-name $tenant_name-thingGroup \
  --thing-policy-name $tenant_name-thingPolicy \
  --tes-role-name GreengrassV2TokenExchangeRole \
  --tes-role-alias-name GreengrassCoreTokenExchangeRoleAlias \
  --component-default-user ggc_user:ggc_group \
  --provision true \
  --setup-system-service true
}

deploy_components() {
 secret_arn=$(aws secretsmanager list-secrets --filters Key=name,Values=$tenant_name-secrets --query SecretList[].ARN --output text)
 thinggroup_arn=$(aws iot list-thing-groups --name-prefix-filter $tenant_name-thingGroup --query thingGroups[].groupArn --output text)
 echo " List of deployment you wish to copy for deployment"
 echo ""
 aws greengrassv2 list-deployments |jq -r '.deployments[] |  {Deployment_Name : .deploymentName , Deployment_Id : .deploymentId }'

 echo "enter the deployment id from above to copy deployment to new target: "
 read deployment_id
 echo ""
 aws greengrassv2 get-deployment --deployment-id $deployment_id --output json > deployment.json
 jq 'del(.revisionId, .deploymentId, .iotJobId, .iotJobArn, .deploymentStatus, .creationTimestamp, .isLatestForTarget, .tags)' deployment.json > tmp.json && mv tmp.json deployment.json
 jq --arg thinggroup_arn "$thinggroup_arn" --arg tenant_name "$tenant_name" '.targetArn=$thinggroup_arn | .deploymentName=$tenant_name' deployment.json > tmp.json && mv tmp.json deployment.json
 awk '/aws.greengrass.SecretManager/{p=1}p&&/"merge"/{gsub(/[^[:alnum:]\{\}":]/,"");gsub(/"arn":"[^"]+"/,"\"arn\":\"""\"");p=0}1' deployment.json > tmp.json && mv tmp.json deployment.json
 sed -i 's#"merge":"{"cloudSecrets":{"arn":""}}"#"merge": "{\\"cloudSecrets\\":[{\\"arn\\":\\"'"$secret_arn"'\\"}]}"#g' deployment.json
 jq . deployment.json > tmp.json && mv tmp.json deployment.json
 echo "creating deployment for $tenant_name"
 echo ""
aws greengrassv2 create-deployment --cli-input-json file://deployment.json

}

# end of functions
####################

####################
# execution
parse_args $@

case ${CMD_ARG} in
	"configure_device")
		echo "Configuring greengrass device"
                echo ""
                create_policy_json
                create_credentials_json
                create_s3_bucket
                create_tenent_secrets
                greengrass_provisioning
                deploy_components
		;;
	"build_s3_bucket")
		echo "Creating S3 Bucket and bucket policy only"
                echo ""
                install_pre-requisites
                configure_aws_cli
                create_s3_bucket
		;;
	"build_secrets")
		echo "creating KMS key and tenent secrets only"
                echo ""
		install_pre-requisites
                configure_aws_cli
                create_tenent_secrets
		;;
  "deploy_components")
  		echo "Deploy components to IOT Device"
                  echo ""
                  deploy_components
  	;;
	*)
		echo "Invalid cmd '${CMD_ARG}'!"
                echo ""
		print_usage
		exit 1
		;;
esac
exit 0