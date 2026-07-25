# Sankofa Freight Networks — CSV to PostgreSQL: Building a Scalable Logistics Data Warehouse

> **A Data Engineering Case Study**
> Specialization: Logistics & Supply Chain
> Accredited by the American Council of Training and Development

---

## Overview

Sankofa Freight Networks is a logistics and supply chain company coordinating warehousing, freight movement, and delivery across all 16 regions of Ghana. They operate a network of regional carriers serving retail and industrial clients, with distribution hubs in every region to ensure reliable delivery performance.

Their order volume recently crossed **750,000 orders** spanning January 2024 through June 2026. The entire operation ran off a single flat CSV export shared across teams by email and spreadsheet link — a setup that could no longer support both day-to-day order processing and multi-year performance reporting simultaneously.

This project redesigns that flat-file process into a **normalized, partitioned PostgreSQL data warehouse**.

---

## The Business Problem

| Pain Point | Description |
|---|---|
| **Scale Incompatibility** | A single CSV holding 750,000+ orders and ~1.9 million order line items breaks standard spreadsheet tools the moment it's opened |
| **No Referential Integrity** | Customer, product, warehouse, and shipment details repeat on every row with no constraints — anything goes |
| **Performance at Scale** | A date-filtered report requires scanning the entire flat file, getting slower with every new order recorded |

---

## Project Goals

By completing this project you will be able to:

- **Design & Build an ETL Pipeline** — Reusable pandas pipelines that clean, de-duplicate, and split a 750,000+ order flat file into relational tables ready for a production database
- **Implement a Relational & Normalized Schema** — Model one-to-many and junction-table relationships with primary keys, foreign keys, and check constraints that guarantee referential integrity end to end
- **Optimize Query Performance** — Apply declarative range partitioning and indexing so multi-year order and shipment history stays fast to query as the business scales

---

## Pipeline Architecture

The pipeline follows a simplified **two-hop pattern**:

```
Raw CSV Export
      │
      ▼
┌─────────────────────────────────┐
│   Step 1 — Schema Design        │
│   Normalize flat file into       │
│   relational tables with PK/FK  │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│   Step 2 — Data Profiling &     │
│   Cleaning (pandas)             │
│   De-duplicate, fix nulls,      │
│   standardize formats           │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│   Step 3 — Partitioned Load     │
│   PostgreSQL warehouse with     │
│   orders & shipments partitioned│
│   by year                       │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│   Step 4 — Quality Validation   │
│   (Gold Layer)                  │
│   Referential integrity checks  │
│   + analytical query validation │
└─────────────────────────────────┘
```

---

## Project Workflow

### Step 1 — Schema Design & Normalization
Split the single wide table into normalized relational tables with defined primary and foreign keys. The flat file is decomposed into dimension and fact tables covering customers, products, warehouses, carriers, orders, order line items, and shipments.

### Step 2 — Data Profiling & Cleaning
Inspect the raw CSV, identify duplicate rows, missing values, and inconsistent formatting across 750,000+ orders, and resolve them with pandas. This step produces clean, typed DataFrames — one per relational table.

### Step 3 — Partitioned Warehouse Load
Load the cleaned tables into PostgreSQL. The `orders` and `shipments` tables are partitioned by year using **declarative range partitioning**, allowing Postgres to scan only the relevant slice of data for any date-filtered report.

### Step 4 — Quality Validation (Gold Layer)
Confirm referential integrity across all foreign key relationships and run analytical queries to prove the warehouse supports both daily operational queries and multi-year historical reporting.

---

## Schema Design

The normalized schema splits the original flat file into the following tables:

```
customers          products           warehouses         carriers
    │                  │                   │                 │
    └──────────────────┴───────────────────┴────────┐        │
                                                    ▼        │
                                                  orders      │
                                                    │         │
                                          ┌─────────┴──────┐ │
                                          │                │ │
                                    order_items        shipments ◄─┘
```

| Table | Description |
|---|---|
| `customers` | Unique customer records with contact and region info |
| `products` | Product catalog with category and unit details |
| `warehouses` | Warehouse locations across Ghana's 16 regions |
| `carriers` | Carrier network used for freight movement |
| `orders` | Order header records — partitioned by year |
| `order_items` | Line items linking orders to products and quantities |
| `shipments` | Shipment and delivery tracking — partitioned by year |

---

## Tech Stack

| Tool | Purpose |
|---|---|
| **Python / pandas** | Data profiling, cleaning, de-duplication, and transformation |
| **PostgreSQL** | Target warehouse with declarative range partitioning |
| **psycopg2 / SQLAlchemy** | Python-to-Postgres connection and bulk loading |
| **SQL** | Schema DDL, partitioning, indexing, and analytical queries |

---

## Key Engineering Decisions

**Declarative Range Partitioning**
Orders and shipments are partitioned by year (`2024`, `2025`, `2026`). Postgres partition pruning ensures date-filtered queries scan only the relevant child table, keeping performance predictable as order history grows.

**Referential Integrity via FK Constraints**
Every order line item and shipment record is linked to a valid parent record through enforced foreign keys. Orphaned records that fail this check are quarantined and logged during the ETL run.

**Reproducible ETL**
The pandas pipeline is designed to be re-run against any future CSV export without manual intervention — cleaning rules are parameterized, not hard-coded to specific row ranges.

---

## Getting Started

### Prerequisites
- Python 3.9+
- PostgreSQL 14+
- pip packages: `pandas`, `psycopg2-binary`, `sqlalchemy`, `python-dotenv`

### Setup

```bash
# Clone the repository
git clone https://github.com/<your-username>/logistics-business-data-warehouse.git
cd logistics-business-data-warehouse

# Install dependencies
pip install -r requirements.txt

# Configure your database connection
cp .env.example .env
# Edit .env with your PostgreSQL credentials
```

### Run the Pipeline

```bash
# Step 1: Create the partitioned schema
psql -U <user> -d <database> -f sql/01_schema.sql

# Step 2 & 3: Clean and load data
python etl/pipeline.py --input data/raw/sankofa_orders.csv

# Step 4: Run validation queries
psql -U <user> -d <database> -f sql/04_validation.sql
```

---

## Project Structure

```
logistics-business-data-warehouse/
├── data/
│   ├── raw/                  # Original CSV export (not committed — see .gitignore)
│   └── processed/            # Cleaned intermediate DataFrames
├── etl/
│   ├── pipeline.py           # Main ETL entry point
│   ├── clean.py              # Profiling and cleaning logic
│   ├── transform.py          # Normalization and key generation
│   └── load.py               # PostgreSQL bulk loader
├── sql/
│   ├── 01_schema.sql         # DDL: tables, partitions, indexes, constraints
│   ├── 02_partitions.sql     # Partition child table definitions
│   ├── 03_views.sql          # Analytics views (gold layer)
│   └── 04_validation.sql     # Referential integrity and QA queries
├── notebooks/
│   └── exploration.ipynb     # Data profiling notebook
├── requirements.txt
├── .env.example
├── LICENSE
└── README.md
```

---

## Results

After the pipeline runs against the full 750,000-order export:

- All duplicate order records are identified and removed
- ~1.9 million order line items are linked to valid order headers via FK constraints
- Orders and shipments are queryable by year with partition pruning confirmed via `EXPLAIN ANALYZE`
- Analytical views support multi-year delivery-performance reporting without full-table scans

---

## Learning Outcomes

This project demonstrates practical skills in:

- Cleaning and normalizing large-scale flat-file exports with pandas
- Relational schema design with enforced primary and foreign keys
- PostgreSQL declarative range partitioning and query optimization
- Building reproducible ETL pipelines for production-scale data

---

## Author

**Oluwatobi Meduoye**
Data Engineering Case Study — Sankofa Freight Networks
[LinkedIn](https://www.linkedin.com/in/) · [GitHub](https://github.com/)

---

## License

This project is licensed under the terms of the [LICENSE](LICENSE) file included in this repository.
