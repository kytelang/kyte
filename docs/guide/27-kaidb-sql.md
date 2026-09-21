# 27. kaidb SQL reference

This chapter is a practical reference for the SQL that kaidb understands today. It
covers the statements, the query clauses, the operators, the types, and the indexing
practice that makes reads fast. Where the behaviour differs from what you might
expect from another database, it says so plainly.

kaidb SQL is close to standard SQL with a few deliberate simplifications. Equality is
a single `=` (there is no `==`), the parameter placeholder is `?`, and column widths
in a type such as `VARCHAR(64)` are parsed but not stored.

## Statements at a glance

kaidb parses and runs: `SELECT` (with `UNION` and `UNION ALL`), `INSERT`, `UPDATE`,
`DELETE`, `CREATE`, `DROP`, `ALTER`, `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`,
`RELEASE`, `IMPORT`, `EXPORT`, `BACKUP`, `ANALYZE`, and the access control statements
`CREATE USER`, `CREATE ROLE`, `GRANT`, and `REVOKE`.

## Data definition

### Creating tables

```sql
CREATE TABLE IF NOT EXISTS ord (
    id      INT PRIMARY KEY,
    customer TEXT NOT NULL,
    total   DECIMAL(12,2) DEFAULT 0,
    status  TEXT DEFAULT 'new',
    parent  INT REFERENCES ord(id)
);
```

A few things to know:

- The **type name is a free identifier**. kaidb accepts the usual names (`INT`,
  `BIGINT`, `TEXT`, `VARCHAR`, `DOUBLE`, `DECIMAL`, `BOOL`, and so on) but does not
  restrict you to a fixed keyword set. An optional size or precision such as `(64)`
  or `(12,2)` is parsed and then discarded, because kaidb does not store column
  widths.
- **Column constraints** may appear in any order: `PRIMARY KEY`, `UNIQUE`,
  `NOT NULL`, `NULL`, `DEFAULT (value)`, and `REFERENCES parent(col)` for a foreign
  key. `AUTO_INCREMENT` is accepted for compatibility and then ignored, so assign
  your own key values.
- `IF NOT EXISTS` is supported.

### Creating indexes

```sql
CREATE INDEX ord_by_status ON ord (status);
CREATE UNIQUE INDEX ord_by_customer ON ord (customer);
CREATE INDEX ord_status_total ON ord (status, total);
```

Indexes may be single column or **composite** (several columns). There is no separate
`INCLUDE` or covering keyword: you build a covering index by listing the filter
column first and the columns you want to read or aggregate after it, as in
`ord_status_total` above. See the indexing section below for why this matters.

### Dropping and altering

```sql
DROP TABLE ord;

DROP INDEX ord_by_status;            -- the bare form
DROP INDEX ord_by_status ON ord;     -- the MySQL form also works

ALTER TABLE ord RENAME TO orders;
ALTER TABLE ord ADD COLUMN note TEXT;
```

Index names are unique across the database, so the `ON table` clause on `DROP INDEX`
is optional. Both the bare form and the MySQL `ON table` form are accepted.

## Data manipulation

### Insert

```sql
INSERT INTO ord (id, customer, total, status)
VALUES (1, 'Asha', 250.00, 'new'),
       (2, 'Ravi', 90.00, 'paid');
```

Multi row `VALUES` is supported and every row is inserted; the statement reports the
number of rows affected.

### Update and delete

```sql
UPDATE ord SET status = 'shipped', total = total + 10 WHERE id = 2;

DELETE FROM ord WHERE status = 'cancelled';
```

Updates use standard `SET column = expression` assignments. Both `UPDATE` and
`DELETE` take an optional `WHERE` clause.

## Queries

A `SELECT` supports the usual clauses, in this order:

```sql
SELECT DISTINCT status, COUNT(*) AS n, SUM(total) AS revenue
FROM ord
LEFT JOIN customer ON customer.id = ord.customer_id
WHERE total > 100 AND status IN ('paid', 'shipped')
GROUP BY status
HAVING COUNT(*) > 1
ORDER BY revenue DESC
LIMIT 20 OFFSET 0;
```

- **Projections**: `*`, named columns, and aggregates, each with an optional `AS`
  alias.
- **Joins**: `INNER`, `LEFT`, `RIGHT`, and `FULL OUTER` joins with an `ON`
  condition. The planner chooses nested loop or hash join by estimated cost.
- **Aggregates**: `COUNT`, `SUM`, `AVG`, `MIN`, and `MAX`, with `GROUP BY`, `HAVING`,
  and `DISTINCT`.
- **Set operations**: `UNION` and `UNION ALL` chain selects.
- **Subqueries**: `IN (SELECT ...)` and a scalar `(SELECT ...)`.
- **Paging**: `ORDER BY`, `LIMIT`, and `OFFSET`.

### WHERE operators

- Comparison: `=` (a single equals sign; there is no `==`), `<`, `>`, `<=`, `>=`,
  `<>`, and `!=`.
- Logical: `AND`, `OR`, `NOT`.
- Membership and ranges: `IN (...)`, `BETWEEN a AND b`, `LIKE 'pattern%'`.
- Null tests: `IS NULL` and `IS NOT NULL`.
- Conditionals: `CASE WHEN ... THEN ... ELSE ... END`.
- The parameter placeholder is `?`.

### A note on literals

Number literals may be integers or floats, but the exponent form (`1e9`) is not
supported. A leading minus sign is a separate token, so write `-5` and it is read as
negation of `5`.

## Types and NULL

Because the type name is a free identifier, you can use the names your schema tools
emit. Internally the clustered primary key is stored as decimal text, and secondary
index keys are order preserving fixed width tokens so that ranges sort correctly.
`NULL` and `NOT NULL` are honoured, and `DEFAULT NULL` is accepted.

## Indexing for speed

This is the single most useful thing to understand about kaidb performance.

Because the table is its own primary key tree, a lookup or range **by primary key** is
as cheap as it gets: the key and the row are found together. A read that filters on a
**secondary index**, however, finds matching keys in the index and then, for each
match, descends back into the clustered base tree to fetch the row. For a query that
touches many rows, that per row base descent (the "base seek") is the bulk of the
cost.

The remedy is a **covering composite index**: put the filter column first and the
columns you actually read or aggregate after it. The planner then satisfies the query
from the index alone, with no base descent per row. Fast paths that use this include
index only counts, index min and max, and index only grouped and scalar aggregates.

```sql
-- Slower: filters on status via the index, then descends per row to read total.
CREATE INDEX ord_by_status ON ord (status);
SELECT SUM(total) FROM ord WHERE status = 'paid';

-- Faster: the index carries both status and total, so the sum is index only.
CREATE INDEX ord_status_total ON ord (status, total);
SELECT SUM(total) FROM ord WHERE status = 'paid';
```

> The planner is cost based. If a range predicate matches a large fraction of the
> table (roughly a third or more), it will drop the index and scan, because at that
> point a scan does less work than many index descents.

## Bulk load, export, and backup

kaidb supports bulk data movement and hot backup as SQL statements:

```sql
IMPORT INTO ord FROM 'orders.csv' FORMAT CSV;
EXPORT ord TO 'orders.json' FORMAT JSON;
BACKUP DATABASE TO '/backups/2026-09-19';
```

`IMPORT` and `EXPORT` handle `CSV`, `JSON`, `BSON`, and `MANIFEST` formats. `ANALYZE`
refreshes planner statistics.

## Known simplifications

Keep these in mind so nothing surprises you:

- Equality is `=`, not `==`.
- The parameter placeholder is `?`, not `$1` or a named marker.
- Column widths in types such as `VARCHAR(64)` are parsed and discarded.
- `AUTO_INCREMENT` is accepted but does nothing; assign key values yourself.
- The exponent form of number literals (`1e9`) is not supported.
