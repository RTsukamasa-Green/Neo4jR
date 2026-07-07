#' Open a connection. `uri` is a Bolt URI, e.g. "neo4j://localhost:7687"

# nolint start

#' or "127.0.0.1:7687". When `database` is non-empty it selects the default
#' database for the session; an empty string uses the server default
#' ("neo4j"). Returns an external pointer that R holds onto.
bolt_connect <- function(uri, user, password, database) .Call(wrap__bolt_connect, uri, user, password, database)

#' Run a parameterized Cypher statement and collect every row.
#'
#' `params` is a named R list; each element becomes a Cypher `$param`. Values
#' are converted straight to native Bolt types (no JSON round-trip), so the
#' query text is never string-interpolated (no injection, and the server can
#' cache the plan).
#'
#' Returns a named list with `records` (one named list per row, values mapped
#' to native R structures), `keys` (column names), `count`, and `elapsed_ms`
#' (client-side round-trip time). The R side shapes `records` into either a
#' data frame or a nested list.
bolt_run <- function(conn, cypher, params) .Call(wrap__bolt_run, conn, cypher, params)


# nolint end
