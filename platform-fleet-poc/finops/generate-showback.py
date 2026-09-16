#!/usr/bin/env python3
"""Generate FinOps CSV datasets from OpenCost allocations and cluster context.

Inputs:
- Cluster context file (ConfigMap YAML managed per cluster)
- OpenCost allocations API response

Output:
- Cluster inventory CSV (one row per cluster)
- Showback CSV (many rows per cluster, one per namespace)
- Client view CSV (minimal fields for service/finance stakeholders)
"""

from __future__ import annotations

import argparse
import csv
import json
import urllib.parse
import urllib.request
from pathlib import Path

import yaml


def load_cluster_context(path: Path) -> dict:
    doc = yaml.safe_load(path.read_text())
    data = doc.get("data", {})
    return {
        "requestId": data.get("requestId", "unknown"),
        "clusterId": data.get("clusterId", "unknown"),
        "clusterProfile": data.get("clusterProfile", "unknown"),
        "tenant": data.get("tenant", "unknown"),
        "environment": data.get("environment", "unknown"),
        "technicalOwner": data.get("technicalOwner", "unknown"),
        "financialAllocationRef": data.get("financialAllocationRef", "unknown"),
        "requestedWorkerCapacity": data.get("requestedWorkerCapacity", "unknown"),
        "lifecycleState": data.get("lifecycleState", "unknown"),
        "exceptionId": data.get("exceptionId", "none"),
    }


def fetch_allocations(base_url: str, window: str = "7d") -> dict:
    params = {
        "window": window,
        "aggregate": "namespace",
        "accumulate": "false",
    }
    url = f"{base_url.rstrip('/')}/allocation?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def iter_allocation_rows(payload: dict):
    data = payload.get("data", [])
    for item in data:
        if not isinstance(item, dict):
            continue

        # OpenCost can return one dict where keys are aggregate values
        # (for example namespaces) and values are allocation objects.
        if "properties" not in item:
            for value in item.values():
                if isinstance(value, dict) and "properties" in value:
                    yield value
            continue

        yield item


def allocation_records(allocations: dict):
    records = []
    for item in iter_allocation_rows(allocations):
        properties = item.get("properties", {})
        window = item.get("window", {})
        records.append(
            {
                "namespace": properties.get("namespace", "unknown"),
                "cpuCost": item.get("cpuCost", 0),
                "ramCost": item.get("ramCost", 0),
                "pvCost": item.get("pvCost", 0),
                "networkCost": item.get("networkCost", 0),
                "totalCost": item.get("totalCost", 0),
                "window": f"{window.get('start', '')}..{window.get('end', '')}",
            }
        )
    return records


def write_inventory_csv(path: Path, context: dict) -> None:
    with path.open("w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            [
                "clusterId",
                "environment",
                "clusterProfile",
                "tenant",
                "technicalOwner",
                "financialAllocationRef",
                "requestedWorkerCapacity",
                "lifecycleState",
                "requestId",
                "exceptionId",
            ]
        )
        writer.writerow(
            [
                context["clusterId"],
                context["environment"],
                context["clusterProfile"],
                context["tenant"],
                context["technicalOwner"],
                context["financialAllocationRef"],
                context["requestedWorkerCapacity"],
                context["lifecycleState"],
                context["requestId"],
                context["exceptionId"],
            ]
        )


def write_showback_csv(path: Path, context: dict, records: list[dict]) -> None:
    with path.open("w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            [
                "clusterId",
                "environment",
                "clusterProfile",
                "technicalOwner",
                "financialAllocationRef",
                "namespace",
                "cpuCost",
                "ramCost",
                "pvCost",
                "networkCost",
                "totalCost",
                "window",
            ]
        )

        for item in records:
            writer.writerow(
                [
                    context["clusterId"],
                    context["environment"],
                    context["clusterProfile"],
                    context["technicalOwner"],
                    context["financialAllocationRef"],
                    item["namespace"],
                    item["cpuCost"],
                    item["ramCost"],
                    item["pvCost"],
                    item["networkCost"],
                    item["totalCost"],
                    item["window"],
                ]
            )


def write_client_csv(path: Path, context: dict, records: list[dict]) -> None:
    with path.open("w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            [
                "clusterId",
                "environment",
                "owner",
                "costCenter",
                "namespace",
                "totalCost",
                "window",
            ]
        )

        for item in records:
            writer.writerow(
                [
                    context["clusterId"],
                    context["environment"],
                    context["technicalOwner"],
                    context["financialAllocationRef"],
                    item["namespace"],
                    item["totalCost"],
                    item["window"],
                ]
            )


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate showback CSV from OpenCost + cluster context")
    parser.add_argument("--cluster-context", required=True, help="Path to cluster-context.yaml")
    parser.add_argument("--opencost-url", default="http://localhost:9003", help="OpenCost API base URL")
    parser.add_argument("--allocations-file", help="Path to pre-fetched OpenCost allocations JSON")
    parser.add_argument("--window", default="7d", help="OpenCost window (e.g. 1d, 7d, 30d)")
    parser.add_argument("--out", default="showback.csv", help="Output showback CSV path")
    parser.add_argument("--inventory-out", help="Output cluster inventory CSV path")
    parser.add_argument("--client-out", help="Output client-friendly showback CSV path")
    args = parser.parse_args()

    context = load_cluster_context(Path(args.cluster_context))
    if args.allocations_file:
        allocations = json.loads(Path(args.allocations_file).read_text())
    else:
        allocations = fetch_allocations(args.opencost_url, args.window)
    showback_path = Path(args.out)
    inventory_path = Path(args.inventory_out) if args.inventory_out else showback_path.with_name("cluster-inventory.csv")
    client_path = Path(args.client_out) if args.client_out else showback_path.with_name("showback-client.csv")

    records = allocation_records(allocations)
    write_inventory_csv(inventory_path, context)
    write_showback_csv(showback_path, context, records)
    write_client_csv(client_path, context, records)

    print(f"Inventory generated at {inventory_path}")
    print(f"Showback generated at {showback_path}")
    print(f"Client view generated at {client_path}")


if __name__ == "__main__":
    main()