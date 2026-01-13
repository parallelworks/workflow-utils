#!/usr/bin/python3
import os
import requests
from base64 import b64encode

"""
THIS SCRIPTS NEEDS TO RUN IN THE USER CONTAINER AND ONLY WORKS IF THE USER
IS AN ADMIN OF THE ORGANIZATION!!!
"""

def encode_string_to_base64(text):
    # Convert the string to bytes
    text_bytes = text.encode('utf-8')
    # Encode the bytes to base64
    encoded_bytes = b64encode(text_bytes)
    # Convert the encoded bytes back to a string
    encoded_string = encoded_bytes.decode('utf-8')
    return encoded_string

PW_PLATFORM_HOST = os.environ.get('PW_PLATFORM_HOST')
HEADERS = {"Authorization": "Basic {}".format(encode_string_to_base64(os.environ['PW_API_KEY']))}
SESSION_URL = f'https://{PW_PLATFORM_HOST}/api/v2/auth/session'
ORG_URL = f'https://{PW_PLATFORM_HOST}/api/v2/organization'

res = requests.get(SESSION_URL, headers = HEADERS)

org_name = res.json()['organization']

res = requests.get(ORG_URL, headers = HEADERS)

for org in res.json():
    if org['name'] == org_name:
        org_id = org['id']

org_info = {
    'ORGANIZATION_NAME': org_name,
    'ORGANIZATION_ID': org_id
}

org_info_txt = "\n".join([f'export {key}="{value}"' for key, value in org_info.items()])
print(org_info_txt)