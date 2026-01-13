#!/usr/bin/python3
import os
import requests
import argparse
import json
from base64 import b64encode

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


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Process resource_name and resource_namespace')
    parser.add_argument('--resource_name', type=str, help='Name of the resource')
    parser.add_argument('--resource_namespace', type=str, help='Namespace of the resource')
    args = parser.parse_args()

    URL = f'https://{PW_PLATFORM_HOST}/api/compute/clusters/{args.resource_namespace}/{args.resource_name}'

    res = requests.get(URL, headers = HEADERS)

    print(json.dumps(res.json()['nodes'], indent = 4))