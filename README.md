# ALL VIBE CODED. PoC ONLY

# Neo4jR

An R package that connects to Neo4j over the Bolt protocol. It wraps the Rust
[`neo4rs`](https://github.com/neo4j-labs/neo4rs) crate via
[`extendr`](https://extendr.github.io/); the Rust code is compiled into the
package, so there is no Python or external runtime dependency. TLS uses
`rustls` (no system OpenSSL).

## Installation

Installing a binary package does not require the Rust toolchain; only building
a binary or installing from source does.

### Install a binary

From a binary file (`.tgz` on macOS, `.zip` on Windows):

```r
install.packages("Neo4jR_0.0.0.9000.tgz", repos = NULL)
remotes::install_local("Neo4jR_0.0.0.9000.tgz")
devtools::install_local("Neo4jR_0.0.0.9000.tgz")
```

Each installs the precompiled library without invoking cargo/rustc.

### Internal package repository

Place binaries in a CRAN-style directory and index it (paths use the target R
version, e.g. 4.4):

```r
tools::write_PACKAGES("repo/bin/windows/contrib/4.4",             type = "win.binary")
tools::write_PACKAGES("repo/bin/macosx/big-sur-arm64/contrib/4.4", type = "mac.binary")
```

Serve the directory over HTTP or a `file://` path:

```r
install.packages("Neo4jR", repos = "https://internal.example.com/r")
```

### Build a binary (requires Rust)

Run on the target OS, with `cargo`/`rustc` >= 1.81:

```sh
R CMD INSTALL --build .
```

This produces `Neo4jR_<version>.tgz` on macOS or `Neo4jR_<version>.zip` on
Windows. A binary must be built on its target platform.

The R Windows installer does not add R to `PATH`, so `R CMD` may be unavailable
in a shell. Building from within R avoids this:

```r
pkgbuild::build(".", binary = TRUE)
```

On Windows, R links with the GNU (Rtools) ABI. If the Rust GNU target is not
already the default toolchain, install it once before building:

```sh
rustup target add x86_64-pc-windows-gnu
```

### Build from source (requires Rust)

```r
rextendr::register_extendr(); roxygen2::roxygenise()  # after editing Rust
R CMD INSTALL .
```

## Connecting

```r
con <- neo4j_connect("neo4j://localhost:7687", user = "neo4j",
                     password = "password", database = "mydb")
```

`database` is optional and defaults to the server default (`"neo4j"`). The
connection is lazy: it is established on the first query, not at `neo4j_connect()`.

## Running queries

```r
cypher(con, "RETURN 1 AS n, 'hi' AS greeting")
#>   n greeting
#> 1 1       hi
```

`cypher(con, query, parameters = list(), format = "data.frame", summary = FALSE)`
returns a `data.frame` by default: one column per returned value, one row per
record. Scalar columns are simplified to typed atomic vectors; Neo4j lists,
maps, nodes, relationships and paths become list-columns of structured objects.

### Parameters

Values passed via `parameters` are sent as native Bolt values, so they are not
interpolated into the query text (no Cypher injection) and the server can reuse
the query plan.

```r
cypher(con,
       "MATCH (p:Person) WHERE p.age >= $min_age RETURN p.name AS name, p.age AS age",
       parameters = list(min_age = 30))
```

Length-1 R vectors are sent as Bolt scalars; longer vectors and nested lists
become Bolt lists/maps.

Labels and relationship types can be parameterized with Cypher
[dynamic labels](https://neo4j.com/docs/cypher-manual/current/clauses/match/#dynamic-match)
(`$(...)`):

```r
cypher(con, "CREATE (n:$($label) {name: $name})",
       parameters = list(label = "Person", name = "Ada"))
```

### Data type mapping

| Neo4j value | R representation |
|---|---|
| Integer / Float / Boolean / String | length-1 atomic vector |
| List (`[1,2,3]`) | atomic vector (or list if heterogeneous) |
| Map (`{a:1}`) | named list |
| Node | `list(id, labels, properties)`, class `neo4j_node` |
| Relationship | `list(id, type, start, end, properties)`, class `neo4j_relationship` |
| Path | `list(nodes, relationships)`, class `neo4j_path` |
| `null` | `NA` |

```r
df <- cypher(con, "MATCH (p:Person) RETURN p LIMIT 1")
node <- df$p[[1]]
node$id
node$labels
node$properties$name
```

### Result shape

`format = "list"` returns a nested structure instead of a data frame: a list of
records, each a named list, with vectors for Neo4j lists and named lists for
maps.

```r
cypher(con, "MATCH (p:Person) RETURN p.name AS name, p.tags AS tags",
       format = "list")
```

### Query summary

`summary = TRUE` prints a summary and attaches it to the result; retrieve it
with `neo4j_summary()`.

```r
df <- cypher(con, "MATCH (n) RETURN n LIMIT 100", summary = TRUE)
#> Neo4j query summary: 100 record(s), 1 column(s), 12.4 ms (client-side)
neo4j_summary(df)$elapsed_ms
```

The summary is client-side (records, columns, round-trip time). Server-side
write counters are not reported (see Limitations).

## Architecture

```
R  (neo4j_connect / cypher; neo4j_connection S3 wrapper)
│   .Call  ->  extendr-generated wrappers (R/extendr-wrappers.R)
Rust (src/rust/src/lib.rs)
├─ Neo4jConnection { graph: neo4rs::Graph, rt: tokio::Runtime }   (R external pointer)
├─ bolt_connect(): ConfigBuilder(.db) -> rt.block_on(Graph::connect(...))
└─ bolt_run():     rt.block_on(execute -> collect rows)
              └─ get_value()/bolt_to_robj(): type-probe each value into
                 native R structures; returns records + keys + summary
```

`neo4rs` is async; each connection holds one Tokio runtime and calls
`block_on` per query.

## CRAN packaging

CRAN build machines have no network access, so dependencies must be vendored:

```r
rextendr::vendor_pkgs()   # writes src/rust/vendor.tar.xz + .cargo config
```

`cargo build --offline` must then succeed. The vendored tarball counts toward
CRAN package size limits.

## Limitations

- Server-side write counters (nodes/relationships created, properties set) are
  not exposed by `neo4rs` 0.8, so `summary` reports client-side info only.
- Temporal and spatial types (Date/Time/DateTime/Duration, Point) are returned
  as their debug text, not R date/time/spatial objects.
- Column order follows Bolt's field order, which may differ from the `RETURN`
  clause order.

## Roadmap

- Temporal and spatial types -> R `Date`/`POSIXct`.
- Server-side write counters.
- Explicit transactions and multi-database routing.
- Connection/auth options (encryption, fetch size) via `ConfigBuilder`.
