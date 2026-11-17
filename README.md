# ALL VIBE CODED. PoC ONLY

# Neo4jR

An R package that connects to Neo4j over the Bolt protocol. It wraps the Rust
[`neo4rs`](https://github.com/neo4j-labs/neo4rs) crate via
[`extendr`](https://extendr.github.io/) and compiles the Rust code into the
package.

## Installation

Installing a binary package does not require the Rust toolchain, however building
a binary or installing from source does.

### Install a binary

From a binary file (`.tgz` on macOS, `.zip` on Windows), use `repos = NULL`:
Binaries for Windows, Linux and Mac silicon are in `binaries/1
```r
install.packages("Neo4jR_0.0.0.9000.zip", repos = NULL)   # Windows
install.packages(<binary file>, repos = NULL)   # macOS
```

You can also try installing from source, but this will require the Rust toolchain.



### Build a binary (requires Rust)

Run on the target OS, with `cargo`/`rustc` >= 1.81. The binary is
`Neo4jR_<version>.tgz` on macOS or `Neo4jR_<version>.zip` on Windows, and must
be built on its target platform.

From a shell — writes the binary to the current working directory:

```sh
R CMD INSTALL --build .
```



```r
pkgbuild::build(".", binary = TRUE)                       # -> ../Neo4jR_<version>.zip
pkgbuild::build(".", binary = TRUE, dest_path = "binaries/windows")  # choose location
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

`database` is optional; when omitted, the database is left unspecified and the
server routes queries to the connecting user's home (default) database. The
connection is lazy: it is established on the first query, not at
`neo4j_connect()`.

## Running queries

```r
cypher(con, "RETURN 1 AS n, 'hi' AS greeting")
#>   n greeting
#> 1 1       hi
```

`cypher(con, query, parameters = list(), format = "data.frame", summary = FALSE)`
returns a `data.frame` by default. Scalar columns are simplified to typed atomic vectors. Neo4j lists,
maps, nodes, relationships and paths are rendered as list-columns of structured objects.

### Parameters


```r
cypher(con,
       "MATCH (p:Person) WHERE p.age >= $min_age RETURN p.name AS name, p.age AS age",
       parameters = list(min_age = 30))
```

Length-1 R vectors are sent as Bolt scalars; longer vectors and nested lists
become Bolt lists/maps.



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

