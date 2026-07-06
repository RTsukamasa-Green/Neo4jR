#' Connect to a Neo4j database
#'
#' Opens a Bolt connection to a Neo4j server and returns a connection handle
#' that can be passed to [cypher()].
#'
#' @param uri Bolt URI, e.g. `"neo4j://localhost:7687"` or `"127.0.0.1:7687"`.
#' @param user Username (default `"neo4j"`).
#' @param password Password.
#' @param database Name of the database to use for the session. Defaults to
#'   `NULL`, which uses the server default (`"neo4j"`).
#'
#' @return A `neo4j_connection` object.
#' @export
#'
#' @examples
#' \dontrun{
#' con <- neo4j_connect("neo4j://localhost:7687", "neo4j", "password",
#'                      database = "mydb")
#' cypher(con, "RETURN 1 AS n")
#' }
neo4j_connect <- function(uri, user = "neo4j", password = "", database = NULL) {
  stopifnot(is.character(uri), length(uri) == 1L)
  if (is.null(database)) database <- ""
  stopifnot(is.character(database), length(database) == 1L)
  handle <- bolt_connect(uri, user, password, database)
  structure(list(handle = handle, uri = uri, database = database),
            class = "neo4j_connection")
}

#' Run a Cypher statement
#'
#' Executes a Cypher query over the Bolt connection and returns the result in
#' one of two shapes (see `format`).
#'
#' Always pass user-supplied values through `parameters` rather than pasting
#' them into the query string: parameters are sent as native Bolt values, which
#' prevents Cypher injection and lets the server reuse the query plan.
#'
#' @param con A `neo4j_connection` from [neo4j_connect()].
#' @param query A Cypher statement. Reference parameters with `$name`.
#' @param parameters A named list of query parameters, substituted for the
#'   matching `$name` placeholders. Length-1 vectors are sent as scalars;
#'   longer vectors and nested lists become Bolt lists/maps. Defaults to none.
#' @param format Result shape. `"data.frame"` (default) returns one column per
#'   returned value and one row per record; scalar columns are simplified to
#'   atomic vectors, while nodes, relationships, paths and heterogeneous values
#'   become list-columns. `"list"` returns a JSON-analogous nested structure: a
#'   list of records, each a named list whose values are R vectors (a Neo4j
#'   list), named lists (a Neo4j map), or classed objects (`neo4j_node` /
#'   `neo4j_relationship` / `neo4j_path`).
#' @param summary If `TRUE`, print a one-line client-side query summary
#'   (records, columns, elapsed round-trip time). The summary is always
#'   attached to the result as the `"neo4j_summary"` attribute; see
#'   [neo4j_summary()].
#'
#' @return A `data.frame` or a list, per `format`.
#' @export
#'
#' @examples
#' \dontrun{
#' cypher(con,
#'        "MATCH (p:Person) WHERE p.age > $min_age RETURN p.name AS name",
#'        parameters = list(min_age = 30))
#'
#' # Whole nodes come back as structured objects:
#' cypher(con, "MATCH (p:Person) RETURN p LIMIT 1", format = "list")
#' }
cypher <- function(con, query, parameters = list(),
                   format = c("data.frame", "list"), summary = FALSE) {
  stopifnot(inherits(con, "neo4j_connection"))
  stopifnot(is.character(query), length(query) == 1L)
  stopifnot(is.list(parameters))
  format <- match.arg(format)
  if (length(parameters) > 0L && is.null(names(parameters))) {
    stop("`parameters` must be a named list.", call. = FALSE)
  }
  params_json <- if (length(parameters) == 0L) {
    "{}"
  } else {
    jsonlite::toJSON(parameters, auto_unbox = TRUE, null = "null", digits = NA)
  }

  res <- bolt_run(con$handle, query, params_json)
  summ <- structure(
    list(records = res$count, columns = res$keys, elapsed_ms = res$elapsed_ms),
    class = "neo4j_summary"
  )
  if (isTRUE(summary)) print(summ)

  out <- if (format == "list") {
    res$records
  } else {
    .records_to_df(res$records, res$keys, res$count)
  }
  attr(out, "neo4j_summary") <- summ
  out
}

#' Query summary of a result
#'
#' Returns the client-side summary attached to a [cypher()] result: number of
#' records, column names, and elapsed round-trip time in milliseconds.
#'
#' Note: this is measured client-side. Server-side write counters (nodes
#' created, properties set, ...) are not exposed by the underlying `neo4rs`
#' driver and are therefore not reported.
#'
#' @param x A result returned by [cypher()].
#' @return A `neo4j_summary` object (a list), or `NULL` if absent.
#' @export
neo4j_summary <- function(x) {
  attr(x, "neo4j_summary")
}

# Pivot the list of record (named lists) into a data.frame. Columns whose cells
# are all length-1 atomics are simplified to atomic vectors; everything else
# (nodes, lists, maps, mixed) becomes a list-column.
.records_to_df <- function(records, keys, count) {
  if (length(keys) == 0L) {
    return(structure(list(), names = character(0),
                     row.names = integer(0), class = "data.frame"))
  }
  cols <- lapply(keys, function(k) {
    vals <- lapply(records, function(rec) rec[[k]])
    if (length(vals) > 0L &&
        all(vapply(vals, function(v) is.atomic(v) && length(v) == 1L, logical(1)))) {
      unlist(vals, use.names = FALSE)
    } else {
      vals
    }
  })
  names(cols) <- keys
  attr(cols, "row.names") <- if (count > 0L) seq_len(count) else integer(0)
  class(cols) <- "data.frame"
  cols
}

#' @export
print.neo4j_connection <- function(x, ...) {
  db <- if (is.null(x$database) || !nzchar(x$database)) "neo4j (default)" else x$database
  cat("<neo4j_connection>", x$uri, "db:", db, "\n")
  invisible(x)
}

#' @export
print.neo4j_summary <- function(x, ...) {
  cat(sprintf("Neo4j query summary: %d record(s), %d column(s), %.1f ms (client-side)\n",
              x$records, length(x$columns), x$elapsed_ms))
  invisible(x)
}

#' @export
print.neo4j_node <- function(x, ...) {
  cat(sprintf("<neo4j_node> id=%s :%s\n", x$id, paste(x$labels, collapse = ":")))
  utils::str(x$properties, no.list = TRUE, give.attr = FALSE)
  invisible(x)
}

#' @export
print.neo4j_relationship <- function(x, ...) {
  ends <- if (!is.null(x$start)) sprintf(" (%s)->(%s)", x$start, x$end) else ""
  cat(sprintf("<neo4j_relationship> id=%s [:%s]%s\n", x$id, x$type, ends))
  utils::str(x$properties, no.list = TRUE, give.attr = FALSE)
  invisible(x)
}

#' @export
print.neo4j_path <- function(x, ...) {
  cat(sprintf("<neo4j_path> %d node(s), %d relationship(s)\n",
              length(x$nodes), length(x$relationships)))
  invisible(x)
}
