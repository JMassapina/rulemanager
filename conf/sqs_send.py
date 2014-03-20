#!/usr/bin/env python
import requests
import boto
import json
import boto.ec2
import boto.s3
import boto.sqs
import time
import os
from boto.sqs.message import Message

url = 'http://169.254.169.254/latest/meta-data/'
queue_name = 'rulemanager'
queue_owner_account_id = '123456789012'

region_name = requests.get(url+'placement/availability-zone').text[:-1]
region_full = requests.get(url+'placement/availability-zone').text
instance_id = requests.get(url+'instance-id').text
public_hostname = requests.get(url+'public-hostname').text
mac = requests.get(url+'network/interfaces/macs/').text
owner = requests.get(url+'network/interfaces/macs/' + mac + '/owner-id').text

conn = boto.sqs.connect_to_region('eu-west-1')
q = conn.get_queue(queue_name=queue_name, owner_acct_id=queue_owner_account_id)
m = Message()
m.set_body(json.dumps({ "instance_id": instance_id, "hostname": public_hostname, "state": 'up', "region": region_full, "owner": owner }))
status = q.write(m)
