# Introduction
At [ventx](https://www.ventx.de/), we like to keep ourselves busy with bite-sized exercises in between projects - this one is about building a serverless [Slack](https://slack.com/) app with
* [Slack Bolt for Python](https://slack.dev/bolt-python),
* [API Gateway](https://aws.amazon.com/api-gateway/),
* [DynamoDB](https://aws.amazon.com/dynamodb/), 
* [Lambda](https://aws.amazon.com/lambda/) and 
* [Terraform](https://www.terraform.io/).

Our app is a basic polling tool: users can initiate polls with either a [slash command](https://api.slack.com/interactivity/slash-commands) like `/poll "What do you want to eat today?" "Pizza" "Tacos" "Burger"` 
or with an [app_mention](https://api.slack.com/events/app_mention) (These come with the added benefit of playing nice with Slack's built in [reminder](https://slack.com/resources/using-slack/how-to-use-reminders-in-slack) feature.) like `@PollApp "Skip today's daily?" "Yes" "No"`. Users may then post their votes while the poll's results are visible to channel members.


## Prerequisites
Before we get started, make sure that you have:
* a [Slack workspace](https://slack.com/create) set up
* access to an [AWS](https://aws.amazon.com/free) account
* already provisioned a hosted zone with [Route53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/Welcome.html) in the above account
* installed and configured 
    * [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
    * [Terraform](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli)
    * [Docker](https://docs.docker.com/engine/install/) 
* checked out the code that is available on [Github](https://github.com/ventx/slack-pollapp)

## Slack App
Our app uses Slack Bolt _[a Python framework to build Slack apps in a flash with the latest platform features](https://github.com/slackapi/bolt-python)_ so that we do not have to bother with getting into the intricate details of how authentication with Slack or listening and responding to events really works.

The first thing we need to do is retrieve our app's _Signin Secret_ and _Bot User OAuth Token_ from a [Secrets Manager](https://docs.aws.amazon.com/secretsmanager) secret. (We'll get to where you can find these later.) Next is to go about setting up the [App](https://slack.dev/bolt-python/api-docs/slack_bolt/app/app.html) - making sure to set `process_before_response` as per the [documentation's advice](https://slack.dev/bolt-python/concepts#lazy-listeners) for FaaS (Function-as-a-Service) environments such as AWS Lambda - and register our
* slash command (for when our app is being invoked via a slash command), 
* event listener (in case the app is being invoked via `app_mention`) and 
* action listener (that is being called when a user clicks on a vote button).

Note that while we immediately acknowledge requests with `immediate_ack()`, we do not run business logic right away but process [lazily](https://slack.dev/bolt-python/concepts#lazy-listeners).


```python
# ...

def immediate_ack(ack):
    # immediately acknowledge request
    ack()

def init_poll(body, respond):
    # do something on slash command or app_mention

def on_vote(body, respond, action):
    # do something on vote action 

# instantiate app
app = App(
    token=slack_secrets['SLACK_BOT_TOKEN'],
    signing_secret=slack_secrets['SLACK_SIGNIN_SECRET'],
    process_before_response=True
)

# register listeners
app.command(command)(ack=immediate_ack, lazy=[init_poll])
app.event(app_mention)(ack=immediate_ack, lazy=[init_poll])
app.action(action_vote)(ack=immediate_ack, lazy=[on_vote])

# lambda handler
def handler(event, context):
    slack_handler = SlackRequestHandler(app=app)
    return slack_handler.handle(event, context)
```


When a user initiates a poll, we
* generate a unique `poll_id`, 
* initalize a corresponding `poll_data` object, that contains title, options and votes, 
* store both in our DynamoDB _poll_ table and 
* return an interactive message to the given channel using Slack's UI framework [Block Kit](https://api.slack.com/block-kit).

We use the vote button's _value_ attribute to hold both the poll's unique id and the respective option's index.

```python
# ...

def init_poll(body, respond, say, client):
    # parse the given command: "<TITLE>" "<OPTION_A>" "<OPTION_B>" ...
    command = re.findall('"([^"]*)"', body['text']
                         if 'command' in body else body['event']['text'])

    if not len(command) > 1:
        # respond with usage hint
        usage(body, respond, client)
    else:
        # create and persist poll-data
        item = {
            'id': str(uuid.uuid4()),
            'version': 0,
            'data': {
                'title': command[0],
                'options': list(map(lambda x: {'title': x, 'votes': []}, command[1:]))
            }
        }
        poll_table.put_item(Item=item)

        # respond with interactive poll message
        if 'response_url' in body:
            # slash-command response via respond/response_url
            respond(
                response_type='in_channel',
                blocks=get_poll_blocks(
                    poll_id=item['id'], 
                    poll_data=item['data'])
            )
        else:
            # app_mention response via say/chat.postMessage
            say(
                response_type='in_channel',
                blocks=get_poll_blocks(
                    poll_id=item['id'], 
                    poll_data=item['data'])
            )

def get_poll_blocks(poll_id: str, poll_data: dict):
    # message title
    blocks = [
        {
            'type': 'section',
            'text': {
                'type': 'mrkdwn',
                'text': f"*{poll_data['title']}*"
            }
        }
    ]
    for option_id, option in enumerate(poll_data['options']):
        blocks.append({
            # option title and votes
            'type': 'section',
            'text': {
                'type': 'mrkdwn',
                'text': f"{option_id + 1}. {option['title']}\n {', '.join(list(map(lambda x: '<@' + x + '>', option['votes'])))}"
            },
            # option vote button with number of votes
            'accessory': {
                'type': 'button',
                'text': {
                    'type': 'plain_text',
                    'text': f"Vote ({len(option['votes'])})"
                },
                'value': f"{option_id}_{poll_id}",  # option id and poll id
                'action_id': action_vote
            }
        })
    return blocks

# ...
```

Finally when a user votes, we
* extract the previously mentioned `poll_id` and `option_id`,
* fetch the respective item from our DynamoDB _poll_ table,
* update the `poll_data` object and update the above item to keep track the user's vote and 
* redraw the Slack message using blocks once again.

You may have picked up on a try-catch-block inside a for-loop: this is our attempt at preventing concurrency mess-ups using the [Optimistic locking with version number](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBMapper.OptimisticLocking.html) strategy.

> With optimistic locking, each item has an attribute that acts as a version number. If you retrieve an item from a table, the application records the version number of that item. You can update the item, but only if the version number on the server side has not changed. If there is a version mismatch, it means that someone else has modified the item before you did. The update attempt fails, because you have a stale version of the item. If this happens, you simply try again by retrieving the item and then trying to update it. Optimistic locking prevents you from accidentally overwriting changes that were made by others. It also prevents others from accidentally overwriting your changes.

Down below you can see this strategy in action:
For a maximum number of 3 attempts, we'll fetch the item from the table and perform the update if and only if the version we've obtained is still equal to the version of the item when the update is executed. If the put fails with `ConditionalCheckFailedException`, we retry - if it does not, we're good.

```python
# ...

def on_vote(body, respond, action):
     # extract option id and poll id from the action button's value attribute
    option_id = int(action['value'].split('_')[0])
    poll_id = action['value'].split('_')[1]

    for i in range(3):
        try:
            # fetch poll-data for the given poll id
            response = poll_table.get_item(
                TableName=poll_table_name,
                Key={
                    'id': poll_id
                }
            )
            if 'Item' in response:
                current_version = response['Item']['version']
                # update poll-data to reflect this vote
                poll_data = vote(
                    poll_data=response['Item']['data'],
                    user_id=body['user']['id'],
                    option_id=option_id)
                item = {
                    'id': poll_id,
                    'data': poll_data,
                    'version': current_version + 1
                }
                # persist updated poll-data, if we have the latest item version
                poll_table.put_item(
                    Item=item,
                    ConditionExpression='version = :CURRENT_VERSION',
                    ExpressionAttributeValues={
                        ':CURRENT_VERSION': current_version}
                )

                # update interactive poll message
                respond(
                    blocks=get_poll_blocks(
                        poll_id=poll_id,
                        poll_data=poll_data)
                )
            break
        except ClientError as error:
            if error.response['Error']['Code'] != 'ConditionalCheckFailedException':
                raise error
            # else:
            #    retry in case the item we've retrieved is stale by now

def vote(poll_data: dict, user_id: str, option_id: int):
    if user_id in poll_data['options'][option_id]['votes']:
        # unvote
        poll_data['options'][option_id]['votes'] = list(
            filter(lambda x: x != user_id, poll_data['options'][option_id]['votes']))
    else:
        # vote
        poll_data['options'][option_id]['votes'].append(user_id)
    return poll_data

# ...
```

# Infrastructure
For our serverless API we need
* an API Gateway to front the previously discussed Lambda function together with a Route53 record and an ACM certificate,
* the Lambda function itself together with a Slack Bolt library layer we build with Docker,
* a DynamoDB table where we maintain `poll_data` with `poll_id` as its [primary/hash key](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.CoreComponents.html#HowItWorks.CoreComponents.PrimaryKey),
* a Secrets Manager secret that holds our Slack app's credentials and
* a couple of IAM roles.

Since we use Terraform to provision our infrastructure, creating all of the above is matter of 
1. updating `terraform.tfvars`'s 
    * `aws_region` with our desired AWS target region
    * `aws_profile` with the AWS profile we're using
    * `zone_name` with the name of an already existing hosted zone, where the app's record and certificate validation records will be created
2. and running `terraform init` and `terraform apply`.

You may have to wait for the DNS record to propagate for a little while, use _nslookup_ by running the output of the `terraform output -raw check_url_command` command.

# Installing the Slack App to your Workspace
With the necesarry infrastructure in place we can install the app to a Slack workspace using an [app manifest](https://api.slack.com/reference/manifests) file:
* go to https://api.slack.com/apps
* click on _Create New App_
* click on _From an app manifest_ 
* select your desired workspace and click on _Next_
* run `terraform output -raw app_manifest` in the project's root folder and copy the output
* select _YAML_, paste above's app manifest and click on _Next_
* click on _Create_
* navigate to _Settings > Basic Information_, click on _Install to Workspace_ in the _Install your app_ section and confirm by clicking on _Allow_ in the following dialog

Next we put our app's _Signin Secret_ and _Bot User OAuth Token_ into the secret we previously mentioned so that the Lambda function can authenticate with Slack:
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


# Cleanup
To delete your Slack app
* go to https://api.slack.com/apps
* click on _Your Apps_ and select our app
* navigate to _Settings > Basic Information_ and click on _Delete App_

To delete all AWS resources
* run `terraform destroy`
