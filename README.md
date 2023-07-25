# Pollapp

A basic serverless Slack polling app with 
* [Slack Bolt for Python](https://slack.dev/bolt-python),
* [API Gateway](https://aws.amazon.com/api-gateway/),
* [DynamoDB](https://aws.amazon.com/dynamodb/), 
* [Lambda](https://aws.amazon.com/lambda/) and 
* [Terraform](https://www.terraform.io/).

## Prerequisites
Make sure that you have
* a [Slack workspace](https://slack.com/create) set up
* access to an [AWS](https://aws.amazon.com/free) account
* already provisioned a hosted zone with [Route53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/Welcome.html) in the above account
* installed and configured 
    * [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
    * [Terraform](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli)
    * [Docker](https://docs.docker.com/engine/install/) 

## Provision AWS Resources
We use Terraform to create our infrastructure
* update `terraform.tfvars`
    * `aws_region` with our desired AWS target region
    * `aws_profile` with the AWS profile we're using
    * `zone_name` with the name of an already existing hosted zone, where the app's record and certificate validation records will be created and
* run both `terraform init` and `terraform apply`.

You may have to wait for the DNS record to propagate for a little while, use _nslookup_ by running the output of the `terraform output -raw check_url_command` command.

## Installing the Slack App to your Workspace
Install the app to a Slack workspace using an [app manifest](https://api.slack.com/reference/manifests) file:
* go to https://api.slack.com/apps
* click on _Create New App_
* click on _From an app manifest_ 
* select your desired workspace and click on _Next_
* run `terraform output -raw app_manifest` in the project's root folder and copy the output
* select _YAML_, paste above's app manifest and click on _Next_
* click on _Create_
* navigate to _Settings > Basic Information_, click on _Install to Workspace_ in the _Install your app_ section and confirm by clicking on _Allow_ in the following dialog

Next put the app's _Signin Secret_ and _Bot User OAuth Token_ into the secret so that the Lambda function can authenticate with Slack:
* go to https://api.slack.com/apps
* click on _Your Apps_ and select our app
* navigate to _Settings > Basic Information_ and copy the _Signin Secret_'s value
* navigate to _Features > OAuth & Permissions_ and copy the _Bot User OAuth Token_'s value
* run `terraform output -raw set_slack_secret_command`, copy the output command, replace `<SLACK_BOT_TOKEN>` and `<SLACK_SIGNIN_SECRET>` with above's _Signin Secret_ and _Bot User OAuth Token_ so that the result looks like this
```
aws secretsmanager put-secret-value \
    --secret-id pollapp_slack_secrets \
    --secret-string "{\"SLACK_BOT_TOKEN\":\"<SLACK_BOT_TOKEN>\",\"SLACK_SIGNIN_SECRET\":\"<SLACK_SIGNIN_SECRET>\"}\" \
    --region us-east-1
    --profile default
```
* run the above command
* navigate to _Features > App Manifest_ where you may find an info box stating that the _URL isn't verified_ and click _Click here to verify_

Finally test that everything is working by initiating a poll with something like `/poll "My polling app works" "Yes" "No"` in your Slack workspace.


## Cleanup
To delete your Slack app
* go to https://api.slack.com/apps
* click on _Your Apps_ and select our app
* navigate to _Settings > Basic Information_ and click on _Delete App_

To delete all AWS resources
* run `terraform destroy`