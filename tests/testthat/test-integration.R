# Live-database integration tests. Skipped unless NEO4J_TEST_URI is set, so the
# unit suite still runs with no server. To run:
#   NEO4J_TEST_URI=neo4j://localhost:7687 NEO4J_TEST_USER=username \
#   NEO4J_TEST_PASS=password NEO4J_TEST_DB=drivertest Rscript -e 'testthat::test_local(".")'

skip_if_no_db <- function() {
  if (!nzchar(Sys.getenv("NEO4J_TEST_URI"))) {
    skip("NEO4J_TEST_URI not set; skipping live-database tests")
  }
}

live_con <- function() {
  neo4j_connect(
    Sys.getenv("NEO4J_TEST_URI"),
    user = Sys.getenv("NEO4J_TEST_USER", "neo4j"),
    password = Sys.getenv("NEO4J_TEST_PASS", ""),
    database = Sys.getenv("NEO4J_TEST_DB", "")
  )
}

# The label is passed as a parameter too, via Cypher dynamic labels: `$($label)`.
LABEL <- "Neo4jRParamTest"

test_that("parameterized round-trip filters and types results correctly", {
  skip_if_no_db()
  con <- live_con()
  cypher(con, "MATCH (n:$($label)) DETACH DELETE n", parameters = list(label = LABEL))
  cypher(con,
    "CREATE (n:$($label) {name:$name, age:$age, active:$active})",
    parameters = list(label = LABEL, name = "Ada", age = 36L, active = TRUE))
  cypher(con,
    "CREATE (n:$($label) {name:$name, age:$age, active:$active})",
    parameters = list(label = LABEL, name = "Bob", age = 28L, active = FALSE))

  df <- cypher(con,
    "MATCH (n:$($label)) WHERE n.age >= $min RETURN n.name AS name, n.age AS age, n.active AS active",
    parameters = list(label = LABEL, min = 30L))

  expect_equal(nrow(df), 1L)
  expect_equal(df$name, "Ada")
  expect_type(df$age, "integer")
  expect_type(df$active, "logical")

  cypher(con, "MATCH (n:$($label)) DETACH DELETE n", parameters = list(label = LABEL))
})

test_that("parameters are injection-safe (value treated as data, not Cypher)", {
  skip_if_no_db()
  con <- live_con()
  cypher(con, "MATCH (n:$($label)) DETACH DELETE n", parameters = list(label = LABEL))
  cypher(con, "CREATE (n:$($label) {name:$name})",
         parameters = list(label = LABEL, name = "Ada"))

  res <- cypher(con,
    "MATCH (n:$($label)) WHERE n.name = $name RETURN count(n) AS matches",
    parameters = list(label = LABEL, name = "Ada' RETURN 1 // "))
  expect_equal(res$matches, 0L)

  cypher(con, "MATCH (n:$($label)) DETACH DELETE n", parameters = list(label = LABEL))
})

test_that("lists become list-columns of vectors; nodes/rels/paths map to objects", {
  skip_if_no_db()
  con <- live_con()
  cypher(con, "MATCH (n:$($label)) DETACH DELETE n", parameters = list(label = LABEL))
  cypher(con,
    "CREATE (:$($label) {name:$an, tags:$tags})-[:KNOWS {since:$since}]->(:$($label) {name:$bn})",
    parameters = list(label = LABEL, an = "Ada", tags = list("math", "cs"),
                      since = 2020L, bn = "Bob"))

  # list-column
  df <- cypher(con, "MATCH (n:$($label) {name:$name}) RETURN n.tags AS tags",
               parameters = list(label = LABEL, name = "Ada"))
  expect_true(is.list(df$tags))
  expect_identical(df$tags[[1]], c("math", "cs"))

  # node
  nd <- cypher(con, "MATCH (n:$($label) {name:$name}) RETURN n",
               parameters = list(label = LABEL, name = "Ada"))$n[[1]]
  expect_s3_class(nd, "neo4j_node")
  expect_true(LABEL %in% nd$labels)
  expect_identical(nd$properties$name, "Ada")

  # relationship
  rl <- cypher(con, "MATCH (:$($label))-[r:KNOWS]->(:$($label)) RETURN r",
               parameters = list(label = LABEL))$r[[1]]
  expect_s3_class(rl, "neo4j_relationship")
  expect_identical(rl$type, "KNOWS")

  # path
  pt <- cypher(con, "MATCH p = (:$($label) {name:$name})-[:KNOWS]->(:$($label)) RETURN p",
               parameters = list(label = LABEL, name = "Ada"))$p[[1]]
  expect_s3_class(pt, "neo4j_path")
  expect_length(pt$nodes, 2L)
  expect_length(pt$relationships, 1L)

  cypher(con, "MATCH (n:$($label)) DETACH DELETE n", parameters = list(label = LABEL))
})

test_that("format='list' returns nested records and summary is attached", {
  skip_if_no_db()
  con <- live_con()
  cypher(con, "MATCH (n:$($label)) DETACH DELETE n", parameters = list(label = LABEL))
  cypher(con, "CREATE (:$($label) {name:$n, tags:$t})",
         parameters = list(label = LABEL, n = "Ada", t = list("math", "cs")))

  lst <- cypher(con, "MATCH (n:$($label)) RETURN n.name AS name, n.tags AS tags",
                parameters = list(label = LABEL), format = "list")
  expect_type(lst, "list")
  expect_identical(lst[[1]]$name, "Ada")
  expect_identical(lst[[1]]$tags, c("math", "cs"))

  df <- cypher(con, "MATCH (n:$($label)) RETURN n.name AS name",
               parameters = list(label = LABEL), summary = TRUE)
  s <- neo4j_summary(df)
  expect_s3_class(s, "neo4j_summary")
  expect_equal(s$records, 1L)
  expect_true(is.numeric(s$elapsed_ms))

  cypher(con, "MATCH (n:$($label)) DETACH DELETE n", parameters = list(label = LABEL))
})
