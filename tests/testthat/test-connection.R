test_that("package loads and exports the public API", {
  expect_true(is.function(neo4j_connect))
  expect_true(is.function(cypher))
})

test_that("neo4j_connect returns a connection handle (connection is lazy)", {
  # neo4rs::Graph::new builds the pool without dialing, so this succeeds
  # even against a dead endpoint and hands back an external pointer.
  con <- neo4j_connect("neo4j://127.0.0.1:1", user = "neo4j", password = "x")
  expect_s3_class(con, "neo4j_connection")
  expect_identical(typeof(con$handle), "externalptr")
})

test_that("running a query against a dead endpoint raises a clean R error", {
  con <- neo4j_connect("neo4j://127.0.0.1:1", user = "neo4j", password = "x")
  # Drives the full R -> Rust -> neo4rs -> Bolt path; must surface as a
  # catchable R error rather than aborting the session.
  expect_error(
    cypher(con, "RETURN 1 AS n"),
    regexp = "execution failed|refused|IO error",
    ignore.case = TRUE
  )
})
