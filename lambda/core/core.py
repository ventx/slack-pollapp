import logging
import boto3
from boto3.dynamodb.conditions import Attr
from botocore.exceptions import ClientError
import os
import uuid
import json
import re
from slack_bolt import App
from slack_bolt.adapter.aws_lambda import SlackRequestHandler


poll_table_name = os.environ.get('DYNAMODB_TABLE_NAME')
poll_table = boto3.resource('dynamodb').Table(poll_table_name)

command = "/poll"
app_mention = "app_mention"
action_vote = "action_vote"


def immediate_ack(ack):
    ack()


def vote(poll_data: dict, user_id: str, option_id: int):
    if user_id in poll_data['options'][option_id]['votes']:
        poll_data['options'][option_id]['votes'] = list(
            filter(lambda x: x != user_id, poll_data['options'][option_id]['votes']))
    else:
        poll_data['options'][option_id]['votes'].append(user_id)
    return poll_data


def get_poll_blocks(poll_id: str, poll_data: dict):
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
            'type': 'section',
            'text': {
                'type': 'mrkdwn',
                'text': f"{option_id + 1}. {option['title']}\n {', '.join(list(map(lambda x: '<@' + x + '>', option['votes'])))}"
            },
            'accessory': {
                'type': 'button',
                'text': {
                    'type': 'plain_text',
                    'text': f"Vote ({len(option['votes'])})"
                },
                'value': f"{option_id}_{poll_id}",
                'action_id': action_vote
            }
        })
    return blocks


def usage(body, respond, client):
    text = 'Could not parse command!'
    blocks = [
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*Could not parse command!*"
            }
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*Usage:*\n```\"Wanna hang out?\" \"Maybe\" \"Maybe not\"```"
            }
        }
    ]
    if 'response_url' in body:
        respond(
            text=text,
            blocks=blocks)
    else:
        client.chat_postEphemeral(
            channel=body['event']['channel'],
            user=body['event']['user'],
            text=text,
            blocks=blocks)


def init_poll(body, respond, say, client):
    command = re.findall('"([^"]*)"', body['text']
                         if 'command' in body else body['event']['text'])

    if not len(command) > 1:
        usage(body, respond, client)
    else:
        item = {
            'id': str(uuid.uuid4()),
            'version': 0,
            'data': {
                'title': command[0],
                'options': list(map(lambda x: {'title': x, 'votes': []}, command[1:]))
            }
        }
        poll_table.put_item(Item=item)

        if 'response_url' in body:
            respond(
                response_type='in_channel',
                blocks=get_poll_blocks(
                    poll_id=item['id'], poll_data=item['data'])
            )
        else:
            say(
                response_type='in_channel',
                blocks=get_poll_blocks(
                    poll_id=item['id'], poll_data=item['data'])
            )


def on_vote(body, respond, action):
    option_id = int(action['value'].split('_')[0])
    poll_id = action['value'].split('_')[1]

    for i in range(3):
        try:
            response = poll_table.get_item(
                TableName=poll_table_name,
                Key={
                    'id': poll_id
                }
            )
            if 'Item' in response:
                current_version = response['Item']['version']
                poll_data = vote(
                    poll_data=response['Item']['data'],
                    user_id=body['user']['id'],
                    option_id=option_id)
                item = {
                    'id': poll_id,
                    'data': poll_data,
                    'version': current_version + 1
                }
                poll_table.put_item(
                    Item=item,
                    ConditionExpression='version = :CURRENT_VERSION',
                    ExpressionAttributeValues={
                        ':CURRENT_VERSION': current_version}
                )
                respond(
                    blocks=get_poll_blocks(
                        poll_id=poll_id,
                        poll_data=poll_data)
                )
            break
        except ClientError as error:
            if error.response['Error']['Code'] != 'ConditionalCheckFailedException':
                raise error


SlackRequestHandler.clear_all_log_handlers()
logging.basicConfig(format="%(levelname)s %(message)s", level=logging.INFO)

slack_secrets = json.loads(
    boto3.client('secretsmanager')
    .get_secret_value(
        SecretId=os.environ.get("SLACK_SECRETS_SECRET_ID")
    )['SecretString'])

app = App(
    token=slack_secrets['SLACK_BOT_TOKEN'],
    signing_secret=slack_secrets['SLACK_SIGNING_SECRET'],
    process_before_response=True
)
app.command(command)(ack=immediate_ack, lazy=[init_poll])
app.event(app_mention)(ack=immediate_ack, lazy=[init_poll])
app.action(action_vote)(ack=immediate_ack, lazy=[on_vote])


def handler(event, context):
    slack_handler = SlackRequestHandler(app=app)
    return slack_handler.handle(event, context)
