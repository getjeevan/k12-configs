"""
title: K12 Ops Status
author: Jarvis
description: Live health check for all K12 infrastructure services. Queries
             the Jarvis Ops API and returns a plain-text status summary.
version: 1.0
"""

import httpx

OPS_API = "http://192.168.1.168:3006"


class Tools:
    def __init__(self):
        pass

    async def get_k12_status(self) -> str:
        """
        Get the live health status of all K12 infrastructure services.
        Returns a text summary showing which containers and endpoints are
        up or down. Call this whenever the user asks about service health,
        uptime, or whether something is running.
        """
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(f"{OPS_API}/status/text")
                resp.raise_for_status()
                return resp.json().get("text", "No status data returned.")
        except httpx.TimeoutException:
            return "Ops API timed out — K12 may be under load or the jarvis-ops-api container is down."
        except Exception as e:
            return f"Could not reach Jarvis Ops API ({OPS_API}): {e}"

    async def get_k12_status_json(self) -> str:
        """
        Get detailed JSON health data for all K12 services including HTTP
        status codes and Docker health states. Use this when you need
        specific details beyond a simple up/down summary.
        """
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(f"{OPS_API}/status")
                resp.raise_for_status()
                import json
                return json.dumps(resp.json(), indent=2)
        except Exception as e:
            return f"Could not reach Jarvis Ops API: {e}"
