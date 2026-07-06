#ALL VIBE CODED. PoC ONLY

# Neo4jR

A native [Neo4j](https://neo4j.com/) driver for R that speaks the **Bolt**
protocol directly — no Python, no `reticulate`, no external runtime. The heavy
lifting is done by the Rust [`neo4rs`](https://github.com/neo4j-labs/neo4rs)
crate, wrapped with [`extendr`](https://extendr.github.io/); everything ships
inside one R package.

## Why this design

Neo4j's officially supported drivers are Java, Python, JavaScript, Go, and
.NET — none of which are directly wrappable from R via a compiled interface.
The realistic options for a self-contained R package are:

| Approach | Protocol | Compiled dep | CRAN-friendly |
|---|---|---|---|
| `httr2` + Query API | HTTP/JSON | none | easy |
| **`extendr` + `neo4rs` (this pkg)** | **Bolt** | **Rust (vendored)** | **yes** |
| `Rcpp` + `libneo4j-omni` | Bolt | C system lib + OpenSSL | harder |
| hand-rolled Bolt in C++ | Bolt | none | most work |

The old C connector `seabolt` is archived (2021) and not used.

## Usage

```r
con <- neo4j_connect("neo4j://localhost:7687", user = "neo4j", password = "password",
                     database = "mydb")   # database is optional; defaults to "neo4j"

cypher(con, "RETURN 1 AS n, 'hi' AS greeting")
#>   n greeting
#> 1 1       hi
```

`cypher()` returns a `data.frame` by default: one column per returned value,
one row per record. Scalar columns are simplified to typed atomic vectors
(integer / double / logical / character); Neo4j lists, maps, nodes,
relationships and paths become list-columns of structured objects (below).

### Query parameters (always prefer these)

Pass user-supplied values through `parameters`, never by pasting into the query
string. Parameters are sent as native Bolt values, so they cannot alter the
query (no Cypher injection) and the server can reuse the query plan.

```r
cypher(con,
       "MATCH (p:Person) WHERE p.age >= $min_age RETURN p.name AS name, p.age AS age",
       parameters = list(min_age = 30))
```

Length-1 R vectors become Bolt scalars; longer vectors and nested lists become
Bolt lists/maps. A value like `"x' RETURN 1 //"` is treated purely as data.

Labels and relationship types can be parameterized too, via Cypher
[dynamic labels](https://neo4j.com/docs/cypher-manual/current/clauses/match/#dynamic-match)
(`$(...)`), so even they need no string interpolation:

```r
cypher(con, "CREATE (n:$($label) {name: $name})",
       parameters = list(label = "Person", name = "Ada"))

cypher(con, "MATCH (n:$($label)) WHERE n.name = $name RETURN n",
       parameters = list(label = "Person", name = "Ada"))
```

### Structured results (nodes, relationships, paths)

Graph values map to classed R objects, so you can navigate them directly:

```r
df <- cypher(con, "MATCH (p:Person) RETURN p LIMIT 1")
node <- df$p[[1]]            # a list-column cell
node$id                      # element id
node$labels                  # character vector of labels
node$properties$name         # a named list of properties
```

| Neo4j value | R representation |
|---|---|
| Integer / Float / Boolean / String | length-1 atomic vector |
| List (`[1,2,3]`) | atomic vector (or list if heterogeneous) |
| Map (`{a:1}`) | named list |
| Node | `list(id, labels, properties)`, class `neo4j_node` |
| Relationship | `list(id, type, start, end, properties)`, class `neo4j_relationship` |
| Path | `list(nodes, relationships)`, class `neo4j_path` |
| `null` | `NA` |

### Result shape: data frame or nested list

`format = "list"` returns a JSON-analogous structure instead of a data frame —
a list of records, each a named list, with vectors for Neo4j lists and named
lists for maps:

```r
cypher(con, "MATCH (p:Person) RETURN p.name AS name, p.tags AS tags",
       format = "list")
#> [[1]]
#> [[1]]$name  -> "Ada"
#> [[1]]$tags  -> c("math", "cs")
```

### Query summary

`summary = TRUE` prints a client-side summary; it's also attached to every
result and retrievable with `neo4j_summary()`:

```r
df <- cypher(con, "MATCH (n) RETURN n LIMIT 100", summary = TRUE)
#> Neo4j query summary: 100 record(s), 1 column(s), 12.4 ms (client-side)
neo4j_summary(df)$elapsed_ms
```

Note: this is a *client-side* summary (records, columns, round-trip time).
Server-side write counters (nodes created, properties set, ...) are not
surfaced by `neo4rs` 0.8, so they are not reported — see *Known limitations*.

## Architecture

```
R  (neo4j_connect / cypher; neo4j_connection S3 wrapper)
│   .Call  →  extendr-generated wrappers (R/extendr-wrappers.R)
Rust (src/rust/src/lib.rs)
├─ Neo4jConnection { graph: neo4rs::Graph, rt: tokio::Runtime }   ← R external pointer
├─ bolt_connect(): ConfigBuilder(.db) → rt.block_on(Graph::connect(...))
└─ bolt_run():     rt.block_on(execute → collect rows)
              └─ get_value()/bolt_to_robj(): type-probe each value into
                 native R structures (scalars, vectors, nodes, rels, paths)
                 → returns records + keys + client-side summary
```

`neo4rs` is async; we bridge to R's synchronous world by holding one Tokio
runtime per connection and `block_on`-ing every call.

## Building from source

Requires a Rust toolchain (`cargo`, `rustc` ≥ 1.81).

```r
# regenerate wrappers + docs after editing Rust:
rextendr::register_extendr(); roxygen2::roxygenise()
# install:
R CMD INSTALL .
```

## Toward CRAN

CRAN build machines have **no network**, so dependencies must be vendored:

```r
rextendr::vendor_pkgs()   # writes src/rust/vendor.tar.xz + .cargo config
```

Then `cargo build --offline` must succeed. Also verify `neo4rs`'s TLS backend
does not pull `openssl-sys` (prefer a `rustls` feature) to keep the build free
of system libraries, and watch the vendored tarball size against CRAN limits.

## Known limitations

- **No server-side write counters.** `neo4rs` 0.8 discards the Bolt SUCCESS
  metadata, so `summary` reports only client-side info (records, columns,
  round-trip time), not nodes/relationships created or properties set.
- **Temporal & spatial types are stringified.** Date/Time/DateTime/Duration
  and Point values currently come back as their debug text, not R
  `Date`/`POSIXct`/spatial objects.
- **Column order** follows Bolt's field order, which may differ from the
  `RETURN` clause order (`neo4rs`'s `Row` doesn't expose the return-order keys).
  The data is correct; only the column ordering can differ.

## Roadmap

- Temporal & spatial Bolt types → R `Date`/`POSIXct`/`units`.
- Server-side write counters (needs a newer/lower-level Bolt path than
  `neo4rs` 0.8 exposes).
- Explicit transactions and multi-database routing.
- Connection/auth options (encryption, fetch size) via `ConfigBuilder`.
