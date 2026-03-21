import json
import boto3

client = boto3.client("bedrock-agent-runtime")


def handler(event, context):
    response = client.invoke_agent(
        agentId=event["agent_id"],
        agentAliasId=event["alias_id"],
        sessionId=event["session_id"],
        inputText=event["input_text"],
    )
    result = ""
    for chunk_event in response["completion"]:
        if "chunk" in chunk_event:
            result += chunk_event["chunk"]["bytes"].decode()
    return {"result": result}
