-- for warehouse table
CREATE TABLE logistics.warehouses(
	warehouse_id INTEGER PRIMARY KEY,
	warehouse_name VARCHAR(150) NOT NULL,
	warehouse_city VARCHAR(150) NOT NULL,
	warehouse_region VARCHAR(150) NOT NULL
);

-- for carrier
CREATE TABLE logistics.carriers(
	carrier_id INTEGER PRIMARY KEY,
	carrier_name VARCHAR(150) NOT NULL UNIQUE
);

-- for products
CREATE TABLE logistics.products(
	product_id INTEGER PRIMARY KEY,
	product_name VARCHAR(255) NOT NULL,
	category VARCHAR(100) NOT NULL,
	unit_price NUMERIC(10, 2) NOT NULL CHECK(unit_price >= 0)
);

-- for customers
CREATE TABLE logistics.customers(
	customer_id INTEGER PRIMARY KEY,
	customer_name VARCHAR(150) NOT NULL,
	email VARCHAR(255),
	customer_city VARCHAR(100) NOT NULL,
	customer_region VARCHAR(50),
	customer_country VARCHAR(50) NOT NULL DEFAULT 'Ghana'
);

CREATE TABLE logistics.orders (
	order_id INTEGER NOT NULL,
	customer_id INTEGER NOT NULL REFERENCES logistics.customers(customer_id),
	warehouse_id INTEGER NOT NULL REFERENCES logistics.warehouses(warehouse_id),
	order_date DATE NOT NULL,
	order_status VARCHAR(20) NOT NULL CHECK (order_status IN ('Completed', 'Processing', 'Cancelled')),
	PRIMARY KEY(order_id, order_date)  -- COMPOSITE KEY
) PARTITION BY RANGE (order_date);

-- Create the partitions for orders table by YEAR
--2024
CREATE TABLE logistics.orders_2024 PARTITION OF logistics.orders
	FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');

-- 2025
CREATE TABLE logistics.orders_2025 PARTITION OF logistics.orders
	FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');

--2026
CREATE TABLE logistics.orders_2026 PARTITION OF logistics.orders
	FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');

-- Default
CREATE TABLE logistics.orders_default PARTITION OF logistics.orders DEFAULT;

-- for order_items
CREATE TABLE logistics.order_items (
    order_item_id   INTEGER PRIMARY KEY,
    order_id        INTEGER NOT NULL,
    order_date      DATE NOT NULL,            
    product_id      INTEGER NOT NULL REFERENCES logistics.products(product_id),
    quantity        INTEGER NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(10, 2) NOT NULL,   
    line_total      NUMERIC(12, 2) NOT NULL,
    FOREIGN KEY (order_id, order_date) REFERENCES logistics.orders(order_id, order_date)
);

CREATE TABLE logistics.shipments (
    shipment_id             INTEGER NOT NULL,
    order_id                INTEGER NOT NULL,
    carrier_id              INTEGER NOT NULL REFERENCES logistics.carriers(carrier_id),
    service_level           VARCHAR(20) NOT NULL CHECK (service_level IN ('Standard', 'Express', 'Overnight', 'Freight')),
    ship_date               DATE NOT NULL,
    expected_delivery_date  DATE NOT NULL,
    actual_delivery_date    DATE,              
    delivery_status         VARCHAR(20) NOT NULL CHECK (delivery_status IN ('Delivered', 'In Transit', 'Delayed', 'Cancelled')),
    shipping_cost           NUMERIC(10, 2) NOT NULL CHECK (shipping_cost >= 0),
    PRIMARY KEY (shipment_id, ship_date)   
) PARTITION BY RANGE (ship_date);

CREATE TABLE logistics.shipments_2024 PARTITION OF logistics.shipments
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');

CREATE TABLE logistics.shipments_2025 PARTITION OF logistics.shipments
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');

CREATE TABLE logistics.shipments_2026 PARTITION OF logistics.shipments
    FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');

CREATE TABLE logistics.shipments_default PARTITION OF logistics.shipments DEFAULT;