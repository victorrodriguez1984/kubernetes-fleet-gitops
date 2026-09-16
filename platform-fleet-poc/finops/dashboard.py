#!/usr/bin/env python3
"""Lightweight FinOps dashboard for showback CSV files."""

from __future__ import annotations

from pathlib import Path

import pandas as pd
import streamlit as st


DEFAULT_CSV = Path(__file__).with_name("showback-azr.csv")


def load_data(csv_path: Path) -> pd.DataFrame:
    df = pd.read_csv(csv_path)

    numeric_columns = ["cpuCost", "ramCost", "pvCost", "networkCost", "totalCost"]
    for col in numeric_columns:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0.0)

    return df


def money(amount: float) -> str:
    return f"EUR {amount:,.2f}"


def main() -> None:
    st.set_page_config(page_title="FinOps Showback", layout="wide")
    st.title("FinOps Showback Dashboard")

    csv_path = st.sidebar.text_input("CSV path", str(DEFAULT_CSV))
    csv_file = Path(csv_path)

    if not csv_file.exists():
        st.error(f"CSV not found: {csv_file}")
        st.stop()

    df = load_data(csv_file)
    if df.empty:
        st.warning("The CSV has no rows.")
        st.stop()

    total_cost = float(df["totalCost"].sum()) if "totalCost" in df.columns else 0.0
    total_cpu = float(df["cpuCost"].sum()) if "cpuCost" in df.columns else 0.0
    total_ram = float(df["ramCost"].sum()) if "ramCost" in df.columns else 0.0
    total_pv = float(df["pvCost"].sum()) if "pvCost" in df.columns else 0.0

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Total", money(total_cost))
    c2.metric("CPU", money(total_cpu))
    c3.metric("RAM", money(total_ram))
    c4.metric("PV", money(total_pv))

    if "namespace" in df.columns:
        per_ns = (
            df.groupby("namespace", as_index=False)[["cpuCost", "ramCost", "pvCost", "networkCost", "totalCost"]]
            .sum()
            .sort_values("totalCost", ascending=False)
        )
    else:
        per_ns = pd.DataFrame()

    left, right = st.columns([2, 1])

    with left:
        st.subheader("Top Namespaces")
        if per_ns.empty:
            st.info("No namespace column in CSV.")
        else:
            st.bar_chart(per_ns.set_index("namespace")["totalCost"])

    with right:
        st.subheader("Cost Breakdown")
        breakdown = pd.DataFrame(
            {
                "component": ["cpu", "ram", "pv", "network"],
                "cost": [
                    float(df["cpuCost"].sum()),
                    float(df["ramCost"].sum()),
                    float(df["pvCost"].sum()),
                    float(df["networkCost"].sum()),
                ],
            }
        )
        st.dataframe(breakdown, use_container_width=True)

    st.subheader("Raw Data")
    st.dataframe(df, use_container_width=True)


if __name__ == "__main__":
    main()